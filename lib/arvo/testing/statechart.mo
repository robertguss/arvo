## Pure-Mo bounded BFS statechart explorer (`Arvo.Testing.Statechart`, Spec Part 2.6)
## with plain-English Mermaid `stateDiagram-v2` output and built-in formal models +
## real-code replay for `Arvo.Sqlite.Jobs` and `Arvo.Sqlite.Sessions` / `Arvo.Session`.
module Arvo.Testing.Statechart
expose Transition(..),
StateInvariant(..),
ChartSpec(..),
Counterexample(..),
ChartReport(..),
JobsModelState(..),
JobsModelAction(..),
SessionModelState(..),
SessionModelAction(..),
explore,
format_report,
jobs_chart_spec,
broken_jobs_chart_spec,
replay_jobs_path,
session_chart_spec,
broken_session_chart_spec,
replay_session_path
use Api
use Arvo.Session
use Arvo.Sqlite.Jobs
use Arvo.Sqlite.Sessions
use Json

## Directed model transition carrying an action, plain-English label, and successor state.
struct Transition(S, A)
  action: A
  label: Text
  next_state: S
end

## Plain-English safety invariant checked against every reachable state.
struct StateInvariant(S)
  name: Text
  holds?: fn(S) : Bool
end

## Exhaustive bounded statechart specification tied to `covered_files` at `sync_commit`.
struct ChartSpec(S, A)
  title: Text
  covered_files: List(Text)
  sync_commit: Text
  max_states: Int
  initial_states: List(S)
  step_fn: fn(S) : List(Transition(S, A))
  view_state: fn(S) : Text
  view_group: fn(S) : Option(Text)
  invariants: List(StateInvariant(S))
end

## Shortest BFS counterexample witnessing a violated invariant.
struct Counterexample(S, A)
  invariant_name: Text
  steps: List((Text, A, S))
end

## Exploration counts, shortest invariant counterexamples, truncation flag, and Mermaid diagram.
struct ChartReport(S, A)
  states_explored: Int
  transitions_explored: Int
  truncated?: Bool
  violations: List(Counterexample(S, A))
  mermaid_mmd: Text
end

fn sanitize_mermaid_text(raw: Text) : Text
  raw.replace("\r", " ").replace("\n", " ").replace("\"", "'").replace(";", ",").trim
end

fn render_mermaid(
  spec: ChartSpec(S, A),
  ordered_states: List((Text, S)),
  init_ids: List(Text),
  edges: List((Text, Text, Text)),
  break_ids: List(Text),
  may_break_ids: List(Text)
) : Text where S: Equal
  var lines = ["stateDiagram-v2"]

  # Partition states into named groups and ungrouped nodes preserving discovery order
  var group_names = []
  for (_nid, st) in ordered_states
    if spec.view_group(st) is Some(g)
      if not group_names.contains?(g)
        group_names = group_names.append(g)
      end
    end
  end

  for (g_idx, gname) in group_names.enumerate
    lines = lines.append("  state \"#{sanitize_mermaid_text(gname)}\" as grp_#{g_idx} {")
    for (nid, st) in ordered_states
      if spec.view_group(st) == Some(gname)
        lines = lines.append("    #{nid} : #{sanitize_mermaid_text(spec.view_state(st))}")
      end
    end
    lines = lines.append("  }")
  end

  for (nid, st) in ordered_states
    if spec.view_group(st) is None
      lines = lines.append("  #{nid} : #{sanitize_mermaid_text(spec.view_state(st))}")
    end
  end

  for iid in init_ids
    lines = lines.append("  [*] --> #{iid}")
  end
  for (src_id, dst_id, lbl) in edges
    lines = lines.append("  #{src_id} --> #{dst_id} : #{sanitize_mermaid_text(lbl)}")
  end

  lines = lines.append("  classDef breaks fill:#fee2e2,stroke:#b91c1c,color:#7f1d1d")
  lines = lines.append("  classDef mayBreak fill:#fef3c7,stroke:#b45309,color:#78350f")
  for bid in break_ids
    lines = lines.append("  class #{bid} breaks")
  end
  for mid in may_break_ids
    if not break_ids.contains?(mid)
      lines = lines.append("  class #{mid} mayBreak")
    end
  end
  "#{lines.join("\n")}\n"
end

