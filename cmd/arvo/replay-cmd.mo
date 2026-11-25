## `arvo replay` CLI command for capturing sanitized `FailureBundle` JSON files
## and emitting runnable Mo regression tests (`arvo replay capture|gen`).
module ReplayCmd
expose ReplayCmdArgs(..),
ReplayTimeouts(..),
default_timeouts,
replay_usage,
parse_replay_args,
run_replay_cmd
use Api
use Arvo.Audit
use Arvo.Jobs
use Arvo.Replay
use Command
use Json

## Timeout budget used by `arvo replay`.
struct ReplayTimeouts
  sqlite_secs: Int
end

## Returns default timeouts for `arvo replay`.
fn default_timeouts() : ReplayTimeouts
  ReplayTimeouts(sqlite_secs: 15)
end

## Parsed subcommand and options for `arvo replay`.
enum ReplayCmdArgs
  ReplayHelpCmd
  CaptureCmd(
    id: Text,
    kind: Text,
    method: Text,
    path: Text,
    body: Text,
    error_msg: Text,
    commit: Text,
    db_path: Option(Text),
    out_path: Option(Text)
  )
  GenCmd(bundle_path: Text, out_path: Option(Text))
end

## Returns CLI usage documentation for `arvo replay`.
fn replay_usage() : Text
  """
    usage: arvo replay <capture|gen> [--app DIR] [flags]

    Captures sanitized production failure bundles (secrets/cookies redacted) and
    generates standalone Mo regression tests.

    Subcommands:
      capture --id ID [--kind http_500|job_failed|invariant_breach] [--method M]
              [--path P] [--body JSON] [--error MSG] [--commit SHA] [--db SQLITE] [--out PATH]
      gen BUNDLE [--out TEST_MO]
    """
end

