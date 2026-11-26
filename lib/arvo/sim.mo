## Deterministic Web Simulation Testing (DST) engine driving real `ApiTest.App` routes,
## multiple actors, advancing fake `Clock`, `Arvo.Jobs` retries/crashes, session rotation/replay,
## global invariant checking after every step, and delta-shrinking for minimal reproducers.
module Arvo.Sim
expose SystemEvent(..),
SimStep(..),
Invariant(..),
SimConfig(..),
SimSummary(..),
SimFailure(..),
default_config,
check_sessions_invariant,
check_jobs_invariant,
check_events_invariant,
check_sqlite_integrity,
default_invariants,
maybe_system_fault,
apply_standard_system_event,
verify_network_fault,
replay_steps,
run,
format_step,
format_failure
use Api
use Arvo.Fixtures.SimApp
use Arvo.Jobs
use Arvo.Session
use Http
use Json

## Built-in simulation faults mixed alongside app-defined actions.
enum SystemEvent
  AdvanceClock(duration: Duration)
  RunNextJob(job_names: List(Text))
  CrashRunningJob
  RequeueStaleJobs(stale_seconds: Int)
  ExpirePruneSessions
  RotateActorSession(actor_idx: Int)
  ReplayStaleSessionCookie(actor_idx: Int)
  InjectNetworkFault(target: Text, fault: Network.FakeReply)
end

## One simulation trace step: either an app action for `actor_idx` or a `SystemEvent`.
enum SimStep(A)
  AppAction(actor_idx: Int, action: A)
  System(event: SystemEvent)
end

## Global domain or framework invariant evaluated against `(world, db, clock)` after every step.
struct Invariant(W)
  name: Text
  check: fn(W, Sqlite.Database, Clock) : Result(Unit, Text)
end

## Configuration controlling seed sweep count, step budget, shrink budget, and fault mix.
struct SimConfig
  base_seed: Int
  seed_count: Int
  max_steps: Int
  shrink_budget: Int
  fault_probability_pct: Int
end

## Passing simulation sweep statistics.
struct SimSummary
  seeds_run: Int
  total_steps: Int
  system_events_run: Int
  invariants_checked: Int
end

## Deterministic failing trace report produced after shrinking.
struct SimFailure(A)
  seed: Int
  invariant_name: Text
  reason: Text
  original_len: Int
  shrunk_steps: List(SimStep(A))
  failing_step_index: Int
  state_summary: Json
end

## Default `SimConfig` starting at seed 1 with 48 steps/seed, 200 shrink replays, and 15% fault rate.
fn default_config(seed_count: Int) : SimConfig
  SimConfig(
    base_seed: 1,
    seed_count: seed_count,
    max_steps: 48,
    shrink_budget: 200,
    fault_probability_pct: 15
  )
end

fn has_table(db: Sqlite.Database, name: Text) : Result(Bool, Text)
  rows = try db.query(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [Sqlite.String(name)]
  ).map_error(fn(e) "#{e}" end)
  Ok(not rows.rows.empty?)
end

struct SimSessionCheckRow
  id: Text
  token_hash: Text
  last_seen_at: Time
  created_at: Time
end

## Verifies every `arvo_sessions` row stores a non-empty `token_hash` and `last_seen_at >= created_at`.
fn check_sessions_invariant(db: Sqlite.Database) : Result(Unit, Text)
  return Ok(Unit) if not try has_table(db, "arvo_sessions")
  rows = try db.query("SELECT id, token_hash, last_seen_at, created_at FROM arvo_sessions", [])
    .map_error(fn(e) "#{e}" end)
  decoded = try Sqlite.decode[SimSessionCheckRow](rows).map_error(fn(e) "#{e.to_text}" end)
  for r in decoded
    if r.token_hash.trim.empty?
      return Error("session #{r.id} has empty token_hash")
    end
    if r.last_seen_at < r.created_at
      return Error("session #{r.id} last_seen_at < created_at")
    end
  end
  Ok(Unit)
end

struct SimJobCheckRow
  id: Text
  state: Text
  attempts: Int
  max_attempts: Int
end

## Verifies `arvo_jobs` invariants: non-negative attempts and no `pending` job past `max_attempts`.
fn check_jobs_invariant(db: Sqlite.Database) : Result(Unit, Text)
  return Ok(Unit) if not try has_table(db, "arvo_jobs")
  rows = try db.query("SELECT id, state, attempts, max_attempts FROM arvo_jobs", []).map_error(
    fn(e) "#{e}" end
  )
  decoded = try Sqlite.decode[SimJobCheckRow](rows).map_error(fn(e) "#{e.to_text}" end)
  for j in decoded
    if j.attempts < 0
      return Error("job #{j.id} has negative attempts #{j.attempts}")
    end
    if j.state == "pending" and j.attempts >= j.max_attempts
      return Error("job #{j.id} remains pending at attempts #{j.attempts}/#{j.max_attempts}")
    end
  end
  Ok(Unit)
end

struct SimEventCheckRow
  id: Text
  created_at: Time
end

## Verifies `arvo_events` count never shrinks and all ULID IDs and timestamps stay valid & non-decreasing.
fn check_events_invariant(db: Sqlite.Database, prev_count: Int) : Result(Int, Text)
  return Ok(0) if not try has_table(db, "arvo_events")
  rows = try db.query("SELECT id, created_at FROM arvo_events ORDER BY rowid ASC", []).map_error(
    fn(e) "#{e}" end
  )
  decoded = try Sqlite.decode[SimEventCheckRow](rows).map_error(fn(e) "#{e.to_text}" end)
  if decoded.size < prev_count
    return Error("arvo_events shrank from #{prev_count} to #{decoded.size}")
  end
  var prev_ts = None
  for ev in decoded
    if ev.id.byte_count != 26
      return Error("audit event #{ev.id} is not a 26-char ULID")
    end
    if prev_ts is Some(pts)
      if ev.created_at < pts
        return Error("audit event #{ev.id} timestamp moved backward")
      end
    end
    prev_ts = Some(ev.created_at)
  end
  Ok(decoded.size)
end

## Runs SQLite `PRAGMA integrity_check` and `PRAGMA foreign_key_check`.
fn check_sqlite_integrity(db: Sqlite.Database) : Result(Unit, Text)
  ic = try db.query("PRAGMA integrity_check", []).map_error(fn(e) "#{e}" end)
  if ic.rows != [[Sqlite.String("ok")]]
    return Error("PRAGMA integrity_check failed: #{ic.rows}")
  end
  fk = try db.query("PRAGMA foreign_key_check", []).map_error(fn(e) "#{e}" end)
  if not fk.rows.empty?
    return Error("PRAGMA foreign_key_check violations: #{fk.rows}")
  end
  Ok(Unit)
end