## Bounded BFS explorer returning shortest counterexamples and Mermaid `stateDiagram-v2`.
fn explore(spec: ChartSpec(S, A)) : ChartReport(S, A) where S: Equal, S: Hash, A: Equal
  if spec.max_states <= 0
    return ChartReport(
      states_explored: 0,
      transitions_explored: 0,
      truncated?: not spec.initial_states.empty?,
      violations: [],
      mermaid_mmd: "stateDiagram-v2\n"
    )
  end
  limit = spec.max_states
  var visited = {}
  var ordered_states = []
  var init_ids = []
  var queue = []
  var q_idx = 0
  var transitions_count = 0
  var truncated? = false
  var edges = []
  var break_ids = []
  var may_break_ids = []
  var violations = []

  for init_s in spec.initial_states
    if not visited.has?(init_s)
      if ordered_states.size >= limit
        truncated? = true
        continue
      end
      nid = "S#{ordered_states.size}"
      visited = visited.set(init_s, nid)
      ordered_states = ordered_states.append((nid, init_s))
      init_ids = init_ids.append(nid)
      queue = queue.append((init_s, []))
    end
  end

  while true
    (cur_s, cur_path) = case queue.get(q_idx)
      Some(item): item
      None: break
    end
    q_idx += 1
    src_id = visited.get(cur_s) or ""

    # Check every safety invariant at this state
    var state_broke? = false
    for inv in spec.invariants
      if not inv.holds?(cur_s)
        state_broke? = true
        violations = violations.append(Counterexample(invariant_name: inv.name, steps: cur_path))
      end
    end
    if state_broke? and not break_ids.contains?(src_id)
      break_ids = break_ids.append(src_id)
    end

    for tr in spec.step_fn(cur_s)
      transitions_count += 1
      dst_id = case visited.get(tr.next_state)
        Some(existing): existing
        None:
          if ordered_states.size >= limit
            truncated? = true
            continue
          end
          fresh = "S#{ordered_states.size}"
          visited = visited.set(tr.next_state, fresh)
          ordered_states = ordered_states.append((fresh, tr.next_state))
          next_path = cur_path.append((tr.label, tr.action, tr.next_state))
          queue = queue.append((tr.next_state, next_path))
          fresh
      end
      edge = (src_id, dst_id, tr.label)
      if not edges.contains?(edge)
        edges = edges.append(edge)
      end
      if spec.invariants.any?(fn(inv) not inv.holds?(tr.next_state) end)
        if not may_break_ids.contains?(src_id)
          may_break_ids = may_break_ids.append(src_id)
        end
      end
    end
  end

  mmd = render_mermaid(spec, ordered_states, init_ids, edges, break_ids, may_break_ids)
  ChartReport(
    states_explored: ordered_states.size,
    transitions_explored: transitions_count,
    truncated?: truncated?,
    violations: violations,
    mermaid_mmd: mmd
  )
end

## Formats a human-readable Markdown statechart verification report with counterexample steps.
fn format_report(spec: ChartSpec(S, A), report: ChartReport(S, A)) : Text
  status = if report.truncated?
    "FAIL (TRUNCATED)"
  else if report.violations.empty?
    "PASS"
  else
    "FAIL"
  end
  var lines = [
    "## Statechart: #{spec.title} (#{status})",
    "- States explored: #{report.states_explored}",
    "- Transitions explored: #{report.transitions_explored}",
    "- Truncated: #{report.truncated?}",
    "- Sync commit: `#{spec.sync_commit}`",
    "- Covered code: #{spec.covered_files.join(", ")}",
    ""
  ]
  if not report.violations.empty?
    lines = lines.append("### Counterexamples")
    for (idx, v) in report.violations.enumerate
      lines = lines.append("#{idx + 1}. **Broken rule:** #{v.invariant_name}")
      if v.steps.empty?
        lines = lines.append("   - Broken in initial state")
      else
        for (step_idx, (lbl, _act, st)) in v.steps.enumerate
          lines = lines.append("   - Step #{step_idx + 1}: #{lbl} -> #{spec.view_state(st)}")
        end
      end
    end
    lines = lines.append("")
  end
  lines = lines.append("```mermaid").append(report.mermaid_mmd.trim).append("```")
  "#{lines.join("\n")}\n"
end

# ---------------------------------------------------------------------------
# Formal model + real-code replay for Arvo.Jobs
# ---------------------------------------------------------------------------

## Abstract state of one job modeled from `lib/arvo/jobs.mo`.
struct JobsModelState
  status: Text
  attempts: Int
  max_attempts: Int
  due?: Bool
  locked?: Bool
  stale?: Bool
end

## Concrete transitions modeled and replayed against `Arvo.Jobs`.
enum JobsModelAction
  TickWait
  Claim
  Complete
  FailOrRetry
  WorkerStalls
  RequeueStale
