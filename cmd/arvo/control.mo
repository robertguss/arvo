## Universal Control Adapter (`arvo control`) implemented in pure Mo.
## Provides isolated ephemeral launch, read-only doctor & SQL/audit/logs/ARIA inspection,
## deterministic in-place DB reset, browser drive/screenshot/record orchestration, and safe cleanup.
module Control
expose ControlCmd(..),
RunHandle(..),
DoctorCheck(..),
DoctorReport(..),
CleanupReport(..),
control_usage,
valid_run_id?,
parse_control_args,
detect_sqlite_filename,
compute_build_sha,
run_control_cmd
use Command
use Config
use Crypto
use Http
use Json

## Parsed `arvo control <subcommand>` invocation.
enum ControlCmd
  ControlHelpCmd
  ShaCmd
  LaunchCmd(seed: Text, run_id: Option(Text), oneshot?: Bool)
  DoctorCmd(run_id: Text)
  InspectCmd(run_id: Text, mode: Text, sql_query: Option(Text))
  ResetCmd(run_id: Text, seed: Text)
  DriveCmd(run_id: Text, cdp_url: Option(Text), viewport: Text, update_visual?: Bool)
  ScreenshotCmd(run_id: Text, out_path: Option(Text), cdp_url: Option(Text), path: Text, viewport: Text)
  RecordCmd(run_id: Text, out_path: Option(Text), cdp_url: Option(Text), viewport: Text)
  CleanupCmd(run_id: Text)
end

## Persisted isolated runtime handle stored at `.arvo/runs/<run-id>/run.json`.
struct RunHandle
  run_id: Text
  pid: Int
  url: Text
  port: Int
  data_dir: Text
  evidence_dir: Text
  sqlite_file: Text
  build_sha: Text
  seed_profile: Text
  started_at: Text
end

## Single named health probe result reported by `arvo control doctor`.
struct DoctorCheck
  name: Text
  ok?: Bool
  detail: Text
end

## Read-only health verification summary emitted by `arvo control doctor`.
struct DoctorReport
  run_id: Text
  healthy?: Bool
  checks: List(DoctorCheck)
end

## Safe teardown report asserting evidence files survived cleanup.
struct CleanupReport
  run_id: Text
  pid: Int
  stopped?: Bool
  data_removed?: Bool
  evidence_dir: Text
  evidence_files_preserved: Int
  preserved?: Bool
end

## Usage text for `arvo control`.
fn control_usage() : Text
  """
    usage: arvo control <subcommand> [--app DIR] [flags]

    Subcommands:
      launch [--seed NAME] [--run-id ID] [--oneshot]
      doctor --run-id ID
      inspect --run-id ID (--sql QUERY | --audit | --logs | --aria)
      reset --run-id ID [--seed NAME]
      drive --run-id ID [--cdp-url URL] [--viewport all|mobile|desktop] [--update-visual]
      screenshot --run-id ID [--out PATH] [--path /] [--viewport mobile|desktop] [--cdp-url URL]
      record --run-id ID [--out PATH] [--viewport mobile|desktop] [--cdp-url URL]
      cleanup --run-id ID
      sha
    """
end

## Validates run IDs (`[A-Za-z0-9_-]`, non-empty, max 64 chars) to prevent path traversal.
fn valid_run_id?(raw: Text) : Bool
  examples
    valid_run_id?("run-1_a")
    not valid_run_id?("")
    not valid_run_id?("../bad")
    not valid_run_id?("a/b")
  end

  return false if raw.empty? or raw.byte_count > 64
  raw.chars.all?(fn(c) c.ascii_letter? or c.ascii_digit? or c == '-' or c == '_' end)
end