## Built-in Arvo framework invariants checking `arvo_sessions`, `arvo_jobs`, `arvo_events`, and SQLite integrity.
fn default_invariants() : List(Invariant(W))
  [
    Invariant(name: "arvo_sessions_valid", check: fn(_w, db, _clk) check_sessions_invariant(db) end),
    Invariant(name: "arvo_jobs_valid", check: fn(_w, db, _clk) check_jobs_invariant(db) end),
    Invariant(
      name: "arvo_events_append_only",
      check: fn(_w, db, _clk)
        _n = try check_events_invariant(db, 0)
        Ok(Unit)
      end
    ),
    Invariant(name: "sqlite_integrity", check: fn(_w, db, _clk) check_sqlite_integrity(db) end)
  ]
end

## Deterministically chooses a `SystemEvent` across all 8 fault classes when `rng.int(0, 100) < cfg.fault_probability_pct`.
fn maybe_system_fault(
  rng: Random,
  cfg: SimConfig,
  actor_count: Int,
  job_names: List(Text)
) : Option(SystemEvent)
  return None if cfg.fault_probability_pct <= 0
  return None if rng.int(0, 100) >= cfg.fault_probability_pct
  actors = if actor_count > 0: actor_count else: 1
  jobs = if job_names.empty?: ["default.job"] else: job_names
  pick = rng.int(0, 8)
  if pick == 0
    Some(AdvanceClock(duration: 30.seconds))
  else if pick == 1
    Some(RunNextJob(job_names: jobs))
  else if pick == 2
    Some(CrashRunningJob)
  else if pick == 3
    Some(RequeueStaleJobs(stale_seconds: 10))
  else if pick == 4
    Some(ExpirePruneSessions)
  else if pick == 5
    Some(RotateActorSession(actor_idx: rng.int(0, actors)))
  else if pick == 6
    Some(ReplayStaleSessionCookie(actor_idx: rng.int(0, actors)))
  else
    Some(
      InjectNetworkFault(
        target: "https://fault.arvo.invalid/webhook",
        fault: Network.Respond(response: Http.reply(503, "upstream fault"))
      )
    )
  end
end

## Verifies a single scripted `Network.FakeReply` execution against `target`, matching response/error semantics and call log.
fn verify_network_fault(
  target: Text,
  fault: Network.FakeReply,
  res: Result(Http.Response, Http.HttpError),
  calls: List(Network.RecordedCall)
) : Result(Unit, Text)
  if calls.size != 1
    return Error("InjectNetworkFault expected 1 recorded call for #{target}, got #{calls.size}")
  end
  recorded_url = case calls.first
    Some(c): c.url
    None: return Error("InjectNetworkFault missing recorded call for #{target}")
  end
  if recorded_url != target
    return Error("InjectNetworkFault recorded #{recorded_url}, expected #{target}")
  end
  case fault
    Network.Respond(response: expected):
      if res != Ok(expected)
        return Error("InjectNetworkFault expected scripted Ok response for #{target}")
      end
      Ok(Unit)
    Network.Fail(error: err):
      if res != Error(Http.Unreachable(err))
        return Error("InjectNetworkFault expected Unreachable(#{err}) for #{target}")
      end
      Ok(Unit)
    Network.TruncateAfter(bytes: _):
      if not (res is Error(Http.BadResponse(reason: _)))
        return Error("InjectNetworkFault expected BadResponse truncation error for #{target}")
      end
      Ok(Unit)
  end
end

## Applies standard infrastructure `SystemEvent`s (`AdvanceClock`, `RunNextJob`, `CrashRunningJob`,
## `RequeueStaleJobs`, and `ExpirePruneSessions`) directly against `db`, `clock`, and `app`.
fn apply_standard_system_event(
  event: SystemEvent,
  db: Sqlite.Database,
  clock: Clock,
  app: ApiTest.App
) : Result(Unit, Text)
  case event
    AdvanceClock(duration: d):
      clock.sleep(d)
      Ok(Unit)
    RunNextJob(job_names: names):
      return Ok(Unit) if not try has_table(db, "arvo_jobs")
      case Jobs.claim_next(db, clock, names)
        Error(e): Error("claim_next failed: #{e}")
        Ok(None): Ok(Unit)
        Ok(Some(job)):
          payload = case Json.parse(job.payload_json)
            Ok(p): p
            Error(_): Json.Null
          end
          case app.run_job(job.job_name, payload)
            Ok(_): Jobs.complete(db, clock, job.id).map_error(fn(e) "#{e}" end)
            Error(err): Jobs.fail_or_retry(db, clock, job.id, job.attempts, job.max_attempts, err)
              .map_error(fn(e) "#{e}" end)
          end
      end
    CrashRunningJob:
      return Ok(Unit) if not try has_table(db, "arvo_jobs")
      rows = try db.query(
        "SELECT id FROM arvo_jobs WHERE state = 'pending' ORDER BY run_at ASC, id ASC LIMIT 1",
        []
      ).map_error(fn(e) "#{e}" end)
      case rows.rows.first
        Some([Sqlite.String(jid)]):
          _upd = try db.execute(
            "UPDATE arvo_jobs SET state = 'running', attempts = attempts + 1, locked_at = ?, updated_at = ? WHERE id = ?",
            [Sqlite.String(clock.now.to_text), Sqlite.String(clock.now.to_text), Sqlite.String(jid)]
          ).map_error(fn(e) "#{e}" end)
          Ok(Unit)
        None | Some(_): Ok(Unit)
      end
    RequeueStaleJobs(stale_seconds: stale_secs):
      return Ok(Unit) if not try has_table(db, "arvo_jobs")
      _r = try Jobs.requeue_stale_running(db, clock, stale_secs).map_error(fn(e) "#{e}" end)
      Ok(Unit)
    ExpirePruneSessions:
      return Ok(Unit) if not try has_table(db, "arvo_sessions")
      _p = try Session.prune_expired(db, clock).map_error(fn(e) "#{e}" end)
      Ok(Unit)
    InjectNetworkFault(target: _, fault: _): Error(
      "InjectNetworkFault must be handled inside the caller's test apply_step via Network.fake_scripted + Sim.verify_network_fault"
    )
    RotateActorSession(actor_idx: _) | ReplayStaleSessionCookie(actor_idx: _): Error(
      "RotateActorSession and ReplayStaleSessionCookie require actor session world handling"
    )
  end
end

fn check_all_invariants(world: W, db: Sqlite.Database, clock: Clock, invariants: List(Invariant(W))) : Result(
  Int,
  (Text, Text)
)
  var checked = 0
  for inv in invariants
    checked += 1
    case inv.check(world, db, clock)
      Ok(_): Unit
      Error(reason): return Error((inv.name, reason))
    end
  end
  Ok(checked)
end