end

fn jobs_steps_common(s: JobsModelState, allow_double_claim?: Bool) : List(
  Transition(JobsModelState, JobsModelAction)
)
  var out = []
  if s.status == "pending" and not s.due?
    out = out.append(
      Transition(
        action: TickWait,
        label: "Retry backoff elapses",
        next_state: JobsModelState(
          status: "pending",
          attempts: s.attempts,
          max_attempts: s.max_attempts,
          due?: true,
          locked?: false,
          stale?: false
        )
      )
    )
  end
  if s.status == "pending" and s.due?
    out = out.append(
      Transition(
        action: Claim,
        label: "Worker claims due job",
        next_state: JobsModelState(
          status: "running",
          attempts: s.attempts + 1,
          max_attempts: s.max_attempts,
          due?: true,
          locked?: true,
          stale?: false
        )
      )
    )
  end
  if s.status == "running"
    out = out.append(
      Transition(
        action: Complete,
        label: "Job succeeds",
        next_state: JobsModelState(
          status: "completed",
          attempts: s.attempts,
          max_attempts: s.max_attempts,
          due?: false,
          locked?: false,
          stale?: false
        )
      )
    )
    if s.attempts < s.max_attempts
      out = out.append(
        Transition(
          action: FailOrRetry,
          label: "Job fails and schedules retry",
          next_state: JobsModelState(
            status: "pending",
            attempts: s.attempts,
            max_attempts: s.max_attempts,
            due?: false,
            locked?: false,
            stale?: false
          )
        )
      )
    else
      out = out.append(
        Transition(
          action: FailOrRetry,
          label: "Final attempt exhausts retries",
          next_state: JobsModelState(
            status: "failed",
            attempts: s.attempts,
            max_attempts: s.max_attempts,
            due?: false,
            locked?: false,
            stale?: false
          )
        )
      )
    end
    if not s.stale?
      out = out.append(
        Transition(
          action: WorkerStalls,
          label: "Worker stalls past lock TTL",
          next_state: JobsModelState(
            status: "running",
            attempts: s.attempts,
            max_attempts: s.max_attempts,
            due?: true,
            locked?: true,
            stale?: true
          )
        )
      )
    end
    if s.stale?
      if s.attempts < s.max_attempts
        out = out.append(
          Transition(
            action: RequeueStale,
            label: "Stale lock recovery requeues job",
            next_state: JobsModelState(
              status: "pending",
              attempts: s.attempts,
              max_attempts: s.max_attempts,
              due?: true,
              locked?: false,
              stale?: false
            )
          )
        )
      else
        out = out.append(
          Transition(
            action: RequeueStale,
            label: "Stale lock recovery exhausts retries",
            next_state: JobsModelState(
              status: "failed",
              attempts: s.attempts,
              max_attempts: s.max_attempts,
              due?: false,
              locked?: false,
              stale?: false
            )
          )
        )
      end
    end
    if allow_double_claim?
      out = out.append(
        Transition(
          action: Claim,
          label: "Buggy worker double-claims running job",
          next_state: JobsModelState(
            status: "running",
            attempts: s.max_attempts + 1,
            max_attempts: s.max_attempts,
            due?: true,
            locked?: true,
            stale?: false
          )
        )
      )
    end
  end
  out
end

fn jobs_invariants() : List(StateInvariant(JobsModelState))
  [
    StateInvariant(
      name: "Only running jobs hold an exclusive lock",
      holds?: fn(s) s.locked? == (s.status == "running") end
    ),
    StateInvariant(
      name: "Attempt count never exceeds max_attempts",
      holds?: fn(s) s.attempts <= s.max_attempts end
    ),
    StateInvariant(
      name: "Completed or failed jobs are terminal and never due",
      holds?: fn(s) (s.status != "completed" and s.status != "failed") or not s.due? end
    )
  ]
end

fn jobs_spec_with(title: Text, allow_double_claim?: Bool) : ChartSpec(
  JobsModelState,
  JobsModelAction
)
  ChartSpec(
    title: title,
    covered_files: ["lib/arvo/sqlite/jobs.mo:claim_next,complete,fail_or_retry,requeue_stale_running"],
    sync_commit: "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
    max_states: 200,
    initial_states: [
      JobsModelState(
        status: "pending",
        attempts: 0,
        max_attempts: 2,
        due?: true,
        locked?: false,
        stale?: false
      )
    ],
    step_fn: fn(s) jobs_steps_common(s, allow_double_claim?) end,
    view_state: fn(s)
      due_tag = if s.due?: "due" else: "backoff"
      stale_tag = if s.stale?: ", stale" else: ""
      "#{s.status} (try #{s.attempts}/#{s.max_attempts}, #{due_tag}#{stale_tag})"
    end,
    view_group: fn(s)
      if s.status == "pending"
        Some("Queued")
      else if s.status == "running"
        Some("Executing")
      else
        Some("Terminal")
      end
    end,
    invariants: jobs_invariants()
  )
