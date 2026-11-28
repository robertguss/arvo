## `arvo dev` local full-stack development supervisor running Vite HMR alongside `mo serve --watch`
## with isolated dev mailbox defaults (`ARVO_DEV=1`, `ARVO_INSECURE_COOKIES=1`).
module DevCmd
expose DevArgs(..),
DevPlan(..),
dev_usage,
parse_dev_args,
shell_quote,
build_dev_plan,
build_supervisor_script,
run_dev
use Command
use Config

## Parsed CLI options for `arvo dev`.
struct DevArgs
  port: Int
  vite_port: Int
  no_vite?: Bool
  dry_run?: Bool
  emit_script?: Bool
  help?: Bool
end

## Resolved command plan and dev environment emitted by `--dry-run` and executed live.
struct DevPlan
  app_dir: Text
  entry: Text
  frontend_dir: Text
  backend_url: Text
  dev_dashboard_url: Text
  mailbox_dir: Text
  vite_enabled?: Bool
  vite_url: Option(Text)
  backend_cmd: Text
  vite_cmd: Option(Text)
  env_vars: Map(Text, Text)
end

## Usage text for `arvo dev`.
fn dev_usage() : Text
  """
    usage: arvo dev [--app DIR] [--port 8080] [--vite-port 5173] [--no-vite] [--dry-run] [--emit-script]

    Starts Vite HMR and `mo serve --watch` under one clean signal-trapped supervisor with
    `ARVO_DEV=1`, `ARVO_INSECURE_COOKIES=1`, and local Dev Mailbox enabled at `.arvo/mailbox`.

    Flags:
      --app DIR          Target application subdirectory (default: `.`)
      --port PORT        Backend HTTP port (default: 8080)
      --vite-port PORT   Vite HMR port (default: 5173)
      --no-vite          Run only `mo serve --watch` (disable Vite HMR)
      --dry-run          Print resolved DevPlan JSON without launching processes
      --emit-script      Print POSIX supervisor shell script for host execution
      -h, --help         Show this help
    """
end