## Replays an explicit `steps` trace from `init_world(seed)`, checking `invariants` after every step.
## Returns `Ok((sys_events, checks))` or `Error((invariant_name, reason, failing_step_index))`.
fn replay_steps(
  seed: Int,
  steps: List(SimStep(A)),
  init_world: fn(Int) : (W, Sqlite.Database, Clock, SecureRandom, Random, ApiTest.App),
  apply_step: fn(W, SimStep(A), Sqlite.Database, Clock, ApiTest.App) : Result(W, Text),
  invariants: List(Invariant(W))
) : Result((Int, Int), (Text, Text, Int))
  (init_w, db, clock, _srng, _rng, app) = init_world(seed)
  var world = init_w
  var sys_count = 0
  var checks_count = 0
  var prev_events = 0

  case check_events_invariant(db, prev_events)
    Ok(n): prev_events = n
    Error(r): return Error(("arvo_events_append_only", r, 0))
  end
  case check_all_invariants(world, db, clock, invariants)
    Ok(c): checks_count += c
    Error((iname, r)): return Error((iname, r, 0))
  end

  for (idx, step) in steps.enumerate
    if step is System(event: _)
      sys_count += 1
    end
    world = case apply_step(world, step, db, clock, app)
      Ok(next_w): next_w
      Error(r): return Error(("step_execution_error", r, idx))
    end
    case check_events_invariant(db, prev_events)
      Ok(n): prev_events = n
      Error(r): return Error(("arvo_events_append_only", r, idx))
    end
    case check_all_invariants(world, db, clock, invariants)
      Ok(c): checks_count += c
      Error((iname, r)): return Error((iname, r, idx))
    end
  end
  Ok((sys_count, checks_count))
end

fn eval_target_failure(
  seed: Int,
  target_invariant: Text,
  candidate: List(SimStep(A)),
  init_world: fn(Int) : (W, Sqlite.Database, Clock, SecureRandom, Random, ApiTest.App),
  apply_step: fn(W, SimStep(A), Sqlite.Database, Clock, ApiTest.App) : Result(W, Text),
  invariants: List(Invariant(W))
) : Option((Text, Int))
  case replay_steps(seed, candidate, init_world, apply_step, invariants)
    Error((iname, reason, idx)): if iname == target_invariant: Some((reason, idx)) else: None
    Ok(_): None
  end
end

fn delete_slice(xs: List(SimStep(A)), from_idx: Int, count: Int) : List(SimStep(A))
  xs.take(from_idx).concat(xs.drop(from_idx + count))
end

fn shrink_trace(
  seed: Int,
  target_invariant: Text,
  initial_steps: List(SimStep(A)),
  initial_reason: Text,
  initial_idx: Int,
  shrink_budget: Int,
  init_world: fn(Int) : (W, Sqlite.Database, Clock, SecureRandom, Random, ApiTest.App),
  apply_step: fn(W, SimStep(A), Sqlite.Database, Clock, ApiTest.App) : Result(W, Text),
  invariants: List(Invariant(W))
) : (List(SimStep(A)), Text, Int)
  var current = initial_steps
  var current_reason = initial_reason
  var current_idx = initial_idx
  var budget = shrink_budget
  var chunk = current.size.floor_div(2)

  while chunk >= 1
    var start = 0
    while start + chunk <= current.size and budget > 0
      candidate = delete_slice(current, start, chunk)
      if candidate.empty?
        break
      end
      budget -= 1
      if eval_target_failure(seed, target_invariant, candidate, init_world, apply_step, invariants) is
        Some((r, ix))
        current = candidate
        current_reason = r
        current_idx = ix
      else
        start += chunk
      end
    end
    chunk = chunk.floor_div(2)
  end

  # Second pass: shorten large clock advances down to 1 second if failure persists
  for idx in 0..current.size
    break if budget <= 0
    case current.get(idx)
      Some(System(event: AdvanceClock(duration: d))):
        if d > 1.second
          shortened = current.set(idx, System(event: AdvanceClock(duration: 1.second))) or current
          budget -= 1
          if eval_target_failure(
            seed,
            target_invariant,
            shortened,
            init_world,
            apply_step,
            invariants
          ) is
            Some((r, ix))
            current = shortened
            current_reason = r
            current_idx = ix
          end
        end
      None | Some(_): Unit
    end
  end

  (current, current_reason, current_idx)
end

## Formats one simulation step into a concise human-readable line.
fn format_step(step: SimStep(A)) : Text where A: Json
  case step
    AppAction(actor_idx: actor_idx, action: action): "actor[#{actor_idx}]: #{Json.encode(action)}"
    System(event: ev):
      case ev
        AdvanceClock(duration: d): "system: advance_clock(#{d})"
        RunNextJob(job_names: names): "system: run_next_job(#{names.join(",")})"
        CrashRunningJob: "system: crash_running_job"
        RequeueStaleJobs(stale_seconds: secs): "system: requeue_stale_jobs(#{secs}s)"
        ExpirePruneSessions: "system: expire_prune_sessions"
        RotateActorSession(actor_idx: actor_idx): "system: rotate_actor_session(#{actor_idx})"
        ReplayStaleSessionCookie(actor_idx: actor_idx): "system: replay_stale_session_cookie(#{actor_idx})"
        InjectNetworkFault(target: target, fault: _): "system: inject_network_fault(#{target})"
      end
  end
end

## Formats a `SimFailure` report with seed, violated invariant, original vs shrunk length, and steps.
fn format_failure(failure: SimFailure(A)) : Text where A: Json
  step_lines = failure.shrunk_steps.enumerate.map(fn(pair)
    "  #{pair.0 + 1}. #{format_step(pair.1)}"
  end)
  "SimFailure(seed=#{failure.seed}, invariant=#{failure.invariant_name}, original_len=#{failure
    .original_len}, shrunk_len=#{failure.shrunk_steps.size}): #{failure.reason}\n#{step_lines.join(
      "\n"
    )}"
end