end

## Formal statechart model of `Arvo.Jobs` lifecycle (`sync_commit` checked by CLI).
fn jobs_chart_spec() : ChartSpec(JobsModelState, JobsModelAction)
  jobs_spec_with("Arvo.Jobs Lifecycle", false)
end

## Negative broken-transition variant proving `explore` catches double-claiming running jobs.
fn broken_jobs_chart_spec() : ChartSpec(JobsModelState, JobsModelAction)
  jobs_spec_with("Arvo.Jobs Broken Double-Claim", true)
end

## Replays an abstract `JobsModelAction` sequence against real `Arvo.Jobs` + `Sqlite.in_memory()`,
## flagging `MODEL_DRIFT` whenever real SQLite behavior diverges from expected state.
fn replay_jobs_path(
  actions: List(JobsModelAction),
  sqlite: Sqlite,
  rng: SecureRandom,
  clock: Clock
) : Result(Jobs.JobRecord, Text)
  t0 = clock.now
  db = try sqlite.open(":memory:").map_error(fn(e) "#{e}" end)
  try Jobs.init_schema(db).map_error(fn(e) "#{e}" end)
  jid = try Jobs.enqueue_at(db, rng, clock, "default", "email.send", Json.Object({}), t0, 2).map_error(
    fn(e) "#{e}" end
  )
  stale_ttl = 60
  var last_attempts = None
  for act in actions
    case act
      TickWait:
        prev = try last_attempts.or_fail("MODEL_DRIFT: TickWait without prior Claim")
        delay = Jobs.backoff_seconds(prev)
        clock.sleep(delay.seconds)
      Claim:
        claimed = try Jobs.claim_next(db, clock, ["email.send"]).map_error(fn(e) "#{e}" end)
        case claimed
          None: return Error("MODEL_DRIFT: Claim refused by real Arvo.Jobs.claim_next")
          Some(rec): last_attempts = Some(rec.attempts)
        end
      Complete: try Jobs.complete(db, clock, jid).map_error(fn(e) "#{e}" end)
      FailOrRetry:
        cur_att = try last_attempts.or_fail("MODEL_DRIFT: FailOrRetry without prior Claim")
        _fr = try Jobs.fail_or_retry(db, clock, jid, cur_att, 2, "transient")
          .map_error(fn(e) "#{e}" end)
      WorkerStalls: clock.sleep(stale_ttl.seconds)
      RequeueStale:
        changed = try Jobs.requeue_stale_running(db, clock, stale_ttl).map_error(fn(e) "#{e}" end)
        if changed != 1
          return Error("MODEL_DRIFT: RequeueStale affected #{changed} row(s), expected 1")
        end
    end
  end
  rows = try db.query(
    "SELECT id, queue, job_name, payload_json, state, attempts, max_attempts, run_at, locked_at, last_error, created_at, updated_at FROM arvo_jobs WHERE id = ?",
    [Sqlite.String(jid)]
  ).map_error(fn(e) "#{e}" end)
  decoded = try Sqlite.decode[Jobs.JobRecord](rows).map_error(fn(e) "#{e}" end)
  decoded.first.or_fail("missing replayed job row")
end

# ---------------------------------------------------------------------------
# Formal model + real-code replay for Arvo.Session
# ---------------------------------------------------------------------------

## Abstract state of a user session modeled from `lib/arvo/session.mo`.
struct SessionModelState
  status: Text
  current_valid?: Bool
  old_valid?: Bool
end

## Concrete actions modeled and replayed against `Arvo.Session`.
enum SessionModelAction
  CreateSession
  RotateSession
  ReplayOldCookie
  RevokeSession
  ExpireTime
  PruneExpired
end