fn need_val(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("`#{flag}` requires a value. Run `arvo replay --help`.")
  else
    Ok(v)
  end
end

fn parse_capture_args(rest: List(Text)) : Result(ReplayCmdArgs, Text)
  var id = "bundle-1"
  var kind = "http_500"
  var method = "GET"
  var path = "/"
  var body = ""
  var err_msg = "captured failure"
  var commit = "HEAD"
  var db_path = None
  var out_path = None
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(ReplayHelpCmd)
    else if a == "--id"
      id = try need_val(rest, i, "--id")
      i += 1
    else if a == "--kind"
      kind = try need_val(rest, i, "--kind")
      i += 1
    else if a == "--method"
      method = try need_val(rest, i, "--method")
      i += 1
    else if a == "--path"
      path = try need_val(rest, i, "--path")
      i += 1
    else if a == "--body"
      body = try need_val(rest, i, "--body")
      i += 1
    else if a == "--error"
      err_msg = try need_val(rest, i, "--error")
      i += 1
    else if a == "--commit"
      commit = try need_val(rest, i, "--commit")
      i += 1
    else if a == "--db"
      db_path = Some(try need_val(rest, i, "--db"))
      i += 1
    else if a == "--out"
      out_path = Some(try need_val(rest, i, "--out"))
      i += 1
    else
      return Error("unknown flag '#{a}' for `arvo replay capture`. Run `arvo replay --help`.")
    end
    i += 1
  end
  Ok(
    CaptureCmd(
      id: id,
      kind: kind,
      method: method,
      path: path,
      body: body,
      error_msg: err_msg,
      commit: commit,
      db_path: db_path,
      out_path: out_path
    )
  )
end

fn parse_gen_args(rest: List(Text)) : Result(ReplayCmdArgs, Text)
  var bpath = None
  var out_path = None
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(ReplayHelpCmd)
    else if a == "--out"
      out_path = Some(try need_val(rest, i, "--out"))
      i += 1
    else if a.starts_with?("-")
      return Error("unknown flag '#{a}' for `arvo replay gen`. Run `arvo replay --help`.")
    else if bpath == None
      bpath = Some(a)
    else
      return Error("unexpected extra positional argument '#{a}' for `arvo replay gen`.")
    end
    i += 1
  end
  case bpath
    Some(p): Ok(GenCmd(bundle_path: p, out_path: out_path))
    None: Error("`arvo replay gen` requires a BUNDLE file path.")
  end
end

## Parses arguments following `arvo replay`.
fn parse_replay_args(rest: List(Text)) : Result(ReplayCmdArgs, Text)
  sub = case rest.first
    Some(s): s
    None: return Ok(ReplayHelpCmd)
  end
  if sub == "--help" or sub == "-h"
    Ok(ReplayHelpCmd)
  else if sub == "capture"
    parse_capture_args(rest.drop(1))
  else if sub == "gen"
    parse_gen_args(rest.drop(1))
  else
    Error("unknown `arvo replay` subcommand '#{sub}'. Expected `capture` or `gen`.")
  end
end

fn parse_opt_json_field(row: Json, key: Text) : Option(Json)
  case row.text_at(key)
    Some(raw):
      case Json.parse(raw)
        Ok(j): Some(j)
        Error(_): Some(Json.String(raw))
      end
    None: None
  end
end

fn query_readonly_rows(cmd: Command, db_path: Text, sql_q: Text) : List(Json)
  t = default_timeouts()
  case cmd.run("sqlite3", ["-readonly", "-json", db_path, sql_q], t.sqlite_secs.seconds)
    Error(_): []
    Ok(out):
      if not out.ok?
        []
      else
        case Json.parse(out.stdout.trim)
          Ok(Json.Array(items)): items
          Ok(_) | Error(_): []
        end
      end
  end
end

fn decode_audit_row(row: Json, fallback_time: Time) : Option(Audit.AuditEntry)
  id = row.text_at("id") or ""
  return None if id.empty?
  t_str = row.text_at("created_at") or ""
  ts = Time.parse(t_str) or fallback_time
  Some(
    Audit.AuditEntry(
      id: id,
      actor_name: row.text_at("actor_name") or "",
      action: row.text_at("action") or "",
      entity_table: row.text_at("entity_table") or "",
      entity_id: row.text_at("entity_id") or "",
      before_json: parse_opt_json_field(row, "before_json"),
      after_json: parse_opt_json_field(row, "after_json"),
      reason: row.text_at("reason"),
      undo_json: parse_opt_json_field(row, "undo_json"),
      created_at: ts
    )
  )
end

fn decode_job_row(row: Json) : Option(Jobs.JobRecord)
  id = row.text_at("id") or ""
  return None if id.empty?
  Some(
    Jobs.JobRecord(
      id: id,
      queue: row.text_at("queue") or "default",
      job_name: row.text_at("job_name") or "",
      payload_json: row.text_at("payload_json") or "{}",
      state: row.text_at("state") or "failed",
      attempts: row.int_at("attempts") or 0,
      max_attempts: row.int_at("max_attempts") or 1,
      run_at: row.text_at("run_at") or "",
      locked_at: row.text_at("locked_at"),
      last_error: row.text_at("last_error"),
      created_at: row.text_at("created_at") or "",
      updated_at: row.text_at("updated_at") or ""
    )
  )
end

fn load_db_context(cmd: Command, clock: Clock, db_path_opt: Option(Text)) : (
  Option(Jobs.JobRecord),
  List(Audit.AuditEntry),
  Option(Text)
)
  case db_path_opt
    None: (None, [], None)
    Some(p):
      audit_q = "SELECT id, actor AS actor_name, action, entity_table, entity_id, before_json, after_json, reason, undo_json, created_at FROM arvo_events ORDER BY created_at DESC, id DESC LIMIT 10"
      job_q = "SELECT id, queue, job_name, payload_json, state, attempts, max_attempts, run_at, locked_at, last_error, created_at, updated_at FROM arvo_jobs ORDER BY updated_at DESC LIMIT 1"
      now_t = clock.now
      events = query_readonly_rows(cmd, p, audit_q).filter_map(fn(r) decode_audit_row(r, now_t) end)
      jobs = query_readonly_rows(cmd, p, job_q).filter_map(decode_job_row)
      (jobs.first, events, Some(p))
  end
end

## Executes `arvo replay capture|gen` using explicit files, command, clock, env, and console capabilities.
fn run_replay_cmd(
  sub: ReplayCmdArgs,
  files: Files,
  cmd: Command,
  clock: Clock,
  env: Env,
  console: Console
) : Int
  case sub
    ReplayHelpCmd:
      console.print(replay_usage())
      0
    CaptureCmd(
      id: id,
      kind: kind,
      method: method,
      path: path,
      body: body,
      error_msg: err_msg,
      commit: commit,
      db_path: db_path,
      out_path: out_path
    ):
      var req = Api.request(method.ascii_uppercase, path)
      if not body.empty?
        req = req.with_bytes(body.bytes, "application/json")
      end
      (job_opt, events, snap_opt) = load_db_context(cmd, clock, db_path)
      var raw_env = {}
      for k in ["ARVO_SECRET_KEY", "ARVO_SEED_PASSWORD", "ARVO_ALLOWLIST", "ARVO_INSECURE_COOKIES"]
        if env.get(k) is Some(v)
          raw_env = raw_env.set(k, v)
        end
      end
      bundle = Replay.capture_bundle(
        id,
        clock.now.to_text,
        commit,
        kind,
        Some(req),
        job_opt,
        events,
        raw_env,
        snap_opt,
        err_msg
      )
      encoded = Replay.encode_bundle(bundle)
      target = out_path or ".arvo/replays/#{id}.json"
      if files.make_folder(".arvo/replays") is Error(e)
        console.error("arvo replay capture: failed creating .arvo/replays: #{e}")
        return 1
      end
      if files.write_text(target, "#{encoded}\n") is Error(e)
        console.error("arvo replay capture: failed writing #{target}: #{e}")
        return 1
      end
      console.print(target)
      0
    GenCmd(bundle_path: bundle_path, out_path: out_path):
      raw = case files.read_text(bundle_path)
        Ok(t): t
        Error(e):
          console.error("arvo replay gen: cannot read #{bundle_path}: #{e}")
          return 1
      end
      bundle = case Replay.decode_bundle(raw)
        Ok(b): b
        Error(e):
          console.error("arvo replay gen: invalid bundle #{bundle_path}: #{e}")
          return 1
      end
      code = Replay.generate_regression_test(bundle)
      case out_path
        Some(dst):
          if files.write_text(dst, code) is Error(e)
            console.error("arvo replay gen: failed writing #{dst}: #{e}")
            return 1
          end
          console.print(dst)
        None: console.print(code)
      end
      0
  end
end

test "ReplayCmd parses capture/gen args, redacts secrets from Env/DB, and generates regression tests"
  assert default_timeouts().sqlite_secs == 15
  assert parse_replay_args([]) == Ok(ReplayHelpCmd)
  assert parse_replay_args(["--help"]) == Ok(ReplayHelpCmd)
  assert parse_replay_args(["-h"]) == Ok(ReplayHelpCmd)
  assert parse_replay_args(["capture", "--help"]) == Ok(ReplayHelpCmd)
  assert parse_replay_args(["gen", "-h"]) == Ok(ReplayHelpCmd)
  assert parse_replay_args(["bogus"]) is Error(_)
  assert parse_replay_args(["capture", "--bad"]) is Error(_)
  assert parse_replay_args(["capture", "--id"]) is Error(_)
  assert parse_replay_args(["capture", "--out"]) is Error(_)
  assert parse_replay_args(["gen"]) is Error(_)
  assert parse_replay_args(["gen", "a.json", "b.json"]) is Error(_)
  assert parse_replay_args(["gen", "--bad"]) is Error(_)
  assert parse_replay_args(["gen", "--out", "out.mo", "bundle.json"]) ==
    Ok(GenCmd(bundle_path: "bundle.json", out_path: Some("out.mo")))

  cap = parse_replay_args([
    "capture",
    "--out",
    ".arvo/replays/custom.json",
    "--id",
    "r1",
    "--kind",
    "job_failed",
    "--method",
    "POST",
    "--path",
    "/bills/1/pay",
    "--body",
    "{\"password\":\"p\"}",
    "--error",
    "500 boom",
    "--db",
    "app.sqlite",
    "--commit",
    "deadbeef",
    "--id",
    "r1"
  ])
  assert cap is Ok(CaptureCmd(id: _, kind: _, method: _, path: _, body: _, error_msg: _, commit: _, db_path: _, out_path: _))

  t0 = Time.parse("2026-11-25T23:05:00Z") or stop "t0"
  files = Files.in_memory({})
  cmd = Command.fake(
    Command.replies([
      (
        Command.spec(
          "sqlite3",
          [
            "-readonly",
            "-json",
            "app.sqlite",
            "SELECT id, actor AS actor_name, action, entity_table, entity_id, before_json, after_json, reason, undo_json, created_at FROM arvo_events ORDER BY created_at DESC, id DESC LIMIT 10"
          ]
        ),
        Command.ok_output(
          "[{\"id\":\"ev1\",\"actor_name\":\"ada\",\"action\":\"bill.pay\",\"entity_table\":\"bills\",\"entity_id\":\"1\",\"before_json\":\"{\\\"s\\\":\\\"due\\\"}\",\"after_json\":null,\"reason\":\"ok\",\"undo_json\":null,\"created_at\":\"2026-11-25T23:04:00Z\"}]\n"
        )
      ),
      (
        Command.spec(
          "sqlite3",
          [
            "-readonly",
            "-json",
            "app.sqlite",
            "SELECT id, queue, job_name, payload_json, state, attempts, max_attempts, run_at, locked_at, last_error, created_at, updated_at FROM arvo_jobs ORDER BY updated_at DESC LIMIT 1"
          ]
        ),
        Command.ok_output(
          "[{\"id\":\"j1\",\"queue\":\"default\",\"job_name\":\"digest\",\"payload_json\":\"{}\",\"state\":\"failed\",\"run_at\":\"2026-11-25T23:00:00Z\",\"locked_at\":null,\"last_error\":\"boom\",\"created_at\":\"2026-11-25T23:00:00Z\",\"updated_at\":\"2026-11-25T23:01:00Z\"}]\n"
        )
      )
    ])
  )
  env = Env.of({"ARVO_SECRET_KEY": "top_secret_val", "ARVO_ALLOWLIST": "ada@household.local"})
  assert cap is Ok(cap_cmd)
  c_cap = Console.fake()
  assert run_replay_cmd(cap_cmd, files, cmd, Clock.fixed(t0), env, c_cap) == 0
  assert c_cap.printed == [".arvo/replays/custom.json"]
  assert files.read_text(".arvo/replays/custom.json") is Ok(bundle_txt)
  assert not bundle_txt.contains?("top_secret_val")
  assert bundle_txt.contains?("ada@household.local")
  assert bundle_txt.contains?("\"job_name\": \"digest\"")
  assert bundle_txt.contains?("\"attempts\": 0")
  assert bundle_txt.contains?("\"max_attempts\": 1")
  assert bundle_txt.contains?("\"action\": \"bill.pay\"")

  # Capture without body skips body bytes, and write errors fail cleanly
  assert parse_replay_args(["capture", "--id", "nobody"]) is Ok(cap_nobody)
  assert run_replay_cmd(cap_nobody, files, cmd, Clock.fixed(t0), env, Console.fake()) == 0
  assert files.read_text(".arvo/replays/nobody.json") is Ok(nb_txt)
  assert nb_txt.contains?("\"body_text\": \"\"") and nb_txt.contains?("\"headers\": []")

  files_blk = Files.in_memory({".arvo": "blocker"})
  assert run_replay_cmd(cap_cmd, files_blk, cmd, Clock.fixed(t0), env, Console.fake()) == 1
  assert run_replay_cmd(
    CaptureCmd(
      id: "x",
      kind: "http_500",
      method: "GET",
      path: "/",
      body: "",
      error_msg: "e",
      commit: "c",
      db_path: None,
      out_path: Some(".arvo/replays")
    ),
    files,
    cmd,
    Clock.fixed(t0),
    env,
    Console.fake()
  ) ==
    1
  assert run_replay_cmd(
    GenCmd(bundle_path: ".arvo/replays/custom.json", out_path: Some(".arvo/replays")),
    files,
    cmd,
    Clock.fixed(t0),
    env,
    Console.fake()
  ) ==
    1

  c_gen = Console.fake()
  assert run_replay_cmd(
    GenCmd(bundle_path: ".arvo/replays/custom.json", out_path: Some("reg_test.mo")),
    files,
    cmd,
    Clock.fixed(t0),
    env,
    c_gen
  ) ==
    0
  assert c_gen.printed == ["reg_test.mo"]
  assert files.read_text("reg_test.mo") is Ok(reg_src)
  assert reg_src.contains?("test \"replay r1: job_failed\"")

  c_stdout = Console.fake()
  assert run_replay_cmd(
    GenCmd(bundle_path: ".arvo/replays/custom.json", out_path: None),
    files,
    cmd,
    Clock.fixed(t0),
    env,
    c_stdout
  ) ==
    0
  assert (c_stdout.printed.first or "").contains?("module ReplayRegression")

  assert run_replay_cmd(
    GenCmd(bundle_path: "missing.json", out_path: None),
    files,
    cmd,
    Clock.fixed(t0),
    env,
    Console.fake()
  ) ==
    1
  assert files.write_text("bad.json", "{") == Ok(Unit)
  assert run_replay_cmd(
    GenCmd(bundle_path: "bad.json", out_path: None),
    files,
    cmd,
    Clock.fixed(t0),
    env,
    Console.fake()
  ) ==
    1
  assert run_replay_cmd(ReplayHelpCmd, files, cmd, Clock.fixed(t0), env, Console.fake()) == 0
  assert replay_usage().contains?("capture")
end