## Runs `cfg.seed_count` deterministic simulations starting from `cfg.base_seed`.
## Shrinks the first invariant failure and returns a reproducible `SimFailure(A)`.
fn run(
  cfg: SimConfig,
  init_world: fn(Int) : (W, Sqlite.Database, Clock, SecureRandom, Random, ApiTest.App),
  next_step: fn(Random, W) : SimStep(A),
  apply_step: fn(W, SimStep(A), Sqlite.Database, Clock, ApiTest.App) : Result(W, Text),
  invariants: List(Invariant(W))
) : Result(SimSummary, SimFailure(A))
  where A: Json
  var total_steps = 0
  var total_sys = 0
  var total_checks = 0
  var seeds_done = 0

  for offset in 0..cfg.seed_count
    seed = cfg.base_seed + offset
    seeds_done += 1
    (init_w, db, clock, _srng, rng, app) = init_world(seed)
    var world = init_w
    var recorded = []
    var prev_events = 0

    case check_all_invariants(world, db, clock, invariants)
      Ok(c): total_checks += c
      Error((iname, reason)): return Error(
        SimFailure(
          seed: seed,
          invariant_name: iname,
          reason: reason,
          original_len: 0,
          shrunk_steps: [],
          failing_step_index: 0,
          state_summary: Json.Object({"seed": Json.int(seed), "step": Json.int(0)})
        )
      )
    end

    for step_idx in 0..cfg.max_steps
      step = next_step(rng, world)
      recorded = recorded.append(step)
      total_steps += 1
      if step is System(event: _)
        total_sys += 1
      end
      case apply_step(world, step, db, clock, app)
        Ok(next_w): world = next_w
        Error(err_reason):
          (shrunk, s_reason, s_idx) = shrink_trace(
            seed,
            "step_execution_error",
            recorded,
            err_reason,
            step_idx,
            cfg.shrink_budget,
            init_world,
            apply_step,
            invariants
          )
          return Error(
            SimFailure(
              seed: seed,
              invariant_name: "step_execution_error",
              reason: "#{err_reason} (shrunk: #{s_reason})",
              original_len: recorded.size,
              shrunk_steps: shrunk,
              failing_step_index: s_idx,
              state_summary: Json.Object({"seed": Json.int(seed), "step": Json.int(step_idx)})
            )
          )
      end

      case check_events_invariant(db, prev_events)
        Ok(ev_n): prev_events = ev_n
        Error(ev_err):
          (shrunk, s_reason, s_idx) = shrink_trace(
            seed,
            "arvo_events_append_only",
            recorded,
            ev_err,
            step_idx,
            cfg.shrink_budget,
            init_world,
            apply_step,
            invariants
          )
          return Error(
            SimFailure(
              seed: seed,
              invariant_name: "arvo_events_append_only",
              reason: "#{ev_err} (#{s_reason})",
              original_len: recorded.size,
              shrunk_steps: shrunk,
              failing_step_index: s_idx,
              state_summary: Json.Object({"seed": Json.int(seed), "step": Json.int(step_idx)})
            )
          )
      end

      case check_all_invariants(world, db, clock, invariants)
        Ok(c): total_checks += c
        Error((iname, reason)):
          (shrunk, s_reason, s_idx) = shrink_trace(
            seed,
            iname,
            recorded,
            reason,
            step_idx,
            cfg.shrink_budget,
            init_world,
            apply_step,
            invariants
          )
          return Error(
            SimFailure(
              seed: seed,
              invariant_name: iname,
              reason: s_reason,
              original_len: recorded.size,
              shrunk_steps: shrunk,
              failing_step_index: s_idx,
              state_summary: Json.Object({
                "seed": Json.int(seed),
                "step": Json.int(step_idx),
                "raw_reason": Json.String(reason)
              })
            )
          )
      end
    end
  end

  Ok(
    SimSummary(
      seeds_run: seeds_done,
      total_steps: total_steps,
      system_events_run: total_sys,
      invariants_checked: total_checks
    )
  )
end

struct SimWorld
  cookies: List(Text)
  stale_cookies: List(Text)
  pay_attempts: Int
end

enum SimAction
  PayBill(expected_version: Int)
  ListBills
  EnqueueSync
end

fn split_actor_cred(cred: Text) : (Text, Text)
  parts = cred.split("|")
  (parts.first or "", parts.get(1) or "")
end

fn extract_set_cookie_val(res: Api.Response, cookie_name: Text) : Option(Text)
  prefix = "#{cookie_name}="
  for (k, v) in res.headers
    if k.ascii_lowercase == "set-cookie"
      head = (v.split(";").first or "").trim
      if head.drop_prefix(prefix) is Some(tok)
        return Some(tok) if not tok.empty?
      end
    end
  end
  None
end

fn apply_sim_world(
  world: SimWorld,
  step: SimStep(SimAction),
  db: Sqlite.Database,
  clock: Clock,
  app: ApiTest.App
) : Result(SimWorld, Text)
  case step
    System(event: ev):
      case ev
        RotateActorSession(actor_idx: actor_idx):
          cred = case world.cookies.get(actor_idx)
            Some(c): c
            None: return Ok(world)
          end
          (old_cookie, old_csrf) = split_actor_cred(cred)
          return Ok(world) if old_cookie.empty?
          rot_res = app.send(
            Api.post("/sessions/rotate").with_header("Cookie", "arvo_session=#{old_cookie}")
              .with_header("X-XSRF-TOKEN", old_csrf)
          )
          if rot_res.status >= 500
            return Error("session rotation failed with #{rot_res.status}")
          end
          if rot_res.status != 200
            return Ok(world)
          end
          new_cookie = try extract_set_cookie_val(rot_res, "arvo_session").or_fail(
            "session rotation missing Set-Cookie"
          )
          parsed_rot = try Json.parse(rot_res.text).map_error(fn(e) "#{e}" end)
          new_csrf = try parsed_rot.text_at("csrf_token").or_fail("missing rotated csrf_token")
          updated_cookies = world.cookies.set(actor_idx, "#{new_cookie}|#{new_csrf}") or world.cookies
          Ok(
            SimWorld(
              cookies: updated_cookies,
              stale_cookies: world.stale_cookies.append(old_cookie),
              pay_attempts: world.pay_attempts
            )
          )
        ReplayStaleSessionCookie(actor_idx: _):
          stale_tok = case world.stale_cookies.first
            Some(tok): tok
            None: return Ok(world)
          end
          rep_res = app.send(Api.get("/bills").with_header("Cookie", "arvo_session=#{stale_tok}"))
          if rep_res.status != 401 and rep_res.status != 303
            return Error("revoked session cookie accepted with status #{rep_res.status}")
          end
          Ok(world)
        AdvanceClock(duration: _) | RunNextJob(job_names: _) | CrashRunningJob | RequeueStaleJobs(
          stale_seconds: _
        ) | ExpirePruneSessions | InjectNetworkFault(target: _, fault: _):
          try apply_standard_system_event(ev, db, clock, app)
          Ok(world)
      end
    AppAction(actor_idx: actor_idx, action: action):
      cred = world.cookies.get(actor_idx) or ""
      (cookie_val, csrf_tok) = split_actor_cred(cred)
      req = case action
        PayBill(expected_version: ver): Api.post("/bills/1/pay").with_header(
          "Cookie",
          "arvo_session=#{cookie_val}"
        ).with_header("X-XSRF-TOKEN", csrf_tok).with_json(SimApp.SimPayIn(expected_version: ver))
        ListBills: Api.get("/bills").with_header("Cookie", "arvo_session=#{cookie_val}")
        EnqueueSync: Api.post("/jobs/enqueue").with_header("Cookie", "arvo_session=#{cookie_val}")
          .with_header("X-XSRF-TOKEN", csrf_tok)
      end
      res = app.send(req)
      if res.status >= 500
        return Error("unexpected 5xx status #{res.status}")
      end
      Ok(
        SimWorld(
          cookies: world.cookies,
          stale_cookies: world.stale_cookies,
          pay_attempts: world.pay_attempts + 1
        )
      )
  end