fn session_steps_common(s: SessionModelState, allow_revoked_bug?: Bool) : List(
  Transition(SessionModelState, SessionModelAction)
)
  var out = []
  if s.status == "guest"
    out = out.append(
      Transition(
        action: CreateSession,
        label: "User signs in with valid credentials",
        next_state: SessionModelState(status: "active", current_valid?: true, old_valid?: false)
      )
    )
  end
  if s.status == "active"
    out = out.append(
      Transition(
        action: RotateSession,
        label: "Privilege step rotates session token",
        next_state: SessionModelState(status: "active", current_valid?: true, old_valid?: false)
      )
    )
    out = out.append(
      Transition(
        action: RevokeSession,
        label: "User signs out and revokes row",
        next_state: SessionModelState(
          status: "revoked",
          current_valid?: allow_revoked_bug?,
          old_valid?: false
        )
      )
    )
    out = out.append(
      Transition(
        action: ExpireTime,
        label: "Clock passes session TTL",
        next_state: SessionModelState(status: "expired", current_valid?: false, old_valid?: false)
      )
    )
    if allow_revoked_bug?
      out = out.append(
        Transition(
          action: ReplayOldCookie,
          label: "Buggy code accepts prior rotated cookie",
          next_state: SessionModelState(status: "active", current_valid?: true, old_valid?: true)
        )
      )
    end
  end
  if s.status == "expired"
    out = out.append(
      Transition(
        action: PruneExpired,
        label: "Background sweep prunes expired rows",
        next_state: SessionModelState(status: "pruned", current_valid?: false, old_valid?: false)
      )
    )
  end
  out
end

fn session_invariants() : List(StateInvariant(SessionModelState))
  [
    StateInvariant(
      name: "Guest or revoked or expired sessions never authenticate",
      holds?: fn(s) s.status == "active" or not s.current_valid? end
    ),
    StateInvariant(
      name: "Rotated old session cookie never remains valid",
      holds?: fn(s) not s.old_valid? end
    )
  ]
end

fn session_spec_with(title: Text, allow_bug?: Bool) : ChartSpec(
  SessionModelState,
  SessionModelAction
)
  ChartSpec(
    title: title,
    covered_files: [
      "lib/arvo/sqlite/sessions.mo:create,load,rotate,revoke,revoke_all_for_member,prune_expired",
      "lib/arvo/session.mo:prepare_material,unseal_token_hash,verify_stored"
    ],
    sync_commit: "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
    max_states: 200,
    initial_states: [
      SessionModelState(status: "guest", current_valid?: false, old_valid?: false)
    ],
    step_fn: fn(s) session_steps_common(s, allow_bug?) end,
    view_state: fn(s)
      auth_tag = if s.current_valid?: "auth=ok" else: "auth=denied"
      old_tag = if s.old_valid?: ", old=leaked" else: ""
      "#{s.status} (#{auth_tag}#{old_tag})"
    end,
    view_group: fn(s)
      if s.status == "active"
        Some("Authenticated")
      else
        Some("Unauthenticated")
      end
    end,
    invariants: session_invariants()
  )
end

## Formal statechart model of `Arvo.Session` lifecycle (`sync_commit` checked by CLI).
fn session_chart_spec() : ChartSpec(SessionModelState, SessionModelAction)
  session_spec_with("Arvo.Session Lifecycle", false)
end

## Negative broken-transition variant proving `explore` catches accepted revoked/rotated sessions.
fn broken_session_chart_spec() : ChartSpec(SessionModelState, SessionModelAction)
  session_spec_with("Arvo.Session Broken Revocation", true)
end