fn need_value(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("`#{flag}` requires a value. Run `arvo control --help`.")
  else
    Ok(v)
  end
end

fn parse_launch_args(rest: List(Text)) : Result(ControlCmd, Text)
  var seed = "baseline"
  var run_id = None
  var oneshot? = false
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(ControlHelpCmd)
    else if a == "--oneshot"
      oneshot? = true
    else if a == "--seed"
      seed = try need_value(rest, i, "--seed")
      i += 1
    else if a == "--run-id"
      rid = try need_value(rest, i, "--run-id")
      if not valid_run_id?(rid)
        return Error("invalid --run-id '#{rid}' (use [A-Za-z0-9_-])")
      end
      run_id = Some(rid)
      i += 1
    else
      return Error("unknown flag '#{a}' for `arvo control launch`.")
    end
    i += 1
  end
  Ok(LaunchCmd(seed: seed, run_id: run_id, oneshot?: oneshot?))
end

fn parse_run_id_only(rest: List(Text), sub: Text) : Result(Text, Text)
  var run_id = None
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--run-id"
      rid = try need_value(rest, i, "--run-id")
      if not valid_run_id?(rid)
        return Error("invalid --run-id '#{rid}' (use [A-Za-z0-9_-])")
      end
      run_id = Some(rid)
      i += 1
    else
      return Error("unknown flag '#{a}' for `arvo control #{sub}`.")
    end
    i += 1
  end
  case run_id
    Some(r): Ok(r)
    None: Error("`arvo control #{sub}` requires `--run-id ID`.")
  end
end

fn parse_inspect_args(rest: List(Text)) : Result(ControlCmd, Text)
  var run_id = None
  var mode = ""
  var sql_query = None
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(ControlHelpCmd)
    else if a == "--run-id"
      rid = try need_value(rest, i, "--run-id")
      return Error("invalid --run-id '#{rid}'") if not valid_run_id?(rid)
      run_id = Some(rid)
      i += 1
    else if a == "--sql"
      q = try need_value(rest, i, "--sql")
      return Error("choose only one inspect mode (`--sql`, `--audit`, `--logs`, or `--aria`)") if not mode.empty?
      mode = "sql"
      sql_query = Some(q)
      i += 1
    else if a == "--audit"
      return Error("choose only one inspect mode (`--sql`, `--audit`, `--logs`, or `--aria`)") if not mode.empty?
      mode = "audit"
    else if a == "--logs"
      return Error("choose only one inspect mode (`--sql`, `--audit`, `--logs`, or `--aria`)") if not mode.empty?
      mode = "logs"
    else if a == "--aria"
      return Error("choose only one inspect mode (`--sql`, `--audit`, `--logs`, or `--aria`)") if not mode.empty?
      mode = "aria"
    else
      return Error("unknown flag '#{a}' for `arvo control inspect`.")
    end
    i += 1
  end
  rid = try run_id.or_fail("`arvo control inspect` requires `--run-id ID`.")
  return Error("`arvo control inspect` requires one of `--sql`, `--audit`, `--logs`, or `--aria`.") if mode.empty?
  Ok(InspectCmd(run_id: rid, mode: mode, sql_query: sql_query))
end

fn parse_reset_args(rest: List(Text)) : Result(ControlCmd, Text)
  var run_id = None
  var seed = "baseline"
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(ControlHelpCmd)
    else if a == "--run-id"
      rid = try need_value(rest, i, "--run-id")
      return Error("invalid --run-id '#{rid}'") if not valid_run_id?(rid)
      run_id = Some(rid)
      i += 1
    else if a == "--seed"
      seed = try need_value(rest, i, "--seed")
      i += 1
    else
      return Error("unknown flag '#{a}' for `arvo control reset`.")
    end
    i += 1
  end
  rid = try run_id.or_fail("`arvo control reset` requires `--run-id ID`.")
  Ok(ResetCmd(run_id: rid, seed: seed))
end

fn parse_drive_args(rest: List(Text)) : Result(ControlCmd, Text)
  var run_id = None
  var cdp_url = None
  var viewport = "all"
  var update_visual? = false
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(ControlHelpCmd)
    else if a == "--run-id"
      rid = try need_value(rest, i, "--run-id")
      return Error("invalid --run-id '#{rid}'") if not valid_run_id?(rid)
      run_id = Some(rid)
      i += 1
    else if a == "--cdp-url"
      cdp_url = Some(try need_value(rest, i, "--cdp-url"))
      i += 1
    else if a == "--viewport"
      viewport = try need_value(rest, i, "--viewport")
      i += 1
    else if a == "--update-visual"
      update_visual? = true
    else
      return Error("unknown flag '#{a}' for `arvo control drive`.")
    end
    i += 1
  end
  rid = try run_id.or_fail("`arvo control drive` requires `--run-id ID`.")
  Ok(DriveCmd(run_id: rid, cdp_url: cdp_url, viewport: viewport, update_visual?: update_visual?))
end

fn parse_media_args(rest: List(Text), is_screenshot?: Bool) : Result(ControlCmd, Text)
  var run_id = None
  var out_path = None
  var cdp_url = None
  var req_path = "/"
  var viewport = "desktop"
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(ControlHelpCmd)
    else if a == "--run-id"
      rid = try need_value(rest, i, "--run-id")
      return Error("invalid --run-id '#{rid}'") if not valid_run_id?(rid)
      run_id = Some(rid)
      i += 1
    else if a == "--out"
      out_path = Some(try need_value(rest, i, "--out"))
      i += 1
    else if a == "--cdp-url"
      cdp_url = Some(try need_value(rest, i, "--cdp-url"))
      i += 1
    else if a == "--viewport"
      viewport = try need_value(rest, i, "--viewport")
      i += 1
    else if is_screenshot? and a == "--path"
      req_path = try need_value(rest, i, "--path")
      i += 1
    else
      sub = if is_screenshot?: "screenshot" else: "record"
      return Error("unknown flag '#{a}' for `arvo control #{sub}`.")
    end
    i += 1
  end
  sub = if is_screenshot?: "screenshot" else: "record"
  rid = try run_id.or_fail("`arvo control #{sub}` requires `--run-id ID`.")
  if is_screenshot?
    Ok(ScreenshotCmd(run_id: rid, out_path: out_path, cdp_url: cdp_url, path: req_path, viewport: viewport))
  else
    Ok(RecordCmd(run_id: rid, out_path: out_path, cdp_url: cdp_url, viewport: viewport))
  end
end

## Parses arguments after `arvo control`.
fn parse_control_args(rest: List(Text)) : Result(ControlCmd, Text)
  sub = case rest.first
    Some(s): s
    None: return Ok(ControlHelpCmd)
  end
  tail = rest.drop(1)
  if sub == "--help" or sub == "-h"
    Ok(ControlHelpCmd)
  else if sub == "launch"
    parse_launch_args(tail)
  else if sub == "doctor"
    if tail.any?(fn(a) a == "--help" or a == "-h" end)
      Ok(ControlHelpCmd)
    else
      Ok(DoctorCmd(run_id: try parse_run_id_only(tail, "doctor")))
    end
  else if sub == "inspect"
    parse_inspect_args(tail)
  else if sub == "reset"
    parse_reset_args(tail)
  else if sub == "drive"
    parse_drive_args(tail)
  else if sub == "screenshot"
    parse_media_args(tail, true)
  else if sub == "record"
    parse_media_args(tail, false)
  else if sub == "cleanup"
    if tail.any?(fn(a) a == "--help" or a == "-h" end)
      Ok(ControlHelpCmd)
    else
      Ok(CleanupCmd(run_id: try parse_run_id_only(tail, "cleanup")))
    end
  else if sub == "sha"
    if tail.any?(fn(a) a == "--help" or a == "-h" end)
      Ok(ControlHelpCmd)
    else if not tail.empty?
      Error("unknown flag '#{tail.first or ""}' for `arvo control sha`.")
    else
      Ok(ShaCmd)
    end
  else
    Error("unknown control subcommand '#{sub}'. Run `arvo control --help`.")
  end
end

fn join_path(app_dir: Text, rel: Text) : Text
  if app_dir == ".": rel else: "#{app_dir}/#{rel}"
end

struct ControlTimeouts
  git_secs: Int
  mo_secs: Int
  sqlite_secs: Int
  quick_secs: Int
  http_secs: Int
  browser_secs: Int
  ready_polls: Int
  ready_poll_ms: Int
  hold_poll_ms: Int
  stop_polls: Int
  kill_polls: Int
end

fn default_control_timeouts() : ControlTimeouts
  ControlTimeouts(
    git_secs: 5,
    mo_secs: 30,
    sqlite_secs: 10,
    quick_secs: 5,
    http_secs: 3,
    browser_secs: 180,
    ready_polls: 100,
    ready_poll_ms: 100,
    hold_poll_ms: 150,
    stop_polls: 20,
    kill_polls: 15
  )
end

## Extracts the first `sqlite <name> from "<file>"` path from `entry` source (defaults to `"starter.sqlite"`).
fn detect_sqlite_filename(entry_src: Text) : Text
  for raw in entry_src.lines
    trimmed = raw.trim
    if trimmed.starts_with?("sqlite ") and trimmed.contains?(" from \"")
      after_from = (trimmed.split(" from \"").get(1) or "")
      fname = (after_from.split("\"").first or "").trim
      if not fname.empty? and not fname.contains?("..")
        return fname
      end
    end
  end
  "starter.sqlite"
end

## Computes deterministic build identity: git HEAD when accessible, `ARVO_GIT_HEAD`, or source SHA-256.
fn compute_build_sha(app_files: ReadFiles, cfg: Config.ArvoConfig, cmd: Command, env: Env) : Text
  t = default_control_timeouts()
  if cmd.run("git", ["rev-parse", "HEAD"], t.git_secs.seconds) is Ok(out)
    sha = out.stdout.trim
    if out.ok? and not sha.empty?
      return sha
    end
  end
  if env.get("ARVO_GIT_HEAD") is Some(head_sha)
    if not head_sha.trim.empty?
      return head_sha.trim
    end
  end
  var paths = [cfg.entry, "routes.mo", "arvo.toml", cfg.contracts_out]
  fdir = cfg.frontend_dir.drop_suffix("/") or cfg.frontend_dir
  if not fdir.empty?
    for sub in ["src/pages", "src/lib"]
      sub_dir = "#{fdir}/#{sub}"
      for rel in count_files_under(app_files, sub_dir)
        paths = paths.append("#{sub_dir}/#{rel}")
      end
    end
    pw_path = "#{fdir}/scripts/arvo-playwright.mjs"
    if app_files.exists?(pw_path)
      paths = paths.append(pw_path)
    end
  end
  var parts = []
  for p in paths
    if app_files.read_text(p) is Ok(txt)
      parts = parts.append("#{p}\n#{txt}")
    end
  end
  "src:#{Crypto.sha256(parts.join("\n---\n").bytes).to_hex}"
end

fn run_dir_rel(run_id: Text) : Text
  ".arvo/runs/#{run_id}"
end

fn evidence_dir_rel(run_id: Text) : Text
  ".arvo/evidence/#{run_id}"
end

fn run_handle_rel(run_id: Text) : Text
  "#{run_dir_rel(run_id)}/run.json"
end

fn make_default_run_id(clock: Clock) : Text
  raw = clock.now.to_text
  safe = raw.replace(":", "-").replace(".", "-")
  "run-#{safe}"
end

fn copy_public_assets(app_files: Files, data_rel: Text) : Result(Unit, Text)
  return Ok(Unit) if not app_files.exists?("public/manifest.json")
  try app_files.make_folder("#{data_rel}/public/assets").map_error(fn(e) "#{e}" end)
  mbytes = try app_files.read_bytes("public/manifest.json").map_error(fn(e) "#{e}" end)
  try app_files.write_bytes("#{data_rel}/public/manifest.json", mbytes).map_error(fn(e) "#{e}" end)
  if app_files.exists?("public/assets")
    entries = try app_files.walk("public/assets").map_error(fn(e) "#{e}" end)
    for ent in entries
      if ent.kind is File
        src = "public/assets/#{ent.name}"
        dst = "#{data_rel}/public/assets/#{ent.name}"
        sub_parts = ent.name.split("/")
        parent_sub = sub_parts.take(sub_parts.size - 1).join("/")
        if not parent_sub.empty?
          _mk = app_files.make_folder("#{data_rel}/public/assets/#{parent_sub}")
        end
        bytes = try app_files.read_bytes(src).map_error(fn(e) "#{e}" end)
        try app_files.write_bytes(dst, bytes).map_error(fn(e) "#{e}" end)
      end
    end
  end
  Ok(Unit)
end

fn append_control_log(app_files: Files, run_id: Text, clock: Clock, msg: Text) : Unit
  _mk = app_files.make_folder(run_dir_rel(run_id))
  _ap = app_files.append_text("#{run_dir_rel(run_id)}/control.log", "[#{clock.now.to_text}] #{msg}\n")
end

fn load_run_handle(app_files: ReadFiles, run_id: Text) : Result(RunHandle, Text)
  path = run_handle_rel(run_id)
  raw = try app_files.read_text(path).map_error(fn(_) "run '#{run_id}' not found (#{path})" end)
  Json.decode_strict[RunHandle](raw).map_error(fn(e) "corrupt #{path}: #{e.to_text}" end)
end

fn probe_http_ok?(url: Text, net: Network) : Bool
  t = default_control_timeouts()
  case Http.get("#{url}/login").within(t.http_secs.seconds).send(
    net.allow_hosts(["127.0.0.1", "localhost"])
  )
    Ok(resp): resp.status == 200
    Error(_): false
  end
end

fn count_files_under(files: ReadFiles, dir_rel: Text) : List(Text)
  case files.walk(dir_rel)
    Error(_): []
    Ok(ents):
      ents.filter_map(fn(ent)
        if ent.kind is File: Some(ent.name) else: None
      end).sort
  end
end

fn remove_tree_in_run_dir(app_dir: Text, app_files: Files, rel_dir: Text, cmd: Command) : Result(
  Bool,
  Text
)
  t = default_control_timeouts()
  return Error("refusing to delete path outside .arvo/runs/: #{rel_dir}") if not rel_dir.starts_with?(
    ".arvo/runs/"
  )
  if app_files.walk(rel_dir) is Ok(ents)
    for ent in ents
      if ent.kind is File
        _rm = app_files.remove("#{rel_dir}/#{ent.name}")
      end
    end
  end
  # Also remove real on-disk directories inside .arvo/runs/ when running outside in-memory fakes
  case cmd.run("rm", ["-rf", join_path(app_dir, rel_dir)], t.quick_secs.seconds)
    Error(err): return Error("failed removing #{rel_dir}: #{err}")
    Ok(out):
      if not out.ok?
        return Error("failed removing #{rel_dir}: #{out.stderr.trim}")
      end
  end
  Ok(count_files_under(app_files.read_only, rel_dir).empty?)
end

fn wait_for_ready_file(
  files: ReadFiles,
  ready_rel: Text,
  proc: Command.Process,
  clock: Clock
) : Result(Text, Text)
  t = default_control_timeouts()
  var tries = 0
  while tries < t.ready_polls and not files.exists?(ready_rel) and proc.alive?
    clock.sleep(t.ready_poll_ms.milliseconds)
    tries += 1
  end
  if not files.exists?(ready_rel)
    return Error("mo serve did not write ready.json within 10s")
  end
  files.read_text(ready_rel).map_error(fn(e) "failed reading #{ready_rel}: #{e}" end)
end

fn complete_launch(
  app_dir: Text,
  run_id: Text,
  ready_raw: Text,
  fallback_pid: Int,
  data_cmd_path: Text,
  edir_rel: Text,
  sqlite_file: Text,
  build_sha: Text,
  seed: Text,
  app_files: Files,
  clock: Clock,
  net: Network,
  console: Console
) : Result(RunHandle, Text)
  ready_doc = try Json.parse(ready_raw).map_error(fn(e) "invalid ready.json: #{e}" end)
  url = ready_doc.text_at("url") or ""
  port = ready_doc.int_at("port") or 0
  srv_pid = ready_doc.int_at("pid") or fallback_pid
  started_at = ready_doc.text_at("started_at") or clock.now.to_text
  if url.empty? or port <= 0
    return Error("ready.json missing url/port: #{ready_raw}")
  end
  if not probe_http_ok?(url, net)
    return Error("server at #{url} failed /login readiness probe")
  end

  handle = RunHandle(
    run_id: run_id,
    pid: srv_pid,
    url: url,
    port: port,
    data_dir: data_cmd_path,
    evidence_dir: join_path(app_dir, edir_rel),
    sqlite_file: sqlite_file,
    build_sha: build_sha,
    seed_profile: seed,
    started_at: started_at
  )
  handle_json = Json.encode(handle)
  _w = try app_files.write_text(run_handle_rel(run_id), "#{handle_json}\n").map_error(
    fn(e) "failed writing run.json: #{e}" end
  )
  append_control_log(app_files, run_id, clock, "launch pid=#{srv_pid} url=#{url} seed=#{seed}")
  console.print(handle_json)
  Ok(handle)
end

fn hold_until_stopped(
  proc: Command.Process,
  stop_rel: Text,
  oneshot?: Bool,
  app_files: Files,
  clock: Clock
) : Int
  t = default_control_timeouts()
  if not oneshot?
    while proc.alive? and not app_files.exists?(stop_rel)
      clock.sleep(t.hold_poll_ms.milliseconds)
    end
  end
  _k = proc.kill()
  _rm = app_files.remove(stop_rel)
  0
end

fn fail_with(console: Console, msg: Text) : Int
  console.error(msg)
  1
end

fn run_launch_inner(
  app_dir: Text,
  seed: Text,
  run_id_opt: Option(Text),
  oneshot?: Bool,
  cfg: Config.ArvoConfig,
  app_files: Files,
  cmd: Command,
  clock: Clock,
  env: Env,
  net: Network,
  console: Console
) : Result(Int, Text)
  t = default_control_timeouts()
  run_id = run_id_opt or make_default_run_id(clock)
  if not valid_run_id?(run_id)
    return Error("invalid --run-id '#{run_id}'")
  end

  rdir_rel = run_dir_rel(run_id)
  data_rel = "#{rdir_rel}/data"
  edir_rel = evidence_dir_rel(run_id)
  ready_rel = "#{rdir_rel}/ready.json"
  stop_rel = "#{rdir_rel}/stop"

  for dir_p in [rdir_rel, data_rel, edir_rel]
    _mk = try app_files.make_folder(dir_p).map_error(fn(e) "failed creating #{dir_p}: #{e}" end)
  end
  _rm_stop = app_files.remove(stop_rel)
  _rm_rdy = app_files.remove(ready_rel)

  try copy_public_assets(app_files, data_rel).map_error(
    fn(ce) "failed copying static assets: #{ce}" end
  )

  entry_src = case app_files.read_text(cfg.entry)
    Ok(s): s
    Error(_): ""
  end
  sqlite_file = detect_sqlite_filename(entry_src)
  entry_cmd_path = join_path(app_dir, cfg.entry)
  data_cmd_path = join_path(app_dir, data_rel)
  ready_cmd_path = join_path(app_dir, ready_rel)

  # Seed DB deterministically inside isolated data_dir before launching server
  seed_out = try cmd.run(
    "mo",
    ["run", "--state-dir", data_cmd_path, entry_cmd_path, "--arvo-seed", seed, "--db", sqlite_file],
    t.mo_secs.seconds
  ).map_error(fn(err) "seed command failed: #{err}" end)
  if not seed_out.ok?
    return Error("seed '#{seed}' failed:\n#{seed_out.stderr.trim}\n#{seed_out.stdout.trim}")
  end

  build_sha = compute_build_sha(app_files.read_only, cfg, cmd, env)

  # Always start `mo serve` and wait for ready.json BEFORE any loopback client spawns
  loop_cmd = cmd.allow_loopback()
  proc = try loop_cmd.spawn(
    "mo",
    ["serve", entry_cmd_path, "--port", "0", "--data", data_cmd_path, "--ready-file", ready_cmd_path]
  ).map_error(fn(err) "failed spawning mo serve: #{err}" end)

  ready_raw = try wait_for_ready_file(app_files.read_only, ready_rel, proc, clock)
  _handle = try complete_launch(
    app_dir,
    run_id,
    ready_raw,
    proc.pid,
    data_cmd_path,
    edir_rel,
    sqlite_file,
    build_sha,
    seed,
    app_files,
    clock,
    net,
    console
  )
  Ok(hold_until_stopped(proc, stop_rel, oneshot?, app_files, clock))
end

fn run_launch(
  app_dir: Text,
  seed: Text,
  run_id_opt: Option(Text),
  oneshot?: Bool,
  cfg: Config.ArvoConfig,
  app_files: Files,
  cmd: Command,
  clock: Clock,
  env: Env,
  net: Network,
  console: Console
) : Int
  case run_launch_inner(
    app_dir,
    seed,
    run_id_opt,
    oneshot?,
    cfg,
    app_files,
    cmd,
    clock,
    env,
    net,
    console
  )
    Ok(code): code
    Error(msg): fail_with(console, "arvo control launch: #{msg}")
  end
end

fn pid_alive?(cmd: Command, pid: Int) : Bool
  t = default_control_timeouts()
  return false if pid <= 0
  case cmd.run("test", ["-e", "/proc/#{pid}/stat"], t.quick_secs.seconds)
    Ok(out): out.ok?
    Error(_): false
  end
end

fn run_doctor(
  app_dir: Text,
  run_id: Text,
  cfg: Config.ArvoConfig,
  app_files: ReadFiles,
  cmd: Command,
  env: Env,
  net: Network,
  console: Console
) : Int
  t = default_control_timeouts()
  handle = case load_run_handle(app_files, run_id)
    Ok(h): h
    Error(e): return fail_with(console, "arvo control doctor: #{e}")
  end

  alive? = pid_alive?(cmd, handle.pid)
  http_ok? = probe_http_ok?(handle.url, net)
  cur_sha = compute_build_sha(app_files, cfg, cmd, env)
  sha_ok? = cur_sha == handle.build_sha

  db_path = join_path(app_dir, "#{run_dir_rel(run_id)}/data/#{handle.sqlite_file}")
  mig_check = case cmd.run(
    "sqlite3",
    ["-readonly", "-json", db_path, "SELECT COUNT(*) AS cnt FROM _arvo_migrations"],
    t.quick_secs.seconds
  )
    Ok(out):
      if out.ok?
        case Json.parse(out.stdout.trim)
          Ok(Json.Array(rows)):
            cnt = case rows.first
              Some(row): row.int_at("cnt") or 0
              None: 0
            end
            DoctorCheck(name: "migrations", ok?: cnt > 0, detail: "applied=#{cnt}")
          Ok(_) | Error(_): DoctorCheck(name: "migrations", ok?: false, detail: "unexpected sqlite3 output")
        end
      else
        DoctorCheck(name: "migrations", ok?: false, detail: out.stderr.trim)
      end
    Error(err): DoctorCheck(name: "migrations", ok?: false, detail: "#{err}")
  end

  ev_ok? = app_files.exists?(evidence_dir_rel(run_id))
  checks = [
    DoctorCheck(name: "pid_alive", ok?: alive?, detail: "pid=#{handle.pid}"),
    DoctorCheck(name: "http_login", ok?: http_ok?, detail: "#{handle.url}/login"),
    DoctorCheck(
      name: "build_sha",
      ok?: sha_ok?,
      detail: if sha_ok?: handle.build_sha else: "expected=#{handle.build_sha} current=#{cur_sha}"
    ),
    mig_check,
    DoctorCheck(name: "evidence_dir", ok?: ev_ok?, detail: handle.evidence_dir)
  ]
  healthy? = checks.all?(fn(c) c.ok? end)
  report = DoctorReport(run_id: run_id, healthy?: healthy?, checks: checks)
  console.print(Json.encode(report))
  if healthy?: 0 else: 1
end

fn run_sqlite_readonly_json(
  cmd: Command,
  db_path: Text,
  query: Text,
  within_secs: Int
) : Result(Text, Text)
  out = try cmd.run("sqlite3", ["-readonly", "-json", db_path, query], within_secs.seconds).map_error(
    fn(e) "#{e}" end
  )
  if not out.ok?
    return Error(out.stderr.trim)
  end
  trimmed = out.stdout.trim
  Ok(if trimmed.empty?: "[]" else: trimmed)
end

fn run_inspect(
  app_dir: Text,
  run_id: Text,
  mode: Text,
  sql_query: Option(Text),
  app_files: ReadFiles,
  cmd: Command,
  console: Console
) : Int
  t = default_control_timeouts()
  handle = case load_run_handle(app_files, run_id)
    Ok(h): h
    Error(e): return fail_with(console, "arvo control inspect: #{e}")
  end
  db_path = join_path(app_dir, "#{run_dir_rel(run_id)}/data/#{handle.sqlite_file}")

  if mode == "sql"
    case run_sqlite_readonly_json(cmd, db_path, sql_query or "", t.sqlite_secs)
      Ok(body):
        console.print(body)
        0
      Error(err): fail_with(console, "arvo control inspect --sql: #{err}")
    end
  else if mode == "audit"
    audit_q = "SELECT id, actor, action, entity_table, entity_id, reason, created_at FROM arvo_events ORDER BY created_at DESC, id DESC LIMIT 50"
    case run_sqlite_readonly_json(cmd, db_path, audit_q, t.sqlite_secs)
      Ok(body):
        console.print(body)
        0
      Error(err): fail_with(console, "arvo control inspect --audit: #{err}")
    end
  else if mode == "logs"
    clog = case app_files.read_text("#{run_dir_rel(run_id)}/control.log")
      Ok(s): s
      Error(_): ""
    end
    slog = case app_files.read_text("#{run_dir_rel(run_id)}/server.log")
      Ok(s): s
      Error(_): ""
    end
    console.print(
      Json.Object({
        "run_id": Json.String(run_id),
        "control_log": Json.String(clog),
        "server_log": Json.String(slog)
      }).to_text
    )
    0
  else
    # mode == "aria": read-only ARIA snapshot dump from evidence directory
    edir = evidence_dir_rel(run_id)
    aria_files = count_files_under(app_files, edir).filter(fn(f) f.ends_with?(".aria.txt") or f.starts_with?("aria-") end)
    var snapshots = {}
    for rel in aria_files
      if app_files.read_text("#{edir}/#{rel}") is Ok(txt)
        snapshots = snapshots.set(rel, Json.String(txt))
      end
    end
    console.print(Json.Object({"run_id": Json.String(run_id), "aria_snapshots": Json.Object(snapshots)}).to_text)
    0
  end
end

fn run_reset(
  app_dir: Text,
  run_id: Text,
  seed: Text,
  cfg: Config.ArvoConfig,
  app_files: Files,
  cmd: Command,
  clock: Clock,
  console: Console
) : Int
  t = default_control_timeouts()
  handle = case load_run_handle(app_files.read_only, run_id)
    Ok(h): h
    Error(e): return fail_with(console, "arvo control reset: #{e}")
  end
  entry_cmd_path = join_path(app_dir, cfg.entry)
  data_cmd_path = join_path(app_dir, "#{run_dir_rel(run_id)}/data")

  case cmd.run(
    "mo",
    ["run", "--state-dir", data_cmd_path, entry_cmd_path, "--arvo-reset", seed, "--db", handle.sqlite_file],
    t.mo_secs.seconds
  )
    Error(err): return fail_with(console, "arvo control reset: #{err}")
    Ok(out):
      if not out.ok?
        return fail_with(
          console,
          "arvo control reset: failed:\n#{out.stderr.trim}\n#{out.stdout.trim}"
        )
      end
  end

  updated = RunHandle(
    run_id: handle.run_id,
    pid: handle.pid,
    url: handle.url,
    port: handle.port,
    data_dir: handle.data_dir,
    evidence_dir: handle.evidence_dir,
    sqlite_file: handle.sqlite_file,
    build_sha: handle.build_sha,
    seed_profile: seed,
    started_at: handle.started_at
  )
  _w = app_files.write_text(run_handle_rel(run_id), "#{Json.encode(updated)}\n")
  append_control_log(app_files, run_id, clock, "reset seed=#{seed}")
  console.print(Json.Object({"run_id": Json.String(run_id), "reset": Json.String(seed)}).to_text)
  0
end

fn run_browser_script(
  app_dir: Text,
  run_id: Text,
  mode: Text,
  cdp_url: Option(Text),
  extra_args: List(Text),
  cfg: Config.ArvoConfig,
  app_files: Files,
  cmd: Command,
  clock: Clock,
  env: Env,
  net: Network,
  console: Console
) : Int
  t = default_control_timeouts()
  handle = case load_run_handle(app_files.read_only, run_id)
    Ok(h): h
    Error(e): return fail_with(console, "arvo control #{mode}: #{e}")
  end
  if not probe_http_ok?(handle.url, net)
    return fail_with(console, "arvo control #{mode}: server at #{handle.url} is not responding")
  end

  fdir = cfg.frontend_dir.drop_suffix("/") or cfg.frontend_dir
  script_rel = "#{fdir}/scripts/arvo-playwright.mjs"
  if not app_files.exists?(script_rel)
    return fail_with(console, "arvo control #{mode}: missing Playwright runner #{script_rel}")
  end

  var node_args = [
    "--openssl-config=/dev/null",
    "./scripts/arvo-playwright.mjs",
    "--mode",
    mode,
    "--base-url",
    handle.url,
    "--run-id",
    run_id,
    "--app-dir",
    app_dir,
    "--evidence-dir",
    evidence_dir_rel(run_id),
    "--build-sha",
    handle.build_sha
  ].concat(extra_args)

  eff_cdp = case cdp_url
    Some(u): Some(u)
    None: env.get("ARVO_CDP_URL")
  end
  if eff_cdp is Some(u)
    if not u.trim.empty?
      node_args = node_args.append("--cdp-url").append(u.trim)
    end
  end

  fdir_cmd = join_path(app_dir, fdir)
  case cmd.within(fdir_cmd).allow_loopback().allow_programs(["node"]).run(
    "node",
    node_args,
    t.browser_secs.seconds
  )
    Error(err): fail_with(console, "arvo control #{mode}: failed launching node Playwright runner: #{err}")
    Ok(out):
      if not out.stdout.trim.empty?
        console.print(out.stdout.trim)
      end
      if out.ok?
        append_control_log(app_files, run_id, clock, "#{mode} passed")
        0
      else
        if not out.stderr.trim.empty?
          console.error(out.stderr.trim)
        end
        append_control_log(app_files, run_id, clock, "#{mode} failed (exit #{out.status})")
        1
      end
  end
end

fn run_cleanup(
  app_dir: Text,
  run_id: Text,
  app_files: Files,
  cmd: Command,
  clock: Clock,
  console: Console
) : Int
  t = default_control_timeouts()
  handle = case load_run_handle(app_files.read_only, run_id)
    Ok(h): h
    Error(e): return fail_with(console, "arvo control cleanup: #{e}")
  end

  edir_rel = evidence_dir_rel(run_id)
  before_evidence = count_files_under(app_files.read_only, edir_rel)

  # Signal supervisor via stop sentinel first, then stop ONLY recorded handle.pid if still alive
  _w_stop = app_files.write_text("#{run_dir_rel(run_id)}/stop", "stop\n")
  var tries = 0
  while tries < t.stop_polls and pid_alive?(cmd, handle.pid)
    clock.sleep(t.ready_poll_ms.milliseconds)
    tries += 1
  end

  if pid_alive?(cmd, handle.pid)
    _term = cmd.run("kill", ["-TERM", "#{handle.pid}"], t.quick_secs.seconds)
    var k_tries = 0
    while k_tries < t.kill_polls and pid_alive?(cmd, handle.pid)
      clock.sleep(t.ready_poll_ms.milliseconds)
      k_tries += 1
    end
    if pid_alive?(cmd, handle.pid)
      _kill9 = cmd.run("kill", ["-KILL", "#{handle.pid}"], t.quick_secs.seconds)
      clock.sleep(t.ready_poll_ms.milliseconds)
    end
  end

  stopped? = not pid_alive?(cmd, handle.pid)
  data_removed? = case remove_tree_in_run_dir(app_dir, app_files, run_dir_rel(run_id), cmd)
    Ok(removed): removed
    Error(e): return fail_with(console, "arvo control cleanup: #{e}")
  end

  # Verify evidence directory and every pre-existing artifact survived teardown
  after_evidence = count_files_under(app_files.read_only, edir_rel)
  preserved? = app_files.exists?(edir_rel) and before_evidence.all?(fn(f) after_evidence.contains?(f) end)

  report = CleanupReport(
    run_id: run_id,
    pid: handle.pid,
    stopped?: stopped?,
    data_removed?: data_removed?,
    evidence_dir: handle.evidence_dir,
    evidence_files_preserved: after_evidence.size,
    preserved?: preserved?
  )
  console.print(Json.encode(report))
  if stopped? and data_removed? and preserved?: 0 else: 1
end

## Executes an `arvo control` subcommand with explicit capabilities.
fn run_control_cmd(
  app_dir: Text,
  cmd_val: ControlCmd,
  cfg: Config.ArvoConfig,
  app_files: Files,
  cmd: Command,
  clock: Clock,
  env: Env,
  net: Network,
  console: Console
) : Int
  case cmd_val
    ControlHelpCmd:
      console.print(control_usage())
      0
    ShaCmd:
      console.print(compute_build_sha(app_files.read_only, cfg, cmd, env))
      0
    LaunchCmd(seed: seed, run_id: rid_opt, oneshot?: oneshot?): run_launch(
      app_dir,
      seed,
      rid_opt,
      oneshot?,
      cfg,
      app_files,
      cmd,
      clock,
      env,
      net,
      console
    )
    DoctorCmd(run_id: rid): run_doctor(
      app_dir,
      rid,
      cfg,
      app_files.read_only,
      cmd,
      env,
      net,
      console
    )
    InspectCmd(run_id: rid, mode: m, sql_query: q): run_inspect(
      app_dir,
      rid,
      m,
      q,
      app_files.read_only,
      cmd,
      console
    )
    ResetCmd(run_id: rid, seed: seed): run_reset(
      app_dir,
      rid,
      seed,
      cfg,
      app_files,
      cmd,
      clock,
      console
    )
    DriveCmd(run_id: rid, cdp_url: cdp, viewport: vp, update_visual?: upd?):
      var args = ["--viewport", vp]
      if upd?
        args = args.append("--update-visual")
      end
      run_browser_script(app_dir, rid, "drive", cdp, args, cfg, app_files, cmd, clock, env, net, console)
    ScreenshotCmd(run_id: rid, out_path: out_p, cdp_url: cdp, path: p, viewport: vp):
      var args = ["--path", p, "--viewport", vp]
      if out_p is Some(op)
        args = args.append("--out").append(op)
      end
      run_browser_script(
        app_dir,
        rid,
        "screenshot",
        cdp,
        args,
        cfg,
        app_files,
        cmd,
        clock,
        env,
        net,
        console
      )
    RecordCmd(run_id: rid, out_path: out_p, cdp_url: cdp, viewport: vp):
      var args = ["--viewport", vp]
      if out_p is Some(op)
        args = args.append("--out").append(op)
      end
      run_browser_script(app_dir, rid, "record", cdp, args, cfg, app_files, cmd, clock, env, net, console)
    CleanupCmd(run_id: rid): run_cleanup(app_dir, rid, app_files, cmd, clock, console)
  end
end

test "parse_control_args, detect_sqlite_filename, timeouts, and valid_run_id? cover flags and errors"
  ct = default_control_timeouts()
  assert ct.git_secs == 5 and
    ct.mo_secs == 30 and
    ct.sqlite_secs == 10 and
    ct.quick_secs == 5 and
    ct.http_secs == 3 and
    ct.browser_secs == 180 and
    ct.ready_polls == 100 and
    ct.ready_poll_ms == 100 and
    ct.hold_poll_ms == 150 and
    ct.stop_polls == 20 and
    ct.kill_polls == 15
  assert valid_run_id?("run_01-a")
  assert valid_run_id?("a".repeat(64))
  assert not valid_run_id?("a".repeat(65))
  assert not valid_run_id?("")
  assert not valid_run_id?("../evil")
  assert not valid_run_id?("a/b")
  assert detect_sqlite_filename("api\n  sqlite db from \"app.sqlite\"\nend\n") == "app.sqlite"
  assert detect_sqlite_filename("api\n  sqlite db\n  # from \"bad.sqlite\"\nend\n") == "starter.sqlite"
  assert detect_sqlite_filename("api\nend\n") == "starter.sqlite"
  assert detect_sqlite_filename("sqlite x from \"../bad.sqlite\"\n") == "starter.sqlite"

  assert parse_control_args([]) == Ok(ControlHelpCmd)
  assert parse_control_args(["--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["-h"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["launch"]) == Ok(LaunchCmd(seed: "baseline", run_id: None, oneshot?: false))
  assert parse_control_args(["launch", "--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["launch", "-h"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["launch", "--seed", "many_bills", "--run-id", "r1", "--oneshot"]) ==
    Ok(LaunchCmd(seed: "many_bills", run_id: Some("r1"), oneshot?: true))
  assert parse_control_args(["doctor", "--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["doctor", "-h"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["doctor", "--run-id", "r1"]) == Ok(DoctorCmd(run_id: "r1"))
  assert parse_control_args(["inspect", "--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["inspect", "-h"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["inspect", "--run-id", "r1", "--sql", "SELECT 1"]) ==
    Ok(InspectCmd(run_id: "r1", mode: "sql", sql_query: Some("SELECT 1")))
  assert parse_control_args(["inspect", "--run-id", "r1", "--audit"]) ==
    Ok(InspectCmd(run_id: "r1", mode: "audit", sql_query: None))
  assert parse_control_args(["inspect", "--run-id", "r1", "--logs"]) ==
    Ok(InspectCmd(run_id: "r1", mode: "logs", sql_query: None))
  assert parse_control_args(["inspect", "--run-id", "r1", "--aria"]) ==
    Ok(InspectCmd(run_id: "r1", mode: "aria", sql_query: None))
  assert parse_control_args(["reset", "--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["reset", "-h"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["reset", "--seed", "empty", "--run-id", "r1"]) ==
    Ok(ResetCmd(run_id: "r1", seed: "empty"))
  assert parse_control_args(["reset", "--run-id", "r1", "--seed", "empty"]) ==
    Ok(ResetCmd(run_id: "r1", seed: "empty"))
  assert parse_control_args(["drive", "--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["drive", "-h"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["drive", "--run-id", "r1"]) ==
    Ok(DriveCmd(run_id: "r1", cdp_url: None, viewport: "all", update_visual?: false))
  assert parse_control_args(["drive", "--run-id", "r1", "--cdp-url", "http://127.0.0.1:9222", "--viewport", "mobile", "--update-visual"]) ==
    Ok(DriveCmd(run_id: "r1", cdp_url: Some("http://127.0.0.1:9222"), viewport: "mobile", update_visual?: true))
  assert parse_control_args(["screenshot", "--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["screenshot", "-h"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["screenshot", "--out", "shot.png", "--path", "/login", "--viewport", "mobile", "--cdp-url", "http://127.0.0.1:9222", "--run-id", "r1"]) ==
    Ok(ScreenshotCmd(run_id: "r1", out_path: Some("shot.png"), cdp_url: Some("http://127.0.0.1:9222"), path: "/login", viewport: "mobile"))
  assert parse_control_args(["record", "--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["record", "-h"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["record", "--out", "vid.webm", "--viewport", "desktop", "--run-id", "r1"]) ==
    Ok(RecordCmd(run_id: "r1", out_path: Some("vid.webm"), cdp_url: None, viewport: "desktop"))
  assert parse_control_args(["cleanup", "--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["cleanup", "-h"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["cleanup", "--run-id", "r1"]) == Ok(CleanupCmd(run_id: "r1"))
  assert parse_control_args(["sha"]) == Ok(ShaCmd)
  assert parse_control_args(["sha", "--help"]) == Ok(ControlHelpCmd)
  assert parse_control_args(["sha", "-h"]) == Ok(ControlHelpCmd)

  for bad in [
    ["bogus"],
    ["sha", "--bad"],
    ["launch", "--seed"],
    ["launch", "--run-id", "../x"],
    ["launch", "--bad"],
    ["doctor"],
    ["doctor", "--run-id", "bad/id"],
    ["doctor", "--run-id", "r1", "--extra"],
    ["doctor", "--bad"],
    ["inspect", "--run-id", "r1"],
    ["inspect", "--audit", "--logs", "--run-id", "r1"],
    ["inspect", "--run-id", "r1", "--sql", "SELECT 1", "--audit"],
    ["inspect", "--run-id", "r1", "--bad"],
    ["reset"],
    ["reset", "--bad", "--run-id", "r1"],
    ["drive"],
    ["drive", "--bad", "--run-id", "r1"],
    ["screenshot"],
    ["record"],
    ["cleanup"],
    ["cleanup", "--run-id", "r1", "--extra"],
    ["screenshot", "--run-id", "r1", "--bad"],
    ["record", "--run-id", "r1", "--path", "/"]
  ]
    assert parse_control_args(bad) is Error(_)
  end
  assert control_usage().contains?("cleanup")
end

test "run_control_cmd executes launch, doctor, inspect, reset, drive, and cleanup preserving evidence"
  t0 = Time.parse("2026-11-25T21:00:00Z") or stop "t0"
  cfg = Config.default_config()
  ready_payload = "{\"url\":\"http://127.0.0.1:41999\",\"port\":41999,\"pid\":4242,\"started_at\":\"2026-11-25T21:00:00Z\"}\n"
  files = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": "module Main\napi\n  sqlite db from \"starter.sqlite\"\nend\n",
    "public/manifest.json": "{\"src/main.tsx\":{\"file\":\"assets/app.js\"}}",
    "public/assets/root.js": "console.log(0);",
    "public/assets/sub/app.js": "console.log(1);",
    "frontend/scripts/arvo-playwright.mjs": "// playwright driver",
    ".arvo/evidence/r1/shot.png": "PNG",
    ".arvo/evidence/r1/home.aria.txt": "- heading \"Ada\"",
    ".arvo/runs/r1/ready-present.json": ready_payload
  })

  replies = Command.replies([
    (
      Command.spec("mo", ["run", "--state-dir", "examples/app/.arvo/runs/r1/data", "examples/app/main.mo", "--arvo-seed", "baseline", "--db", "starter.sqlite"]),
      Command.ok_output("{\"seeded\":\"baseline\"}\n")
    ),
    (Command.spec("git", ["rev-parse", "HEAD"]), Command.ok_output("abc1234\n")),
    (
      Command.spec("mo", ["serve", "examples/app/main.mo", "--port", "0", "--data", "examples/app/.arvo/runs/r1/data", "--ready-file", "examples/app/.arvo/runs/r1/ready.json"]),
      Command.ok_output("")
    ),
    (Command.spec("test", ["-e", "/proc/0/stat"]), Command.ok_output("")),
    (Command.spec("test", ["-e", "/proc/1/stat"]), Command.ok_output("")),
    (Command.spec("test", ["-e", "/proc/4242/stat"]), Command.ok_output("")),
    (
      Command.spec("sqlite3", ["-readonly", "-json", "examples/app/.arvo/runs/r1/data/starter.sqlite", "SELECT COUNT(*) AS cnt FROM _arvo_migrations"]),
      Command.ok_output("[{\"cnt\":1}]\n")
    ),
    (
      Command.spec("sqlite3", ["-readonly", "-json", "examples/app/.arvo/runs/r1/data/starter.sqlite", "SELECT id FROM bills"]),
      Command.ok_output("[{\"id\":1}]\n")
    ),
    (
      Command.spec("sqlite3", ["-readonly", "-json", "examples/app/.arvo/runs/r1/data/starter.sqlite", "DELETE FROM bills"]),
      Command.output(1, "", "Error: attempt to write a readonly database")
    ),
    (
      Command.spec("sqlite3", ["-readonly", "-json", "examples/app/.arvo/runs/r1/data/starter.sqlite", "SELECT id, actor, action, entity_table, entity_id, reason, created_at FROM arvo_events ORDER BY created_at DESC, id DESC LIMIT 50"]),
      Command.ok_output("[{\"action\":\"auth.login\"}]\n")
    ),
    (
      Command.spec("mo", ["run", "--state-dir", "examples/app/.arvo/runs/r1/data", "examples/app/main.mo", "--arvo-reset", "empty", "--db", "starter.sqlite"]),
      Command.ok_output("{\"reset\":\"empty\"}\n")
    ),
    (
      Command.spec("node", ["--openssl-config=/dev/null", "./scripts/arvo-playwright.mjs", "--mode", "drive", "--base-url", "http://127.0.0.1:41999", "--run-id", "r1", "--app-dir", "examples/app", "--evidence-dir", ".arvo/evidence/r1", "--build-sha", "abc1234", "--viewport", "all"])
        .in_folder("examples/app/frontend"),
      Command.ok_output("   \n")
    ),
    (
      Command.spec("node", ["--openssl-config=/dev/null", "./scripts/arvo-playwright.mjs", "--mode", "screenshot", "--base-url", "http://127.0.0.1:41999", "--run-id", "r1", "--app-dir", "examples/app", "--evidence-dir", ".arvo/evidence/r1", "--build-sha", "abc1234", "--path", "/", "--viewport", "desktop", "--out", "s.png", "--cdp-url", "http://127.0.0.1:9222"])
        .in_folder("examples/app/frontend"),
      Command.ok_output("{\"shot\":\"s.png\"}\n")
    ),
    (
      Command.spec("node", ["--openssl-config=/dev/null", "./scripts/arvo-playwright.mjs", "--mode", "record", "--base-url", "http://127.0.0.1:41999", "--run-id", "r1", "--app-dir", "examples/app", "--evidence-dir", ".arvo/evidence/r1", "--build-sha", "abc1234", "--viewport", "mobile", "--out", "v.webm"])
        .in_folder("examples/app/frontend"),
      Command.output(1, "", "   \n")
    ),
    (Command.spec("rm", ["-rf", "examples/app/.arvo/runs/r1"]), Command.ok_output(""))
  ])

  net = Network.fake(
    Http.replies([
      (Http.get("http://127.0.0.1:41999/login").within(3.seconds), Http.reply(200, "<html>login</html>"))
    ])
  )

  # 0. ControlHelpCmd + pid_alive? boundaries
  c_help = Console.fake()
  assert run_control_cmd(
    "examples/app",
    ControlHelpCmd,
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_help
  ) ==
    0
  assert c_help.printed.any?(fn(l) l.contains?("cleanup") end)
  assert not pid_alive?(Command.fake(replies), 0)
  assert not pid_alive?(Command.fake(replies), -1)
  assert pid_alive?(Command.fake(replies), 1)
  assert not pid_alive?(Command.fake(replies).allow_programs([]), 4242)

  # 1. Launch error branches + wait_for_ready_file timing + complete_launch + hold_until_stopped
  assert run_control_cmd(
    "examples/app",
    LaunchCmd(seed: "baseline", run_id: Some("bad/id"), oneshot?: true),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  assert run_control_cmd(
    "examples/app",
    LaunchCmd(seed: "baseline", run_id: Some("r1"), oneshot?: true),
    cfg,
    files,
    Command.fake(replies).allow_programs([]),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  rep_seed_bad = Command.replies([
    (
      Command.spec("mo", ["run", "--state-dir", "examples/app/.arvo/runs/r1/data", "examples/app/main.mo", "--arvo-seed", "baseline", "--db", "starter.sqlite"]),
      Command.output(1, "", "bad seed")
    )
  ])
  c_seed_bad = Console.fake()
  assert run_control_cmd(
    "examples/app",
    LaunchCmd(seed: "baseline", run_id: Some("r1"), oneshot?: true),
    cfg,
    files,
    Command.fake(rep_seed_bad),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_seed_bad
  ) ==
    1
  assert c_seed_bad.printed_errors.any?(fn(e) e.contains?("seed 'baseline' failed") end)
  rep_no_spawn = Command.replies([
    (
      Command.spec("mo", ["run", "--state-dir", "examples/app/.arvo/runs/r1/data", "examples/app/main.mo", "--arvo-seed", "baseline", "--db", "starter.sqlite"]),
      Command.ok_output("{\"seeded\":\"baseline\"}\n")
    ),
    (Command.spec("git", ["rev-parse", "HEAD"]), Command.ok_output("abc1234\n"))
  ])
  assert run_control_cmd(
    "examples/app",
    LaunchCmd(seed: "baseline", run_id: Some("r1"), oneshot?: true),
    cfg,
    files,
    Command.fake(rep_no_spawn),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1

  files_blocked = Files.in_memory({".arvo": "blocker"})
  assert run_control_cmd(
    "examples/app",
    LaunchCmd(seed: "baseline", run_id: Some("r1"), oneshot?: true),
    cfg,
    files_blocked,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  files_pub_blocked = Files.in_memory({
    "public/manifest.json": "{}",
    ".arvo/runs/r1/data/public": "file-blocker"
  })
  assert run_control_cmd(
    "examples/app",
    LaunchCmd(seed: "baseline", run_id: Some("r1"), oneshot?: true),
    cfg,
    files_pub_blocked,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1

  c_wait_bad = Console.fake()
  assert run_control_cmd(
    "examples/app",
    LaunchCmd(seed: "baseline", run_id: Some("r1"), oneshot?: true),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_wait_bad
  ) ==
    1
  assert c_wait_bad.printed_errors.any?(fn(e) e.contains?("ready.json") end)
  assert files.exists?(".arvo/runs/r1/data/public/manifest.json")
  assert files.exists?(".arvo/runs/r1/data/public/assets/root.js")
  assert files.exists?(".arvo/runs/r1/data/public/assets/sub/app.js")
  assert files.entries(".arvo/runs/r1/data/public/assets/root.js") is Error(_)
  assert files.entries(".arvo/runs/r1/data/public/assets/sub/app.js") is Error(_)
  assert not files.exists?(".arvo/runs/r1/data/public/assets/sub/app.js/x")

  assert Command.fake(replies).spawn(
    "mo",
    ["serve", "examples/app/main.mo", "--port", "0", "--data", "examples/app/.arvo/runs/r1/data", "--ready-file", "examples/app/.arvo/runs/r1/ready.json"]
  ) is Ok(fake_proc)
  clk_present = Clock.fixed(t0)
  assert wait_for_ready_file(
    files.read_only,
    ".arvo/runs/r1/ready-present.json",
    fake_proc,
    clk_present
  ) ==
    Ok(ready_payload)
  assert clk_present.now == t0
  clk_wait = Clock.fixed(t0)
  assert wait_for_ready_file(
    files.read_only,
    ".arvo/runs/r1/missing.json",
    fake_proc,
    clk_wait
  ) is
    Error(_)
  assert (clk_wait.now - t0).in_milliseconds == 10000

  c_l = Console.fake()
  assert complete_launch(
    "examples/app",
    "r1",
    ready_payload,
    99,
    "examples/app/.arvo/runs/r1/data",
    ".arvo/evidence/r1",
    "starter.sqlite",
    "abc1234",
    "baseline",
    files,
    Clock.fixed(t0),
    net,
    c_l
  ) is
    Ok(_)
  assert (c_l.printed.first or "").contains?("\"port\":41999")
  assert files.exists?(".arvo/runs/r1/run.json")
  assert hold_until_stopped(fake_proc, ".arvo/runs/r1/stop", true, files, Clock.fixed(t0)) == 0
  assert not fake_proc.alive?
  assert hold_until_stopped(fake_proc, ".arvo/runs/r1/stop", false, files, Clock.fixed(t0)) == 0
  assert Command.fake(replies).spawn(
    "mo",
    ["serve", "examples/app/main.mo", "--port", "0", "--data", "examples/app/.arvo/runs/r1/data", "--ready-file", "examples/app/.arvo/runs/r1/ready.json"]
  ) is Ok(fake_proc2)
  assert files.write_text(".arvo/runs/r1/stop", "stop\n") == Ok(Unit)
  assert hold_until_stopped(fake_proc2, ".arvo/runs/r1/stop", false, files, Clock.fixed(t0)) == 0
  assert not fake_proc2.alive?
  assert not files.exists?(".arvo/runs/r1/stop")

  # Error & boundary branches in complete_launch & compute_build_sha fallbacks
  for bad_ready in [
    "not-json",
    "{\"url\":\"\",\"port\":41999}",
    "{\"url\":\"http://127.0.0.1:41999\"}",
    "{\"url\":\"http://127.0.0.1:41999\",\"port\":0}",
    "{\"url\":\"http://127.0.0.1:41999\",\"port\":-1}",
    "{\"url\":\"http://127.0.0.1:49999\",\"port\":49999}"
  ]
    assert complete_launch(
      "examples/app",
      "r1",
      bad_ready,
      99,
      "d",
      "e",
      "s",
      "b",
      "baseline",
      files,
      Clock.fixed(t0),
      net,
      Console.fake()
    ) is
      Error(_)
  end
  net_p1 = Network.fake(
    Http.replies([
      (Http.get("http://127.0.0.1:41999/login").within(3.seconds), Http.reply(200, "ok"))
    ])
  )
  assert files.make_folder(".arvo/runs/r_p1") == Ok(Unit)
  assert complete_launch(
    "examples/app",
    "r_p1",
    "{\"url\":\"http://127.0.0.1:41999\",\"port\":1}",
    99,
    "examples/app/.arvo/runs/r_p1/data",
    ".arvo/evidence/r_p1",
    "starter.sqlite",
    "abc1234",
    "baseline",
    files,
    Clock.fixed(t0),
    net_p1,
    Console.fake()
  ) is
    Ok(h_p1)
  assert h_p1.pid == 99 and h_p1.port == 1

  rep_nogit = Command.replies([(Command.spec("git", ["rev-parse", "HEAD"]), Command.output(1, "", "err"))])
  rep_emptygit = Command.replies([(Command.spec("git", ["rev-parse", "HEAD"]), Command.ok_output("\n"))])
  assert compute_build_sha(files.read_only, cfg, Command.fake(rep_nogit), Env.of({"ARVO_GIT_HEAD": "envsha"})) ==
    "envsha"
  sha1 = compute_build_sha(files.read_only, cfg, Command.fake(rep_emptygit), Env.of({}))
  assert sha1.starts_with?("src:")
  files_fe = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": "module Main\n",
    "frontend/src/arvo.gen.ts": "export interface Home {}\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n",
    "frontend/src/lib/format.ts": "export const x = 1;\n",
    "frontend/scripts/arvo-playwright.mjs": "// v1\n"
  })
  sha_fe1 = compute_build_sha(files_fe.read_only, cfg, Command.fake(rep_emptygit), Env.of({}))
  assert files_fe.write_text("frontend/src/pages/Home.tsx", "export default function Home() { return <div/>; }\n") == Ok(Unit)
  sha_fe2 = compute_build_sha(files_fe.read_only, cfg, Command.fake(rep_emptygit), Env.of({}))
  assert sha_fe1 != sha_fe2
  assert files_fe.write_text("frontend/scripts/arvo-playwright.mjs", "// v2\n") == Ok(Unit)
  sha_fe3 = compute_build_sha(files_fe.read_only, cfg, Command.fake(rep_emptygit), Env.of({}))
  assert sha_fe2 != sha_fe3
  c_sha = Console.fake()
  assert run_control_cmd("examples/app", ShaCmd, cfg, files_fe, Command.fake(rep_emptygit), Clock.fixed(t0), Env.of({}), net, c_sha) == 0
  assert c_sha.printed == [sha_fe3]

  # 2. Doctor (healthy + all unhealthy migration branches)
  c_d = Console.fake()
  assert run_control_cmd(
    "examples/app",
    DoctorCmd(run_id: "r1"),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_d
  ) ==
    0
  assert (c_d.printed.first or "").contains?("\"healthy?\":true")
  assert run_control_cmd(
    "examples/app",
    DoctorCmd(run_id: "missing"),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  for bad_mig_reply in [
    Command.ok_output("[{\"cnt\":0}]\n"),
    Command.ok_output("[{}]\n"),
    Command.ok_output("[]\n"),
    Command.ok_output("bad-json\n"),
    Command.output(1, "", "sql err")
  ]
    rep_unhealthy = Command.replies([
      (Command.spec("git", ["rev-parse", "HEAD"]), Command.ok_output("different_sha\n")),
      (Command.spec("test", ["-e", "/proc/4242/stat"]), Command.output(1, "", "")),
      (
        Command.spec("sqlite3", ["-readonly", "-json", "examples/app/.arvo/runs/r1/data/starter.sqlite", "SELECT COUNT(*) AS cnt FROM _arvo_migrations"]),
        bad_mig_reply
      )
    ])
    c_uh = Console.fake()
    assert run_control_cmd(
      "examples/app",
      DoctorCmd(run_id: "r1"),
      cfg,
      files,
      Command.fake(rep_unhealthy),
      Clock.fixed(t0),
      Env.of({}),
      Network.fake({}),
      c_uh
    ) ==
      1
    assert (c_uh.printed.first or "").contains?("{\"name\":\"migrations\",\"ok?\":false")
  end
  c_uh_perm = Console.fake()
  assert run_control_cmd(
    "examples/app",
    DoctorCmd(run_id: "r1"),
    cfg,
    files,
    Command.fake(replies).allow_programs([]),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({}),
    c_uh_perm
  ) ==
    1
  assert (c_uh_perm.printed.first or "").contains?("{\"name\":\"migrations\",\"ok?\":false")

  # 3. Inspect: SQL ok, SQL write rejected, audit ok/fail, logs, aria, missing run
  c_sql = Console.fake()
  assert run_control_cmd(
    "examples/app",
    InspectCmd(run_id: "r1", mode: "sql", sql_query: Some("SELECT id FROM bills")),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_sql
  ) ==
    0
  assert (c_sql.printed.first or "").contains?("\"id\":1")
  assert run_control_cmd(
    "examples/app",
    InspectCmd(run_id: "r1", mode: "sql", sql_query: Some("DELETE FROM bills")),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  assert run_control_cmd(
    "examples/app",
    InspectCmd(run_id: "r1", mode: "sql", sql_query: Some("SELECT 1")),
    cfg,
    files,
    Command.fake(replies).allow_programs([]),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  c_aud = Console.fake()
  assert run_control_cmd(
    "examples/app",
    InspectCmd(run_id: "r1", mode: "audit", sql_query: None),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_aud
  ) ==
    0
  assert (c_aud.printed.first or "").contains?("auth.login")
  assert run_control_cmd(
    "examples/app",
    InspectCmd(run_id: "r1", mode: "audit", sql_query: None),
    cfg,
    files,
    Command.fake(replies).allow_programs([]),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  c_log = Console.fake()
  assert run_control_cmd(
    "examples/app",
    InspectCmd(run_id: "r1", mode: "logs", sql_query: None),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_log
  ) ==
    0
  assert (c_log.printed.first or "").contains?("launch pid=4242")
  c_aria = Console.fake()
  assert run_control_cmd(
    "examples/app",
    InspectCmd(run_id: "r1", mode: "aria", sql_query: None),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_aria
  ) ==
    0
  assert (c_aria.printed.first or "").contains?("Ada")
  assert run_control_cmd(
    "examples/app",
    InspectCmd(run_id: "missing", mode: "logs", sql_query: None),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1

  # 4. Reset, Drive, Screenshot, Record (success + blank stdout/stderr + error paths)
  assert run_control_cmd(
    "examples/app",
    ResetCmd(run_id: "r1", seed: "empty"),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    0
  assert run_control_cmd(
    "examples/app",
    ResetCmd(run_id: "missing", seed: "empty"),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  assert run_control_cmd(
    "examples/app",
    ResetCmd(run_id: "r1", seed: "empty"),
    cfg,
    files,
    Command.fake(replies).allow_programs([]),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  rep_rst_fail = Command.replies([
    (
      Command.spec("mo", ["run", "--state-dir", "examples/app/.arvo/runs/r1/data", "examples/app/main.mo", "--arvo-reset", "bad", "--db", "starter.sqlite"]),
      Command.output(1, "", "bad seed")
    )
  ])
  assert run_control_cmd(
    "examples/app",
    ResetCmd(run_id: "r1", seed: "bad"),
    cfg,
    files,
    Command.fake(rep_rst_fail),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1

  c_drv = Console.fake()
  assert run_control_cmd(
    "examples/app",
    DriveCmd(run_id: "r1", cdp_url: None, viewport: "all", update_visual?: false),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_drv
  ) ==
    0
  assert c_drv.printed.empty?
  assert run_control_cmd(
    "examples/app",
    DriveCmd(run_id: "missing", cdp_url: None, viewport: "all", update_visual?: false),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  assert run_control_cmd(
    "examples/app",
    DriveCmd(run_id: "r1", cdp_url: None, viewport: "all", update_visual?: false),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({}),
    Console.fake()
  ) ==
    1
  assert run_control_cmd(
    "examples/app",
    DriveCmd(run_id: "r1", cdp_url: None, viewport: "all", update_visual?: false),
    cfg,
    files,
    Command.fake(replies).allow_programs([]),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  assert run_control_cmd(
    "examples/app",
    ScreenshotCmd(run_id: "r1", out_path: Some("s.png"), cdp_url: None, path: "/", viewport: "desktop"),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({"ARVO_CDP_URL": "http://127.0.0.1:9222"}),
    net,
    Console.fake()
  ) ==
    0
  c_rec = Console.fake()
  assert run_control_cmd(
    "examples/app",
    RecordCmd(run_id: "r1", out_path: Some("v.webm"), cdp_url: None, viewport: "mobile"),
    cfg,
    files,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_rec
  ) ==
    1
  assert c_rec.printed_errors.empty?
  assert files.read_text(".arvo/runs/r1/run.json") is Ok(r1_run_json)
  files_no_pw = Files.in_memory({
    ".arvo/runs/r1/run.json": r1_run_json
  })
  assert run_control_cmd(
    "examples/app",
    DriveCmd(run_id: "r1", cdp_url: None, viewport: "all", update_visual?: false),
    cfg,
    files_no_pw,
    Command.fake(replies),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1

  # 5. Cleanup (preserving evidence files + missing run + missing evidence dir + kill escalation)
  assert remove_tree_in_run_dir("examples/app", files, "bad/path", Command.fake(replies)) is Error(_)
  assert remove_tree_in_run_dir("examples/app", files, ".arvo/runs/r_p1", Command.fake(replies).allow_programs([])) is
    Error(_)
  replies_dead = Command.replies([
    (Command.spec("test", ["-e", "/proc/4242/stat"]), Command.output(1, "", "")),
    (Command.spec("rm", ["-rf", "examples/app/.arvo/runs/r1"]), Command.ok_output(""))
  ])
  c_clean = Console.fake()
  assert run_control_cmd(
    "examples/app",
    CleanupCmd(run_id: "r1"),
    cfg,
    files,
    Command.fake(replies_dead),
    Clock.fixed(t0),
    Env.of({}),
    net,
    c_clean
  ) ==
    0
  assert (c_clean.printed.first or "").contains?("\"preserved?\":true")
  assert not files.exists?(".arvo/runs/r1/run.json")
  assert files.exists?(".arvo/evidence/r1/shot.png")

  # Missing run handle returns 1
  assert run_control_cmd(
    "examples/app",
    CleanupCmd(run_id: "r1"),
    cfg,
    files,
    Command.fake(replies_dead),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1

  # Missing evidence_dir fails preserved? check (`exists?(edir_rel) and true` -> false)
  r3_json = "{\"run_id\":\"r3\",\"pid\":4242,\"url\":\"http://127.0.0.1:41999\",\"port\":41999,\"data_dir\":\"d\",\"evidence_dir\":\"e\",\"sqlite_file\":\"starter.sqlite\",\"build_sha\":\"abc1234\",\"seed_profile\":\"baseline\",\"started_at\":\"2026-11-25T21:00:00Z\"}"
  files_no_ev = Files.in_memory({".arvo/runs/r3/run.json": r3_json})
  rep_r3 = Command.replies([
    (Command.spec("test", ["-e", "/proc/4242/stat"]), Command.output(1, "", "")),
    (Command.spec("rm", ["-rf", "examples/app/.arvo/runs/r3"]), Command.ok_output(""))
  ])
  assert run_control_cmd(
    "examples/app",
    CleanupCmd(run_id: "r3"),
    cfg,
    files_no_ev,
    Command.fake(rep_r3),
    Clock.fixed(t0),
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1

  # Kill escalation when PID refuses to stop (exact poll durations asserted)
  assert files.make_folder(".arvo/runs/r2") == Ok(Unit)
  assert files.make_folder(".arvo/evidence/r2") == Ok(Unit)
  assert complete_launch(
    "examples/app",
    "r2",
    ready_payload,
    99,
    "examples/app/.arvo/runs/r2/data",
    ".arvo/evidence/r2",
    "starter.sqlite",
    "abc1234",
    "baseline",
    files,
    Clock.fixed(t0),
    net,
    Console.fake()
  ) is
    Ok(_)
  replies_term = Command.replies([
    (Command.spec("test", ["-e", "/proc/4242/stat"]), Command.ok_output("")),
    (Command.spec("kill", ["-TERM", "4242"]), Command.ok_output("")),
    (Command.spec("kill", ["-KILL", "4242"]), Command.ok_output("")),
    (Command.spec("rm", ["-rf", "examples/app/.arvo/runs/r2"]), Command.ok_output(""))
  ])
  clk_esc = Clock.fixed(t0)
  assert run_control_cmd(
    "examples/app",
    CleanupCmd(run_id: "r2"),
    cfg,
    files,
    Command.fake(replies_term),
    clk_esc,
    Env.of({}),
    net,
    Console.fake()
  ) ==
    1
  assert (clk_esc.now - t0).in_milliseconds == 3600
end