end

fn single_flight_invariant(_w: SimWorld, db: Sqlite.Database, _clk: Clock) : Result(Unit, Text)
  rows = try db.query("SELECT id FROM arvo_events WHERE action = 'bill.mark_in_flight'", [])
    .map_error(fn(e) "#{e}" end)
  if rows.rows.size > 1
    Error("bill paid #{rows.rows.size} times without lock rejection")
  else
    Ok(Unit)
  end
end

fn next_sim_step(rng: Random, _w: SimWorld) : SimStep(SimAction)
  fault_cfg = SimConfig(
    base_seed: 1,
    seed_count: 1,
    max_steps: 48,
    shrink_budget: 200,
    fault_probability_pct: 45
  )
  if maybe_system_fault(rng, fault_cfg, 2, ["sync.bill"]) is Some(sys_ev)
    return System(event: sys_ev)
  end
  pick = rng.int(0, 6)
  if pick == 0
    AppAction(actor_idx: 0, action: EnqueueSync)
  else if pick == 1
    AppAction(actor_idx: 1, action: ListBills)
  else
    actor_i = rng.int(0, 2)
    AppAction(actor_idx: actor_i, action: PayBill(expected_version: 1))
  end
end

test "Arvo.Sim passes on locked workflow, discovers and shrinks optimistic-lock race, and catches corrupted framework tables"
  t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"

  init_clean = fn(seed)
    sql = Sqlite.in_memory()
    clk = Clock.fixed(t0)
    srng = SecureRandom.seeded(seed)
    rng = Random.seeded(seed)
    env = Env.of({})
    app = ApiTest.start(SimApp, sql, clk, srng, env)
    db = case sql.open("sim.sqlite")
      Ok(d): d
      Error(_): stop "open sim.sqlite"
    end
    (c1, c2) = case SimApp.bootstrap_world(db, srng, clk)
      Ok(pair): pair
      Error(_): stop "bootstrap failed"
    end
    w = SimWorld(cookies: [c1, c2], stale_cookies: [], pay_attempts: 0)
    (w, db, clk, srng, rng, app)
  end

  invs = default_invariants().append(
    Invariant(name: "single_bill_payment", check: single_flight_invariant)
  )
  cfg_clean = default_config(8)
  assert cfg_clean.base_seed == 1
  assert cfg_clean.seed_count == 8
  assert cfg_clean.max_steps == 48
  assert cfg_clean.shrink_budget == 200
  assert cfg_clean.fault_probability_pct == 15

  apply_sim_test = fn(w, step, db, clk, app)
    if step is System(event: InjectNetworkFault(target: t, fault: f))
      net = Network.fake_scripted([("GET", t, [f])])
      res = Http.get(t).send(net)
      try verify_network_fault(t, f, res, Network.recorded_calls(net))
      Ok(w)
    else
      apply_sim_world(w, step, db, clk, app)
    end
  end

  clean_res = run(
    SimConfig(
      base_seed: 1,
      seed_count: 6,
      max_steps: 20,
      shrink_budget: 100,
      fault_probability_pct: 15
    ),
    init_clean,
    next_sim_step,
    apply_sim_test,
    invs
  )
  assert clean_res is Ok(summary)
  assert summary.seeds_run == 6
  assert summary.total_steps == 120
  assert summary.system_events_run > 0
  assert summary.invariants_checked == 630

  # Prove deterministic step generator hits ALL 8 SystemEvent variants + actor actions
  sample_w = SimWorld(cookies: ["c1|t1", "c2|t2"], stale_cookies: [], pay_attempts: 0)
  sample_rng = Random.seeded(77)
  var gen_steps = []
  for _i in 0..160
    gen_steps = gen_steps.append(next_sim_step(sample_rng, sample_w))
  end
  assert gen_steps.contains?(System(event: AdvanceClock(duration: 30.seconds)))
  assert gen_steps.contains?(System(event: RunNextJob(job_names: ["sync.bill"])))
  assert gen_steps.contains?(System(event: CrashRunningJob))
  assert gen_steps.contains?(System(event: RequeueStaleJobs(stale_seconds: 10)))
  assert gen_steps.contains?(System(event: ExpirePruneSessions))
  assert gen_steps.contains?(System(event: RotateActorSession(actor_idx: 0)))
  assert gen_steps.contains?(System(event: ReplayStaleSessionCookie(actor_idx: 0)))
  assert gen_steps.contains?(
    System(
      event: InjectNetworkFault(
        target: "https://fault.arvo.invalid/webhook",
        fault: Network.Respond(response: Http.reply(503, "upstream fault"))
      )
    )
  )
  assert gen_steps.contains?(AppAction(actor_idx: 0, action: EnqueueSync))
  assert gen_steps.contains?(AppAction(actor_idx: 1, action: ListBills))
  assert gen_steps.contains?(AppAction(actor_idx: 0, action: PayBill(expected_version: 1)))
  assert gen_steps.contains?(AppAction(actor_idx: 1, action: PayBill(expected_version: 1)))
  assert not gen_steps.contains?(AppAction(actor_idx: 2, action: PayBill(expected_version: 1)))
  assert not gen_steps.contains?(System(event: AdvanceClock(duration: 31.seconds)))
  assert not gen_steps.contains?(System(event: RequeueStaleJobs(stale_seconds: 11)))

  # Also verify apply_sim_world executes real RotateActorSession, ReplayStaleSessionCookie, & InjectNetworkFault
  (sys_w, sys_db, sys_clk, _sys_srng, _sys_rng, sys_app) = init_clean(99)
  assert apply_sim_world(
    sys_w,
    System(event: RotateActorSession(actor_idx: 0)),
    sys_db,
    sys_clk,
    sys_app
  ) is
    Ok(rotated_w)
  assert rotated_w.cookies != sys_w.cookies
  assert rotated_w.stale_cookies.size == 1
  assert apply_sim_world(
    rotated_w,
    System(event: ReplayStaleSessionCookie(actor_idx: 0)),
    sys_db,
    sys_clk,
    sys_app
  ) ==
    Ok(rotated_w)
  assert apply_sim_test(
    rotated_w,
    System(
      event: InjectNetworkFault(
        target: "https://t.example/hook",
        fault: Network.Respond(response: Http.reply(503, "down"))
      )
    ),
    sys_db,
    sys_clk,
    sys_app
  ) ==
    Ok(rotated_w)
  assert apply_sim_test(
    rotated_w,
    System(
      event: InjectNetworkFault(
        target: "https://t.example/timeout",
        fault: Network.Fail(error: Network.TimedOut)
      )
    ),
    sys_db,
    sys_clk,
    sys_app
  ) ==
    Ok(rotated_w)
  assert apply_sim_test(
    rotated_w,
    System(
      event: InjectNetworkFault(
        target: "https://t.example/cut",
        fault: Network.TruncateAfter(bytes: 4)
      )
    ),
    sys_db,
    sys_clk,
    sys_app
  ) ==
    Ok(rotated_w)
  assert apply_standard_system_event(
    InjectNetworkFault(
      target: "https://t.example/hook",
      fault: Network.Respond(response: Http.reply(503, "down"))
    ),
    sys_db,
    sys_clk,
    sys_app
  ) is
    Error(_)
  assert apply_standard_system_event(RotateActorSession(actor_idx: 0), sys_db, sys_clk, sys_app) is
    Error(_)
  assert verify_network_fault(
    "https://t.example/hook",
    Network.Respond(response: Http.reply(200, "ok")),
    Ok(Http.reply(200, "ok")),
    []
  ) is
    Error(_)
  assert verify_network_fault(
    "https://t.example/hook",
    Network.Respond(response: Http.reply(200, "ok")),
    Ok(Http.reply(500, "bad")),
    [
      Network.RecordedCall(
        method: "GET",
        url: "https://t.example/hook",
        headers: [],
        body: Bytes.empty
      )
    ]
  ) is
    Error(_)

  # Prove able to fail + shrink: BUG_NO_REVOKE=1 caught by RotateActorSession + ReplayStaleSessionCookie
  init_no_revoke = fn(seed)
    sql = Sqlite.in_memory()
    clk = Clock.fixed(t0)
    srng = SecureRandom.seeded(seed)
    rng = Random.seeded(seed)
    app = ApiTest.start(SimApp, sql, clk, srng, Env.of({"BUG_NO_REVOKE": "1"}))
    db = case sql.open("sim.sqlite")
      Ok(d): d
      Error(_): stop "open sim.sqlite"
    end
    (c1, c2) = case SimApp.bootstrap_world(db, srng, clk)
      Ok(pair): pair
      Error(_): stop "bootstrap failed"
    end
    (SimWorld(cookies: [c1, c2], stale_cookies: [], pay_attempts: 0), db, clk, srng, rng, app)
  end
  assert replay_steps(
    1,
    [System(event: RotateActorSession(actor_idx: 0)), System(event: ReplayStaleSessionCookie(actor_idx: 0))],
    init_no_revoke,
    apply_sim_world,
    invs
  ) is
    Error(("step_execution_error", _, 1))
  assert apply_sim_world(
    rotated_w,
    AppAction(actor_idx: 0, action: ListBills),
    sys_db,
    sys_clk,
    sys_app
  ) is
    Ok(after_act)
  assert after_act.pay_attempts == 1

  # Verify status >= 500 triggers step error cleanly
  sql_500 = Sqlite.in_memory()
  clk_500 = Clock.fixed(t0)
  srng_500 = SecureRandom.seeded(99)
  app_500 = ApiTest.start(SimApp, sql_500, clk_500, srng_500, Env.of({"BUG_500": "1"}))
  assert sql_500.open("sim.sqlite") is Ok(db_500)
  assert SimApp.bootstrap_world(db_500, srng_500, clk_500) is Ok((c500, _))
  w_500 = SimWorld(cookies: [c500], stale_cookies: [], pay_attempts: 0)
  assert apply_sim_world(
    w_500,
    AppAction(actor_idx: 0, action: ListBills),
    db_500,
    clk_500,
    app_500
  ) ==
    Error("unexpected 5xx status 500")

  # Prove able to fail + shrink + deterministically reproduce on BUG_SKIP_LOCK=1
  init_buggy = fn(seed)
    sql = Sqlite.in_memory()
    clk = Clock.fixed(t0)
    srng = SecureRandom.seeded(seed)
    rng = Random.seeded(seed)
    env = Env.of({"BUG_SKIP_LOCK": "1"})
    app = ApiTest.start(SimApp, sql, clk, srng, env)
    db = case sql.open("sim.sqlite")
      Ok(d): d
      Error(_): stop "open sim.sqlite"
    end
    (c1, c2) = case SimApp.bootstrap_world(db, srng, clk)
      Ok(pair): pair
      Error(_): stop "bootstrap failed"
    end
    w = SimWorld(cookies: [c1, c2], stale_cookies: [], pay_attempts: 0)
    (w, db, clk, srng, rng, app)
  end

  buggy_cfg = SimConfig(
    base_seed: 10,
    seed_count: 5,
    max_steps: 32,
    shrink_budget: 200,
    fault_probability_pct: 15
  )
  assert run(buggy_cfg, init_buggy, next_sim_step, apply_sim_world, invs) is Error(failure)
  assert failure.invariant_name == "single_bill_payment"
  assert failure.shrunk_steps.size == 2
  assert failure.shrunk_steps.size <= failure.original_len
  assert failure.failing_step_index == 1
  formatted_f = format_failure(failure)
  assert formatted_f.contains?("invariant=single_bill_payment")
  assert formatted_f.contains?("\n  1. ")
  assert formatted_f.contains?("\n  2. ")

  # Replaying the reported seed reproduces the exact same shrunk failure deterministically
  replay_cfg = SimConfig(
    base_seed: failure.seed,
    seed_count: 1,
    max_steps: 32,
    shrink_budget: 200,
    fault_probability_pct: 15
  )
  assert run(replay_cfg, init_buggy, next_sim_step, apply_sim_world, invs) is Error(repro)
  assert repro.shrunk_steps == failure.shrunk_steps
  assert repro.invariant_name == failure.invariant_name
  assert replay_steps(failure.seed, failure.shrunk_steps, init_buggy, apply_sim_world, invs) is
    Error((iname_r, _reason_r, idx_r))
  assert iname_r == "single_bill_payment"
  assert idx_r == 1

  # Shrink clock advance on non-zero index + respect 1-step & failing step errors
  var dummy_rng = 0
  init_tiny = fn(seed)
    sql = Sqlite.in_memory()
    clk = Clock.fixed(t0)
    srng = SecureRandom.seeded(seed)
    rng = Random.seeded(seed)
    app = ApiTest.start(SimApp, sql, clk, srng, Env.of({}))
    db = case sql.open("sim.sqlite")
      Ok(d): d
      Error(_): stop "open sim"
    end
    _ = dummy_rng
    (0, db, clk, srng, rng, app)
  end
  # Step 0 initial invariant failure
  apply_count_clock = fn(w, step, _db, clk, _app)
    case step
      System(event: AdvanceClock(duration: d)):
        clk.sleep(d)
        Ok(w + 1)
      System(event: _): Ok(w)
      AppAction(actor_idx: _, action: ListBills): Error("step_boom")
      AppAction(actor_idx: _, action: _): Ok(w + 1)
    end
  end
  bad_init_inv = [Invariant(name: "always_bad", check: fn(_w, _db, _c) Error("boom0") end)]
  assert replay_steps(1, [], init_tiny, apply_count_clock, bad_init_inv) ==
    Error(("always_bad", "boom0", 0))
  assert run(
    SimConfig(
      base_seed: 5,
      seed_count: 1,
      max_steps: 3,
      shrink_budget: 10,
      fault_probability_pct: 0
    ),
    init_tiny,
    fn(_r, _w) System(event: AdvanceClock(duration: 10.seconds)) end,
    apply_count_clock,
    bad_init_inv
  ) is
    Error(init_f)
  assert init_f.seed == 5
  assert init_f.original_len == 0
  assert init_f.shrunk_steps.empty?
  assert init_f.failing_step_index == 0
  assert Json.encode(init_f.state_summary) == "{\"seed\":5,\"step\":0}"

  # Shrink clock advance on non-zero index + respect 1-step & failing step errors
  clock_inv = [
    Invariant(
      name: "clock_advanced_twice",
      check: fn(_w, _db, clk)
        if clk.now > t0
          Error("tripped")
        else
          Ok(Unit)
        end
      end
    )
  ]
  next_clock_mixed = fn(_r, w)
    if w == 0
      AppAction(actor_idx: 0, action: EnqueueSync)
    else
      System(event: AdvanceClock(duration: 30.seconds))
    end
  end
  assert run(
    SimConfig(
      base_seed: 1,
      seed_count: 1,
      max_steps: 4,
      shrink_budget: 50,
      fault_probability_pct: 0
    ),
    init_tiny,
    next_clock_mixed,
    apply_count_clock,
    clock_inv
  ) is
    Error(clk_f)
  assert clk_f.invariant_name == "clock_advanced_twice"
  assert clk_f.shrunk_steps == [System(event: AdvanceClock(duration: 1.second))]
  assert clk_f.failing_step_index == 0

  # Verify budget=0 skips clock shortening, minimum 2s clock threshold keeps 20s, and 2-step essential trace shrinks idx=1 AdvanceClock to 1s
  assert run(
    SimConfig(base_seed: 2, seed_count: 1, max_steps: 2, shrink_budget: 0, fault_probability_pct: 0),
    init_tiny,
    fn(_r, _w) System(event: AdvanceClock(duration: 20.seconds)) end,
    apply_count_clock,
    clock_inv
  ) is
    Error(budget_f)
  assert budget_f.shrunk_steps == [System(event: AdvanceClock(duration: 20.seconds))]

  min_2s_inv = [
    Invariant(
      name: "two_secs",
      check: fn(_w, _db, clk)
        if clk.now >= t0 + 2.seconds: Error("2s") else: Ok(Unit)
      end
    )
  ]
  assert run(
    SimConfig(
      base_seed: 6,
      seed_count: 1,
      max_steps: 1,
      shrink_budget: 10,
      fault_probability_pct: 0
    ),
    init_tiny,
    fn(_r, _w) System(event: AdvanceClock(duration: 20.seconds)) end,
    apply_count_clock,
    min_2s_inv
  ) is
    Error(min2_f)
  assert min2_f.shrunk_steps == [System(event: AdvanceClock(duration: 20.seconds))]

  both_inv = [
    Invariant(
      name: "both_needed",
      check: fn(w, _db, clk)
        if w >= 2 and clk.now > t0: Error("both") else: Ok(Unit)
      end
    )
  ]
  assert run(
    SimConfig(
      base_seed: 7,
      seed_count: 1,
      max_steps: 3,
      shrink_budget: 20,
      fault_probability_pct: 0
    ),
    init_tiny,
    next_clock_mixed,
    apply_count_clock,
    both_inv
  ) is
    Error(both_f)
  assert both_f.shrunk_steps == [
    AppAction(actor_idx: 0, action: EnqueueSync),
    System(event: AdvanceClock(duration: 1.second))
  ]
  assert both_f.failing_step_index == 1

  # Kill chunk halving, <= boundary, budget boundary, d > 1s boundaries, and pre-step arvo_events failure
  assert replay_steps(
    1,
    [
      AppAction(actor_idx: 0, action: EnqueueSync),
      AppAction(actor_idx: 0, action: PayBill(expected_version: 2)),
      AppAction(actor_idx: 0, action: EnqueueSync),
      AppAction(actor_idx: 0, action: EnqueueSync)
    ],
    init_tiny,
    fn(w, step, _db, clk, _app)
      case step
        AppAction(actor_idx: _, action: PayBill(expected_version: 2)): Ok(w + 10)
        System(event: AdvanceClock(duration: d)):
          clk.sleep(d)
          Ok(w + 1)
        AppAction(actor_idx: _, action: _) | System(event: _): Ok(w + 1)
      end
    end,
    [Invariant(name: "ten", check: fn(w, _d, _c) if w >= 10: Error("ten") else: Ok(Unit) end)]
  ) ==
    Error(("ten", "ten", 1))
  ten_inv = [
    Invariant(name: "ten", check: fn(w, _d, _c) if w >= 10: Error("ten") else: Ok(Unit) end)
  ]
  ten_apply = fn(w, step, _db, clk, _app)
    case step
      AppAction(actor_idx: _, action: PayBill(expected_version: 2)): Ok(w + 10)
      System(event: AdvanceClock(duration: d)):
        clk.sleep(d)
        Ok(w + 1)
      AppAction(actor_idx: _, action: _) | System(event: _): Ok(w + 1)
    end
  end
  assert shrink_trace(
    1,
    "ten",
    [
      AppAction(actor_idx: 0, action: EnqueueSync),
      AppAction(actor_idx: 0, action: PayBill(expected_version: 2)),
      AppAction(actor_idx: 0, action: EnqueueSync),
      AppAction(actor_idx: 0, action: EnqueueSync)
    ],
    "ten",
    1,
    20,
    init_tiny,
    ten_apply,
    ten_inv
  ).0 == [AppAction(actor_idx: 0, action: PayBill(expected_version: 2))]
  assert shrink_trace(
    1,
    "ten",
    [
      AppAction(actor_idx: 0, action: PayBill(expected_version: 2)),
      AppAction(actor_idx: 0, action: EnqueueSync)
    ],
    "ten",
    0,
    20,
    init_tiny,
    ten_apply,
    ten_inv
  ).0 == [AppAction(actor_idx: 0, action: PayBill(expected_version: 2))]

  assert shrink_trace(
    1,
    "clock_advanced_twice",
    [
      AppAction(actor_idx: 0, action: EnqueueSync),
      AppAction(actor_idx: 0, action: EnqueueSync),
      System(event: AdvanceClock(duration: 20.seconds))
    ],
    "tripped",
    2,
    2,
    init_tiny,
    apply_count_clock,
    clock_inv
  ).0 == [System(event: AdvanceClock(duration: 20.seconds))]

  assert shrink_trace(
    1,
    "clock_advanced_twice",
    [
      AppAction(actor_idx: 0, action: EnqueueSync),
      System(event: AdvanceClock(duration: 20.seconds))
    ],
    "tripped",
    1,
    0,
    init_tiny,
    apply_count_clock,
    clock_inv
  ).0 == [
    AppAction(actor_idx: 0, action: EnqueueSync),
    System(event: AdvanceClock(duration: 20.seconds))
  ]

  assert shrink_trace(
    1,
    "three_steps",
    [
      System(event: AdvanceClock(duration: 20.seconds)),
      System(event: AdvanceClock(duration: 20.seconds)),
      System(event: AdvanceClock(duration: 20.seconds))
    ],
    "three",
    2,
    5,
    init_tiny,
    apply_count_clock,
    [
      Invariant(
        name: "three_steps",
        check: fn(w, _d, _c) if w >= 3: Error("three") else: Ok(Unit) end
      )
    ]
  ).0 == [
    System(event: AdvanceClock(duration: 1.second)),
    System(event: AdvanceClock(duration: 1.second)),
    System(event: AdvanceClock(duration: 20.seconds))
  ]

  assert shrink_trace(
    1,
    "two_steps",
    [
      System(event: AdvanceClock(duration: 1.second)),
      System(event: AdvanceClock(duration: 20.seconds))
    ],
    "two",
    1,
    3,
    init_tiny,
    apply_count_clock,
    [Invariant(name: "two_steps", check: fn(w, _d, _c) if w >= 2: Error("two") else: Ok(Unit) end)]
  ).0 == [
    System(event: AdvanceClock(duration: 1.second)),
    System(event: AdvanceClock(duration: 1.second))
  ]

  assert shrink_trace(
    1,
    "clock_advanced_twice",
    [System(event: AdvanceClock(duration: 2.seconds))],
    "tripped",
    0,
    5,
    init_tiny,
    apply_count_clock,
    clock_inv
  ).0 == [System(event: AdvanceClock(duration: 1.second))]

  init_bad_ev = fn(seed)
    (w, db, clk, srng, rng, app) = init_tiny(seed)
    _i = db.run(
      "CREATE TABLE IF NOT EXISTS arvo_events (id TEXT PRIMARY KEY, actor TEXT NOT NULL, action TEXT NOT NULL, table_name TEXT NOT NULL, record_id TEXT NOT NULL, created_at TEXT NOT NULL) STRICT",
      []
    )
    _b = db.run(
      "INSERT INTO arvo_events (id, actor, action, table_name, record_id, created_at) VALUES ('short', 'a', 'b', 't', '1', '2026-11-22T09:00:00Z')",
      []
    )
    (w, db, clk, srng, rng, app)
  end
  assert replay_steps(
    1,
    [AppAction(actor_idx: 0, action: EnqueueSync)],
    init_bad_ev,
    apply_count_clock,
    []
  ) is
    Error(("arvo_events_append_only", _, 0))

  assert run(
    SimConfig(
      base_seed: 3,
      seed_count: 1,
      max_steps: 2,
      shrink_budget: 20,
      fault_probability_pct: 0
    ),
    init_tiny,
    fn(_r, _w) AppAction(actor_idx: 0, action: ListBills) end,
    apply_count_clock,
    []
  ) is
    Error(step_f)
  assert step_f.invariant_name == "step_execution_error"
  assert step_f.shrunk_steps == [AppAction(actor_idx: 0, action: ListBills)]
  assert step_f.failing_step_index == 0

  # Verify replay_steps handles clean trace and returns exact sys_count & checks_count
  assert replay_steps(
    4,
    [AppAction(actor_idx: 0, action: EnqueueSync), System(event: AdvanceClock(duration: 5.seconds))],
    init_tiny,
    apply_count_clock,
    [Invariant(name: "always_ok", check: fn(_w, _d, _c) Ok(Unit) end)]
  ) ==
    Ok((1, 3))

  # Exercise remaining format_step variants cleanly
  assert format_step[SimAction](
    System(
      event: InjectNetworkFault(
        target: "http://x",
        fault: Network.Respond(response: Http.reply(200, "ok"))
      )
    )
  ).contains?("inject_network_fault")
  assert format_step[SimAction](System(event: RotateActorSession(actor_idx: 0))).contains?(
    "rotate_actor_session"
  )
  assert format_step[SimAction](System(event: ReplayStaleSessionCookie(actor_idx: 1))).contains?(
    "replay_stale_session_cookie"
  )

  # Direct negative checks for built-in Arvo framework invariants
  sql_bad = Sqlite.in_memory()
  assert sql_bad.open("bad.sqlite") is Ok(db_bad)
  assert check_sessions_invariant(db_bad) == Ok(Unit)
  assert check_jobs_invariant(db_bad) == Ok(Unit)
  assert check_events_invariant(db_bad, 0) == Ok(0)
  assert check_sqlite_integrity(db_bad) == Ok(Unit)

  assert Session.init_schema(db_bad) == Ok(Unit)
  assert db_bad.run(
    "INSERT INTO arvo_sessions (id, member_id, token_hash, csrf_token, expires_at, last_seen_at, created_at) VALUES ('s1', 'm1', '', 'c1', '2026-12-01T00:00:00Z', '2026-11-22T09:00:00Z', '2026-11-22T09:00:00Z')",
    []
  ) ==
    Ok(Unit)
  assert check_sessions_invariant(db_bad) is Error(_)

  assert db_bad.run("DELETE FROM arvo_sessions", []) == Ok(Unit)
  assert db_bad.run(
    "INSERT INTO arvo_sessions VALUES ('s2', 'm1', 'hash_ok', 'c2', '2026-12-01T00:00:00Z', '2026-11-22T08:00:00Z', '2026-11-22T09:00:00Z')",
    []
  ) ==
    Ok(Unit)
  assert check_sessions_invariant(db_bad) is Error(_)

  assert Jobs.init_schema(db_bad) == Ok(Unit)
  assert db_bad.run(
    "INSERT INTO arvo_jobs (id, queue, job_name, payload_json, state, attempts, max_attempts, run_at, created_at, updated_at) VALUES ('j1', 'default', 'sync', '{}', 'pending', 5, 5, '2026-11-22T09:00:00Z', '2026-11-22T09:00:00Z', '2026-11-22T09:00:00Z')",
    []
  ) ==
    Ok(Unit)
  assert check_jobs_invariant(db_bad) is Error(_)

  assert db_bad.run("CREATE TABLE p (id INTEGER PRIMARY KEY) STRICT", []) == Ok(Unit)
  assert db_bad.run("CREATE TABLE c (pid INTEGER NOT NULL REFERENCES p(id)) STRICT", []) == Ok(Unit)
  assert db_bad.run("PRAGMA foreign_keys = OFF", []) == Ok(Unit)
  assert db_bad.run("INSERT INTO c (pid) VALUES (999)", []) == Ok(Unit)
  assert check_sqlite_integrity(db_bad) is Error(_)
end