## Replays a `SessionModelAction` path against real `Arvo.Sqlite.Sessions` + `Arvo.Session`, returning whether the final cookie
## authenticates (and failing with `MODEL_DRIFT` when asked to replay a rejected cookie as valid).
fn replay_session_path(
  actions: List(SessionModelAction),
  cfg: Session.SessionConfig,
  sqlite: Sqlite,
  rng: SecureRandom,
  clock: Clock
) : Result(Bool, Text)
  key = try Bytes.from_hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    .or_fail("bad key")
  db = try sqlite.open(":memory:").map_error(fn(e) "#{e}" end)
  try Sessions.init_schema(db).map_error(fn(e) "#{e}" end)

  var cur_id = ""
  var cur_cookie = ""
  var old_cookie = ""
  var expected_auth? = false
  var actual_auth? = false
  for act in actions
    case act
      CreateSession:
        (s, ck) = try Sessions.create(db, rng, clock, key, "mem_1", cfg).map_error(fn(e) "#{e}" end)
        cur_id = s.id
        cur_cookie = ck
        expected_auth? = true
      RotateSession:
        old_cookie = cur_cookie
        (s2, ck2) = try Sessions.rotate(db, rng, clock, key, cur_id, "mem_1", cfg).map_error(
          fn(e) "#{e}" end
        )
        cur_id = s2.id
        cur_cookie = ck2
        old_session = try Sessions.load(
          Api.get("/").with_header("Cookie", "#{cfg.cookie_name}=#{old_cookie}"),
          db,
          clock,
          key,
          cfg
        ).map_error(fn(e) "#{e}" end)
        if old_session is Some(_)
          return Error("MODEL_DRIFT: old rotated cookie accepted by real Arvo.Session.load")
        end
        expected_auth? = true
      ReplayOldCookie:
        loaded = try Sessions.load(
          Api.get("/").with_header("Cookie", "#{cfg.cookie_name}=#{old_cookie}"),
          db,
          clock,
          key,
          cfg
        ).map_error(fn(e) "#{e}" end)
        if loaded is None
          return Error("MODEL_DRIFT: old rotated cookie rejected by real Arvo.Session.load")
        end
      RevokeSession:
        try Sessions.revoke(db, cur_id).map_error(fn(e) "#{e}" end)
        expected_auth? = false
      ExpireTime:
        clock.sleep(cfg.ttl_seconds.seconds)
        expected_auth? = false
      PruneExpired:
        _n = try Sessions.prune_expired(db, clock).map_error(fn(e) "#{e}" end)
        expected_auth? = false
    end
    loaded_cur = try Sessions.load(
      Api.get("/").with_header("Cookie", "#{cfg.cookie_name}=#{cur_cookie}"),
      db,
      clock,
      key,
      cfg
    ).map_error(fn(e) "#{e}" end)
    actual_auth? = loaded_cur is Some(_)
    if actual_auth? != expected_auth?
      return Error("MODEL_DRIFT: expected auth=#{expected_auth?}, real Session.load=#{actual_auth?}")
    end
  end
  Ok(actual_auth?)
end