fn need_val(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("`#{flag}` requires a value. Run `arvo dev --help`.")
  else
    Ok(v)
  end
end

fn valid_port?(p: Int) : Bool
  p >= 1 and p <= 65535
end

## Parses arguments after `arvo dev`.
fn parse_dev_args(rest: List(Text)) : Result(DevArgs, Text)
  var port = 8080
  var vite_port = 5173
  var no_vite? = false
  var dry_run? = false
  var emit_script? = false
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(
        DevArgs(
          port: port,
          vite_port: vite_port,
          no_vite?: no_vite?,
          dry_run?: dry_run?,
          emit_script?: emit_script?,
          help?: true
        )
      )
    else if a == "--no-vite"
      no_vite? = true
    else if a == "--dry-run"
      dry_run? = true
    else if a == "--emit-script"
      emit_script? = true
    else if a == "--port"
      raw = try need_val(rest, i, "--port")
      parsed = try raw.to_int.or_fail("invalid --port '#{raw}' (expected 1..65535)")
      if not valid_port?(parsed)
        return Error("--port must be between 1 and 65535, got #{parsed}")
      end
      port = parsed
      i += 1
    else if a == "--vite-port"
      raw = try need_val(rest, i, "--vite-port")
      parsed = try raw.to_int.or_fail("invalid --vite-port '#{raw}' (expected 1..65535)")
      if not valid_port?(parsed)
        return Error("--vite-port must be between 1 and 65535, got #{parsed}")
      end
      vite_port = parsed
      i += 1
    else
      return Error("unknown flag '#{a}' for `arvo dev`. Run `arvo dev --help`.")
    end
    i += 1
  end
  if not no_vite? and port == vite_port
    return Error("--port and --vite-port cannot be equal (#{port})")
  end
  Ok(
    DevArgs(
      port: port,
      vite_port: vite_port,
      no_vite?: no_vite?,
      dry_run?: dry_run?,
      emit_script?: emit_script?,
      help?: false
    )
  )
end

## POSIX single-quote escapes `raw` for safe embedded `sh -c` scripts.
fn shell_quote(raw: Text) : Text
  escaped = raw.replace("'", "'\\''")
  "'#{escaped}'"
end

fn non_empty_env(env: Env, name: Text, fallback: Text) : Text
  case env.get(name)
    Some(v) if not v.trim.empty?: v.trim
    Some(_) | None: fallback
  end
end

## Resolves commands, URLs, and safe local-dev environment defaults for `arvo dev`.
fn build_dev_plan(app_dir: Text, dargs: DevArgs, cfg: Config.ArvoConfig, files: ReadFiles, env: Env) : DevPlan
  fdir = cfg.frontend_dir.drop_suffix("/") or cfg.frontend_dir
  pkg_exists? = files.exists?("#{fdir}/package.json")
  vite_enabled? = (not dargs.no_vite?) and pkg_exists?
  vite_url = if vite_enabled?: Some("http://127.0.0.1:#{dargs.vite_port}") else: None
  backend_url = "http://127.0.0.1:#{dargs.port}"
  mailbox_dir = ".arvo/mailbox"
  secret_key = non_empty_env(
    env,
    "ARVO_SECRET_KEY",
    "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
  )
  seed_pw = non_empty_env(env, "ARVO_SEED_PASSWORD", "dev-password-change-me")
  allowlist = non_empty_env(env, "ARVO_ALLOWLIST", "ada@household.local,grace@household.local")

  var env_vars = {
    "ARVO_DEV": "1",
    "ARVO_INSECURE_COOKIES": "1",
    "ARVO_DEV_MAILBOX": mailbox_dir,
    "ARVO_SECRET_KEY": secret_key,
    "ARVO_SEED_PASSWORD": seed_pw,
    "ARVO_ALLOWLIST": allowlist
  }
  if vite_url is Some(vu)
    env_vars = env_vars.set("VITE_DEV_URL", vu)
  end

  vite_cmd = if vite_enabled?
    Some("npm --prefix #{shell_quote(fdir)} run dev -- --host 127.0.0.1 --port #{dargs.vite_port}")
  else
    None
  end
  backend_cmd = "mo serve --watch --bind 127.0.0.1 --port #{dargs.port} #{shell_quote(cfg.entry)}"

  DevPlan(
    app_dir: app_dir,
    entry: cfg.entry,
    frontend_dir: fdir,
    backend_url: backend_url,
    dev_dashboard_url: "#{backend_url}/__arvo",
    mailbox_dir: mailbox_dir,
    vite_enabled?: vite_enabled?,
    vite_url: vite_url,
    backend_cmd: backend_cmd,
    vite_cmd: vite_cmd,
    env_vars: env_vars
  )
end

## Generates the signal-trapped POSIX supervisor script starting optional Vite + `mo serve --watch`.
fn build_supervisor_script(plan: DevPlan) : Text
  var exports = []
  for (k, v) in plan.env_vars.entries.sort_by(fn(p) p.0 end)
    exports = exports.append("export #{k}=#{shell_quote(v)}")
  end
  export_block = exports.join("\n")

  case plan.vite_cmd
    Some(vcmd): """
      #{export_block}
      mkdir -p #{shell_quote(plan.mailbox_dir)}
      VITE_PID=""
      cleanup() {
        if [ -n "$VITE_PID" ]; then
          kill "$VITE_PID" 2>/dev/null || true
          wait "$VITE_PID" 2>/dev/null || true
        fi
      }
      trap cleanup INT TERM EXIT
      #{vcmd} &
      VITE_PID=$!
      exec #{plan.backend_cmd}
      """
    None: """
      #{export_block}
      mkdir -p #{shell_quote(plan.mailbox_dir)}
      exec #{plan.backend_cmd}
      """
  end
end

## Executes `arvo dev`, printing `--dry-run` plan JSON or running the dev server supervisor.
fn run_dev(
  app_dir: Text,
  dargs: DevArgs,
  app_files: Files,
  cmd: Command,
  env: Env,
  console: Console
) : Int
  if dargs.help?
    console.print(dev_usage())
    return 0
  end

  cfg = case Config.load(app_files.read_only)
    Ok(c): c
    Error(e):
      console.error("arvo dev: #{e}")
      return 1
  end

  if not app_files.read_only.exists?(cfg.entry)
    console.error("arvo dev: entry file '#{cfg.entry}' does not exist under '#{app_dir}'")
    return 1
  end

  plan = build_dev_plan(app_dir, dargs, cfg, app_files.read_only, env)
  if dargs.dry_run?
    console.print(plan.to_json.to_text)
    return 0
  end

  script = build_supervisor_script(plan)
  if dargs.emit_script?
    console.print(script)
    return 0
  end

  _mk = app_files.make_folder(plan.mailbox_dir)
  console.print("Arvo Dev Server")
  console.print("  App:           #{plan.backend_url}")
  console.print("  Dev Dashboard: #{plan.dev_dashboard_url}")
  console.print("  Dev Mailbox:   #{plan.mailbox_dir}")
  if plan.vite_url is Some(vu)
    console.print("  Vite HMR:      #{vu}")
  end

  scoped_cmd = if app_dir == ".": cmd else: cmd.within(app_dir)
  case scoped_cmd.run("sh", ["-c", script], 3600.seconds)
    Ok(out):
      if not out.stdout.trim.empty?
        console.print(out.stdout.trim)
      end
      if not out.stderr.trim.empty?
        console.error(out.stderr.trim)
      end
      out.status
    Error(e):
      console.error("arvo dev: supervisor failed: #{e}")
      1
  end
end

test "DevCmd parses ports, validates conflicts, builds Vite + mo serve supervisor, and runs dry-run"
  assert parse_dev_args(["--help"]) is Ok(h) and h.help?
  assert parse_dev_args(["--port", "3000", "--vite-port", "5179", "--dry-run"]) is Ok(da) and
    da.port == 3000 and
    da.vite_port == 5179 and
    da.dry_run? and
    not da.no_vite?
  assert parse_dev_args(["--port", "0"]) is Error(_)
  assert parse_dev_args(["--port", "8080", "--vite-port", "8080"]) is Error(_)
  assert parse_dev_args(["--port", "abc"]) is Error(_)
  assert parse_dev_args(["--bogus"]) is Error(_)

  files = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": "module Main\n",
    "frontend/package.json": "{\"name\":\"web\"}\n"
  })
  c_dry = Console.fake()
  assert parse_dev_args(["--dry-run"]) is Ok(parsed)
  assert run_dev(".", parsed, files, Command.fake(Command.replies([])), Env.of({}), c_dry) == 0
  dry_line = c_dry.printed.first or ""
  assert dry_line.contains?("\"dev_dashboard_url\":\"http://127.0.0.1:8080/__arvo\"")
  assert dry_line.contains?("\"vite_enabled?\":true")
  assert dry_line.contains?("mo serve --watch --bind 127.0.0.1 --port 8080 'main.mo'")

  assert parse_dev_args(["--emit-script"]) is Ok(emit_args) and emit_args.emit_script?
  c_emit = Console.fake()
  assert run_dev(".", emit_args, files, Command.fake(Command.replies([])), Env.of({}), c_emit) == 0
  assert (c_emit.printed.first or "").contains?("exec mo serve --watch --bind 127.0.0.1")

  cfg = Config.default_config()
  plan = build_dev_plan("examples/demo", parsed, cfg, files.read_only, Env.of({}))
  script = build_supervisor_script(plan)
  assert script.contains?("export ARVO_DEV='1'")
  assert script.contains?("export ARVO_DEV_MAILBOX='.arvo/mailbox'")
  assert script.contains?("trap cleanup INT TERM EXIT")

  assert parse_dev_args(["--no-vite"]) is Ok(parsed_no_vite)
  plan_no_vite = build_dev_plan("examples/demo", parsed_no_vite, cfg, files.read_only, Env.of({}))
  assert not plan_no_vite.vite_enabled?
  script_no_vite = build_supervisor_script(plan_no_vite)
  assert not script_no_vite.contains?("VITE_PID")

  replies_ok = Command.replies([
    (
      Command.spec("sh", ["-c", script_no_vite]).in_folder("examples/demo"),
      Command.ok_output("ready\n")
    )
  ])
  c_live = Console.fake()
  assert run_dev(
    "examples/demo",
    parsed_no_vite,
    files,
    Command.fake(replies_ok),
    Env.of({}),
    c_live
  ) ==
    0
  assert c_live.printed.any?(fn(l) l.contains?("http://127.0.0.1:8080/__arvo") end)
end