test "Arvo.Statechart explores Jobs and Session cleanly, replays real code, and catches broken variants"
  t0 = Time.parse("2026-11-25T22:00:00Z") or stop "t0"
  # 1. Clean Jobs exploration + real-code replay across happy, retry-backoff, stale recovery, and terminal fail
  j_spec = jobs_chart_spec()
  assert j_spec.max_states == 200
  j_rep = explore(j_spec)
  assert j_rep.violations.empty?
  assert j_rep.states_explored == 10
  assert j_rep.transitions_explored == 15
  assert j_rep.mermaid_mmd.contains?("stateDiagram-v2")
  assert j_rep.mermaid_mmd.contains?("classDef breaks")
  assert not j_rep.mermaid_mmd.contains?(" breaks\n")
  assert not j_rep.mermaid_mmd.contains?(" mayBreak\n")
  assert j_rep.mermaid_mmd.contains?(
    "  state \"Queued\" as grp_0 {\n    S0 : pending (try 0/2, due)\n    S3 : pending (try 1/2, backoff)\n    S5 : pending (try 1/2, due)\n  }"
  )
  assert j_rep.mermaid_mmd.contains?("  state \"Executing\" as grp_1 {\n    S1 : running (try 1/2, due)")
  assert j_rep.mermaid_mmd.contains?("S4 : running (try 1/2, due, stale)")
  assert j_rep.mermaid_mmd.contains?("S6 : running (try 2/2, due)")
  assert j_rep.mermaid_mmd.contains?("  state \"Terminal\" as grp_2 {\n    S2 : completed (try 1/2, backoff)")
  assert j_rep.mermaid_mmd.contains?("S8 : failed (try 2/2, backoff)")
  assert j_rep.mermaid_mmd.contains?("Worker claims due job")
  assert j_rep.mermaid_mmd.contains?("S3 --> S5 : Retry backoff elapses")
  assert j_rep.mermaid_mmd.contains?("S4 --> S5 : Stale lock recovery requeues job")
  j_md = format_report(j_spec, j_rep)
  assert j_md.contains?("## Statechart: Arvo.Jobs Lifecycle (PASS)")
  assert j_md.contains?("States explored: 10")

  assert replay_jobs_path([TickWait], Sqlite.in_memory(), SecureRandom.seeded(11), Clock.fixed(t0)) is Error(_)
  assert replay_jobs_path([FailOrRetry], Sqlite.in_memory(), SecureRandom.seeded(11), Clock.fixed(t0)) is
    Error(_)
  assert replay_jobs_path([Claim, Complete], Sqlite.in_memory(), SecureRandom.seeded(11), Clock.fixed(t0)) is
    Ok(r_ok)
  assert r_ok.state == "completed" and r_ok.attempts == 1
  assert replay_jobs_path(
    [Claim, FailOrRetry, TickWait, Claim, WorkerStalls, RequeueStale],
    Sqlite.in_memory(),
    SecureRandom.seeded(11),
    Clock.fixed(t0)
  ) is
    Ok(r_stfail)
  assert r_stfail.state == "failed" and r_stfail.attempts == 2
  assert replay_jobs_path(
    [Claim, FailOrRetry, TickWait, Claim, WorkerStalls, RequeueStale, Claim],
    Sqlite.in_memory(),
    SecureRandom.seeded(11),
    Clock.fixed(t0)
  ) ==
    Error("MODEL_DRIFT: Claim refused by real Arvo.Jobs.claim_next")
  assert replay_jobs_path(
    [Claim, FailOrRetry, TickWait, Claim, FailOrRetry],
    Sqlite.in_memory(),
    SecureRandom.seeded(11),
    Clock.fixed(t0)
  ) is
    Ok(r_fail)
  assert r_fail.state == "failed" and r_fail.attempts == 2
  clk_stale = Clock.fixed(t0)
  assert replay_jobs_path(
    [Claim, WorkerStalls, RequeueStale, Claim, Complete],
    Sqlite.in_memory(),
    SecureRandom.seeded(11),
    clk_stale
  ) is
    Ok(r_rec)
  assert r_rec.state == "completed" and r_rec.attempts == 2
  assert (clk_stale.now - t0).in_seconds == 60
  assert replay_jobs_path([RequeueStale], Sqlite.in_memory(), SecureRandom.seeded(11), Clock.fixed(t0)) is
    Error(_)

  # 2. Broken Jobs double-claim produces shortest 2-step counterexample and triggers MODEL_DRIFT on real code
  bj_spec = broken_jobs_chart_spec()
  bj_rep = explore(bj_spec)
  assert not bj_rep.violations.empty?
  first_jv = bj_rep.violations.first or stop "expected jobs counterexample"
  assert first_jv.invariant_name == "Attempt count never exceeds max_attempts"
  assert first_jv.steps.size == 2
  s5_st = (first_jv.steps.get(1) or stop "step2").2
  assert s5_st.attempts == 3 and s5_st.due? and not s5_st.stale?
  assert bj_rep.mermaid_mmd.contains?("S5 : running (try 3/2, due)\n")
  assert bj_rep.mermaid_mmd.contains?("class S5 breaks")
  assert bj_rep.mermaid_mmd.contains?("class S1 mayBreak")
  assert bj_rep.mermaid_mmd.split("class S1 mayBreak").size == 2
  bj_md = format_report(bj_spec, bj_rep)
  assert bj_md.contains?("(FAIL)")
  assert bj_md.contains?("### Counterexamples\n1. **Broken rule:** Attempt count never exceeds max_attempts")
  assert bj_md.contains?("Step 2: Buggy worker double-claims running job")
  term_inv = j_spec.invariants.get(2) or stop "expected terminal invariant"
  assert not term_inv.holds?(
    JobsModelState(
      status: "completed",
      attempts: 1,
      max_attempts: 2,
      due?: true,
      locked?: false,
      stale?: false
    )
  )
  bj_actions = first_jv.steps.map(fn(st) st.1 end)
  assert replay_jobs_path(bj_actions, Sqlite.in_memory(), SecureRandom.seeded(11), Clock.fixed(t0)) ==
    Error("MODEL_DRIFT: Claim refused by real Arvo.Jobs.claim_next")

  # 3. Clean Session exploration + real-code replay across empty, create, rotate, revoke, expire, prune
  s_spec = session_chart_spec()
  assert s_spec.max_states == 200
  s_rep = explore(s_spec)
  assert s_rep.violations.empty?
  assert s_rep.states_explored == 5
  assert s_rep.transitions_explored == 5
  assert not s_rep.mermaid_mmd.contains?(" breaks\n")
  assert s_rep.mermaid_mmd.contains?("  state \"Unauthenticated\" as grp_0 {\n    S0 : guest (auth=denied)")
  assert s_rep.mermaid_mmd.contains?("S2 : revoked (auth=denied)")
  assert s_rep.mermaid_mmd.contains?("S3 : expired (auth=denied)")
  assert s_rep.mermaid_mmd.contains?("S4 : pruned (auth=denied)")
  assert s_rep.mermaid_mmd.contains?("  state \"Authenticated\" as grp_1 {\n    S1 : active (auth=ok)")
  assert format_report(s_spec, s_rep).contains?("## Statechart: Arvo.Session Lifecycle (PASS)")

  sess_cfg = Session.default_config(true)
  assert replay_session_path([], sess_cfg, Sqlite.in_memory(), SecureRandom.seeded(22), Clock.fixed(t0)) ==
    Ok(false)
  assert replay_session_path(
    [CreateSession],
    sess_cfg,
    Sqlite.in_memory(),
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Ok(true)
  assert replay_session_path(
    [CreateSession, RotateSession],
    sess_cfg,
    Sqlite.in_memory(),
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Ok(true)
  assert replay_session_path(
    [CreateSession, RotateSession, RevokeSession],
    sess_cfg,
    Sqlite.in_memory(),
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Ok(false)
  assert replay_session_path(
    [CreateSession, RevokeSession],
    sess_cfg,
    Sqlite.in_memory(),
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Ok(false)
  assert replay_session_path(
    [CreateSession, ExpireTime],
    sess_cfg,
    Sqlite.in_memory(),
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Ok(false)
  assert replay_session_path(
    [CreateSession, ExpireTime, PruneExpired],
    sess_cfg,
    Sqlite.in_memory(),
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Ok(false)

  # 4. Broken Session variant triggers violations, Mermaid breaks (without mayBreak), and MODEL_DRIFT
  bs_rep = explore(broken_session_chart_spec())
  assert bs_rep.violations.size >= 2
  assert bs_rep.violations.any?(fn(v) v.steps.size == 2 end)
  assert bs_rep.mermaid_mmd.contains?("active (auth=ok, old=leaked)")
  assert bs_rep.mermaid_mmd.contains?("class S2 breaks")
  assert bs_rep.mermaid_mmd.contains?("class S4 breaks")
  assert not bs_rep.mermaid_mmd.contains?("class S4 mayBreak")
  assert replay_session_path(
    [CreateSession, RotateSession, ReplayOldCookie],
    sess_cfg,
    Sqlite.in_memory(),
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Error("MODEL_DRIFT: old rotated cookie rejected by real Arvo.Session.load")

  # 5. Edge checks: max_states == 0 -> empty chart, max_states == 1 stops at 1st distinct initial state
  zero_spec = ChartSpec(
    title: "Empty Bound",
    covered_files: ["x.mo"],
    sync_commit: "abc",
    max_states: 0,
    initial_states: [1],
    step_fn: fn(n) [Transition(action: "inc", label: "x", next_state: n + 1)] end,
    view_state: fn(n) "#{n}" end,
    view_group: fn(_) None end,
    invariants: []
  )
  z_rep = explore(zero_spec)
  assert z_rep.states_explored == 0 and
    z_rep.transitions_explored == 0 and
    z_rep.truncated? and
    z_rep.mermaid_mmd == "stateDiagram-v2\n"

  tiny_spec = ChartSpec(
    title: "Broken Init",
    covered_files: ["x.mo"],
    sync_commit: "abc",
    max_states: 1,
    initial_states: [1, 1, 2],
    step_fn: fn(n) [Transition(action: "inc", label: "step;\"one\"", next_state: n + 1)] end,
    view_state: fn(n) "state \"#{n}\"" end,
    view_group: fn(_) None end,
    invariants: [StateInvariant(name: "Never 1", holds?: fn(n) n != 1 end)]
  )
  t_rep = explore(tiny_spec)
  assert t_rep.states_explored == 1 and t_rep.transitions_explored == 1 and t_rep.truncated?
  assert t_rep.violations.size == 1
  assert t_rep.mermaid_mmd.contains?("state '1'")
  assert format_report(tiny_spec, t_rep).contains?("FAIL (TRUNCATED)")
  assert format_report(tiny_spec, t_rep).contains?("Broken in initial state")

  # Truncated clean model reaching max_states before seeing violation (n != 5 at limit 3) must flag truncated?
  trunc_clean = ChartSpec(
    title: "Truncated Counter",
    covered_files: ["x.mo"],
    sync_commit: "abc",
    max_states: 3,
    initial_states: [0],
    step_fn: fn(n) [Transition(action: "inc", label: "inc", next_state: n + 1)] end,
    view_state: fn(n) "#{n}" end,
    view_group: fn(_) None end,
    invariants: [StateInvariant(name: "Never 5", holds?: fn(n) n != 5 end)]
  )
  tc_rep = explore(trunc_clean)
  assert tc_rep.truncated? and tc_rep.violations.empty?
  assert format_report(trunc_clean, tc_rep).contains?("FAIL (TRUNCATED)")
end
