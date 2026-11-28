## Self-contained build bundler and exe.dev SSH + systemd release deployer (`arvo build`, `arvo deploy`).
module DeployCmd
expose BuildArgs(..),
BuildPlan(..),
DeployInitArgs(..),
DeployRunArgs(..),
DeployArgs(..),
DeployPlan(..),
HealthProbe(..),
build_usage,
deploy_usage,
parse_build_args,
parse_deploy_args,
parse_health_probe,
parse_mo_toml_path_deps,
rewrite_mo_toml_for_vendor,
resolve_service_name,
render_systemd_unit,
render_deploy_env_example,
upsert_deploy_toml,
build_bundle_script,
build_deploy_script,
run_build,
run_deploy
use Config
use DevCmd

## Parsed CLI options for `arvo build`.
struct BuildArgs
  out_dir: Text
  skip_frontend?: Bool
  skip_checks?: Bool
  dry_run?: Bool
  emit_script?: Bool
  help?: Bool
end

## Resolved build plan JSON emitted by `arvo build --dry-run`.
struct BuildPlan
  app_dir: Text
  entry: Text
  frontend_dir: Text
  out_dir: Text
  skip_frontend?: Bool
  skip_checks?: Bool
  direct_path_deps: List((Text, Text))
  script: Text
end

## Parsed CLI options for `arvo deploy init`.
struct DeployInitArgs
  host: Option(Text)
  user: Option(Text)
  service_name: Option(Text)
  db: Option(Text)
  port: Option(Int)
  force?: Bool
  help?: Bool
end

## Parsed CLI options for `arvo deploy [HOST]`.
struct DeployRunArgs
  host: Option(Text)
  user: Option(Text)
  service_name: Option(Text)
  port: Option(Int)
  allow_dirty?: Bool
  skip_build?: Bool
  skip_frontend?: Bool
  no_mo_upload?: Bool
  bootstrap_env?: Bool
  rollback?: Bool
  status?: Bool
  logs?: Bool
  dry_run?: Bool
  emit_script?: Bool
  help?: Bool
end

## Tagged command variant after `arvo deploy`.
enum DeployArgs
  InitDeploy(DeployInitArgs)
  RunDeploy(DeployRunArgs)
end

## Parsed health check probe `METHOD /path=CODE`.
struct HealthProbe
  method: Text
  path: Text
  expected_status: Int
end

## Resolved deployment plan JSON emitted by `arvo deploy --dry-run`.
struct DeployPlan
  mode: Text
  app_dir: Text
  host: Text
  user: Text
  port: Int
  service_name: Text
  db: Text
  entry: Text
  env_file: Text
  backup_dir: Text
  data_dirs: List(Text)
  preserve_paths: List(Text)
  health_checks: List(Text)
  upload_mo?: Bool
  bootstrap_env?: Bool
  script: Text
end

## Usage text for `arvo build`.
fn build_usage() : Text
  """
    usage: arvo build [--app DIR] [--out .arvo/dist] [--skip-frontend] [--skip-checks] [--dry-run] [--emit-script]

    Runs `mo check`, optional contract & feature validation, Vite production build, and stages a
    self-contained release bundle in `--out` with all local `mo.toml` path dependencies vendored
    under `vendor/` so target VMs need zero sibling checkouts.

    Flags:
      --app DIR         Target application subdirectory (default: `.`)
      --out DIR         Output directory for release bundle (default: `.arvo/dist`)
      --skip-frontend   Skip `tsc --noEmit` and `vite build`
      --skip-checks     Skip pre-bundle `arvo contracts --check` and `arvo feature --validate`
      --dry-run         Emit BuildPlan JSON without writing files
      --emit-script     Print POSIX build script for host execution
      -h, --help        Show this help
    """
end

## Usage text for `arvo deploy`.
fn deploy_usage() : Text
  """
    usage:
      arvo deploy init [--app DIR] [--host <vm>.exe.xyz] [--service NAME] [--db modb|sqlite] [--port 8000] [--force]
      arvo deploy [HOST] [--app DIR] [flags]

    Configures hardened systemd units and deploys self-contained Arvo releases to exe.dev VMs
    with pre-deploy DB backup, atomic release swap (preserving data/), health probes, and auto-rollback.

    Deploy Flags:
      --host HOST       Target SSH host (overrides [deploy].host in arvo.toml)
      --user USER       SSH & systemd user (default from arvo.toml or `exedev`)
      --service NAME    Systemd service & remote directory name
      --port PORT       Localhost bind port (default from arvo.toml or `8000`)
      --allow-dirty     Deploy even with uncommitted git changes (archives working tree)
      --skip-build      Reuse existing `.arvo/dist` bundle without rebuilding
      --skip-frontend   Forwarded to `arvo build`
      --no-mo-upload    Keep existing `~/.local/bin/mo` on target VM
      --bootstrap-env   Generate `/etc/<service>/<service>.env` (chmod 0600) with CSPRNG key if missing
      --rollback        Roll back active release to `~/<service>.prev` preserving data/
      --status          Inspect remote systemd status, revision, and health probes
      --logs            Show last 60 lines of `journalctl -u <service>`
      --dry-run         Emit DeployPlan JSON without running SSH
      --emit-script     Print POSIX deploy script for host execution
      -h, --help        Show this help
    """
end

fn need_val(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("`#{flag}` requires a value.")
  else
    Ok(v)
  end
end

fn valid_service_name?(raw: Text) : Bool
  s = raw.trim
  return false if s.empty? or s.starts_with?(".") or s.starts_with?("-")
  for ch in s.chars
    ok? = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or
      ch == '-' or
      ch == '_' or
      ch == '.'
    return false if not ok?
  end
  true
end

fn valid_ssh_host?(raw: Text) : Bool
  s = raw.trim
  return false if s.empty? or s.starts_with?("-")
  for ch in s.chars
    return false if ch.ascii_white_space?
  end
  true
end

## Parses arguments after `arvo build`.
fn parse_build_args(rest: List(Text)) : Result(BuildArgs, Text)
  var out_dir = ".arvo/dist"
  var skip_frontend? = false
  var skip_checks? = false
  var dry_run? = false
  var emit_script? = false
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(
        BuildArgs(
          out_dir: out_dir,
          skip_frontend?: skip_frontend?,
          skip_checks?: skip_checks?,
          dry_run?: dry_run?,
          emit_script?: emit_script?,
          help?: true
        )
      )
    else if a == "--skip-frontend"
      skip_frontend? = true
    else if a == "--skip-checks"
      skip_checks? = true
    else if a == "--dry-run"
      dry_run? = true
    else if a == "--emit-script"
      emit_script? = true
    else if a == "--out"
      out_dir = try need_val(rest, i, "--out")
      i += 1
    else
      return Error("unknown flag '#{a}' for `arvo build`. Run `arvo build --help`.")
    end
    i += 1
  end
  Ok(
    BuildArgs(
      out_dir: out_dir,
      skip_frontend?: skip_frontend?,
      skip_checks?: skip_checks?,
      dry_run?: dry_run?,
      emit_script?: emit_script?,
      help?: false
    )
  )
end

fn parse_deploy_init_args(rest: List(Text)) : Result(DeployArgs, Text)
  var host = None
  var user = None
  var svc_name = None
  var db = None
  var port = None
  var force? = false
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(
        InitDeploy(
          DeployInitArgs(
            host: host,
            user: user,
            service_name: svc_name,
            db: db,
            port: port,
            force?: force?,
            help?: true
          )
        )
      )
    else if a == "--force"
      force? = true
    else if a == "--host"
      v = try need_val(rest, i, "--host")
      return Error("invalid --host '#{v}'") if not valid_ssh_host?(v)
      host = Some(v.trim)
      i += 1
    else if a == "--user"
      user = Some((try need_val(rest, i, "--user")).trim)
      i += 1
    else if a == "--service"
      v = (try need_val(rest, i, "--service")).trim
      return Error("invalid --service '#{v}'") if not valid_service_name?(v)
      svc_name = Some(v)
      i += 1
    else if a == "--db"
      v = (try need_val(rest, i, "--db")).trim
      if v != "modb" and v != "sqlite" and v != "hybrid"
        return Error("invalid --db '#{v}' (expected modb, sqlite, or hybrid)")
      end
      db = Some(v)
      i += 1
    else if a == "--port"
      raw = try need_val(rest, i, "--port")
      p = try raw.to_int.or_fail("invalid --port '#{raw}'")
      return Error("--port must be in 1..65535, got #{p}") if p < 1 or p > 65535
      port = Some(p)
      i += 1
    else
      return Error("unknown flag '#{a}' for `arvo deploy init`. Run `arvo deploy --help`.")
    end
    i += 1
  end
  Ok(
    InitDeploy(
      DeployInitArgs(
        host: host,
        user: user,
        service_name: svc_name,
        db: db,
        port: port,
        force?: force?,
        help?: false
      )
    )
  )
end

## Parses arguments after `arvo deploy`.
fn parse_deploy_args(rest: List(Text)) : Result(DeployArgs, Text)
  if rest.first == Some("init")
    return parse_deploy_init_args(rest.drop(1))
  end
  var host = None
  var user = None
  var svc_name = None
  var port = None
  var allow_dirty? = false
  var skip_build? = false
  var skip_frontend? = false
  var no_mo_upload? = false
  var bootstrap_env? = false
  var rollback? = false
  var status? = false
  var logs? = false
  var dry_run? = false
  var emit_script? = false
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(
        RunDeploy(
          DeployRunArgs(
            host: host,
            user: user,
            service_name: svc_name,
            port: port,
            allow_dirty?: allow_dirty?,
            skip_build?: skip_build?,
            skip_frontend?: skip_frontend?,
            no_mo_upload?: no_mo_upload?,
            bootstrap_env?: bootstrap_env?,
            rollback?: rollback?,
            status?: status?,
            logs?: logs?,
            dry_run?: dry_run?,
            emit_script?: emit_script?,
            help?: true
          )
        )
      )
    else if a == "--allow-dirty"
      allow_dirty? = true
    else if a == "--skip-build"
      skip_build? = true
    else if a == "--skip-frontend"
      skip_frontend? = true
    else if a == "--no-mo-upload"
      no_mo_upload? = true
    else if a == "--bootstrap-env"
      bootstrap_env? = true
    else if a == "--rollback"
      rollback? = true
    else if a == "--status"
      status? = true
    else if a == "--logs"
      logs? = true
    else if a == "--dry-run"
      dry_run? = true
    else if a == "--emit-script"
      emit_script? = true
    else if a == "--host"
      v = try need_val(rest, i, "--host")
      return Error("invalid --host '#{v}'") if not valid_ssh_host?(v)
      host = Some(v.trim)
      i += 1
    else if a == "--user"
      user = Some((try need_val(rest, i, "--user")).trim)
      i += 1
    else if a == "--service"
      v = (try need_val(rest, i, "--service")).trim
      return Error("invalid --service '#{v}'") if not valid_service_name?(v)
      svc_name = Some(v)
      i += 1
    else if a == "--port"
      raw = try need_val(rest, i, "--port")
      p = try raw.to_int.or_fail("invalid --port '#{raw}'")
      return Error("--port must be in 1..65535, got #{p}") if p < 1 or p > 65535
      port = Some(p)
      i += 1
    else if a.starts_with?("-")
      return Error("unknown flag '#{a}' for `arvo deploy`. Run `arvo deploy --help`.")
    else if host == None
      return Error("invalid host '#{a}'") if not valid_ssh_host?(a)
      host = Some(a.trim)
    else
      return Error("unexpected extra positional argument '#{a}' for `arvo deploy`.")
    end
    i += 1
  end
  Ok(
    RunDeploy(
      DeployRunArgs(
        host: host,
        user: user,
        service_name: svc_name,
        port: port,
        allow_dirty?: allow_dirty?,
        skip_build?: skip_build?,
        skip_frontend?: skip_frontend?,
        no_mo_upload?: no_mo_upload?,
        bootstrap_env?: bootstrap_env?,
        rollback?: rollback?,
        status?: status?,
        logs?: logs?,
        dry_run?: dry_run?,
        emit_script?: emit_script?,
        help?: false
      )
    )
  )
end

## Parses a health probe string `"GET /health=200"` into `HealthProbe`.
fn parse_health_probe(raw: Text) : Result(HealthProbe, Text)
  parts = raw.trim.split(" ")
  if parts.size != 2
    return Error("invalid health probe '#{raw}' (expected 'METHOD /path=CODE')")
  end
  method = (parts.first or "").ascii_uppercase
  if method != "GET" and method != "HEAD" and method != "POST"
    return Error("unsupported health probe method '#{method}'")
  end
  rhs = parts.get(1) or ""
  eq = rhs.split("=")
  if eq.size != 2
    return Error("invalid health probe '#{raw}' (missing '=STATUS')")
  end
  path = eq.first or ""
  code_raw = eq.get(1) or ""
  if not path.starts_with?("/")
    return Error("health probe path must start with '/': '#{path}'")
  end
  code = try code_raw.to_int.or_fail("invalid health probe status '#{code_raw}'")
  if code < 100 or code > 599
    return Error("health probe status out of range: #{code}")
  end
  Ok(HealthProbe(method: method, path: path, expected_status: code))
end

fn strip_hash_comment(line: Text) : Text
  var out = []
  var in_q? = false
  var esc? = false
  for ch in line.chars
    if esc?
      out = out.append(ch)
      esc? = false
    else if ch == '\\' and in_q?
      out = out.append(ch)
      esc? = true
    else if ch == '"'
      in_q? = not in_q?
      out = out.append(ch)
    else if ch == '#' and not in_q?
      break
    else
      out = out.append(ch)
    end
  end
  Text.from_chars(out).trim
end

fn extract_inline_path(rhs: Text) : Option(Text)
  t = rhs.trim
  return None if not t.starts_with?("{") or not t.ends_with?("}")
  inner = (t.bytes.slice(1, t.byte_count - 1).decode_utf8 or "").trim
  for pair in inner.split(",")
    pieces = pair.split("=")
    if pieces.size >= 2 and (pieces.first or "").trim == "path"
      raw_v = pieces.drop(1).join("=").trim
      if raw_v.starts_with?("\"") and raw_v.ends_with?("\"") and raw_v.byte_count >= 2
        val = (raw_v.bytes.slice(1, raw_v.byte_count - 1).decode_utf8 or "").trim
        return Some(val) if not val.empty?
      end
    end
  end
  None
end

## Extracts `(dep_name, rel_path)` pairs from `[dependencies]` inside `mo_toml`.
fn parse_mo_toml_path_deps(mo_toml: Text) : List((Text, Text))
  var in_deps? = false
  var out = []
  for raw in mo_toml.lines
    line = strip_hash_comment(raw)
    continue if line.empty?
    if line.starts_with?("[")
      in_deps? = line == "[dependencies]"
      continue
    end
    continue if not in_deps? or not line.contains?("=")
    parts = line.split("=")
    dep_name = (parts.first or "").trim
    rhs = parts.drop(1).join("=").trim
    if not dep_name.empty?
      if extract_inline_path(rhs) is Some(p)
        out = out.append((dep_name, p))
      end
    end
  end
  out
end

## Rewrites `path = "..."` entries under `[dependencies]` in `mo_toml` to `vendor/<dep_name>`.
fn rewrite_mo_toml_for_vendor(mo_toml: Text, deps: List((Text, Text))) : Text
  var map_old = {}
  for (name, old_path) in deps
    map_old = map_old.set(name, old_path)
  end
  var in_deps? = false
  var out_lines = []
  for raw in mo_toml.lines
    clean = strip_hash_comment(raw)
    if clean.starts_with?("[")
      in_deps? = clean == "[dependencies]"
      out_lines = out_lines.append(raw)
      continue
    end
    if in_deps? and clean.contains?("=")
      parts = clean.split("=")
      dep_name = (parts.first or "").trim
      case map_old.get(dep_name)
        Some(old_path):
          replaced = raw.replace("\"#{old_path}\"", "\"vendor/#{dep_name}\"")
          out_lines = out_lines.append(replaced)
        None: out_lines = out_lines.append(raw)
      end
    else
      out_lines = out_lines.append(raw)
    end
  end
  out_lines.join("\n")
end

fn extract_pkg_name_from_toml(toml_text: Text) : Option(Text)
  var in_pkg? = false
  for raw in toml_text.lines
    t = strip_hash_comment(raw)
    continue if t.empty?
    if t.starts_with?("[")
      in_pkg? = t == "[package]"
      continue
    end
    if in_pkg? and t.starts_with?("name") and t.contains?("=")
      rhs = t.split("=").drop(1).join("=").trim
      if rhs.starts_with?("\"") and rhs.ends_with?("\"") and rhs.byte_count >= 2
        v = (rhs.bytes.slice(1, rhs.byte_count - 1).decode_utf8 or "").trim
        return Some(v) if not v.empty?
      end
    end
  end
  None
end

## Resolves systemd service & remote folder name from flag, config, `mo.toml`, or `app_dir`.
fn resolve_service_name(
  flag_svc: Option(Text),
  cfg: Config.ArvoConfig,
  rf: ReadFiles,
  app_dir: Text
) : Text
  if flag_svc is Some(s) and valid_service_name?(s)
    return s.trim
  end
  if cfg.deploy.service_name is Some(cs) and valid_service_name?(cs)
    return cs.trim
  end
  if rf.read_text("mo.toml") is Ok(mt)
    if extract_pkg_name_from_toml(mt) is Some(pn) and valid_service_name?(pn)
      return pn
    end
  end
  last = (app_dir.split("/").last or "").trim
  if valid_service_name?(last) and last != ".": last else: "arvo-app"
end

## Renders hardened systemd service unit tailored for exe.dev single-binary `mo serve`.
fn render_systemd_unit(
  svc_name: Text,
  user: Text,
  port: Int,
  entry: Text,
  env_file: Text,
  data_dirs: List(Text),
  preserve_paths: List(Text)
) : Text
  app_dir = "/home/#{user}/#{svc_name}"
  var rw = []
  for d in data_dirs
    clean = d.trim.drop_prefix("./") or d.trim
    if not clean.empty?
      rw = rw.append("#{app_dir}/#{clean}")
    end
  end
  for p in preserve_paths
    clean = p.trim.drop_prefix("./") or p.trim
    if not clean.empty?
      path_full = "#{app_dir}/#{clean}"
      if not rw.contains?(path_full)
        rw = rw.append(path_full)
      end
    end
  end
  rw_line = if rw.empty?: "#{app_dir}/data" else: rw.join(" ")

  """
  [Unit]
  Description=#{svc_name} — Arvo single-binary web application
  After=network-online.target
  Wants=network-online.target

  [Service]
  Type=simple
  User=#{user}
  Group=#{user}
  WorkingDirectory=#{app_dir}
  EnvironmentFile=#{env_file}
  ExecStart=/home/#{user}/.local/bin/mo serve #{app_dir}/#{entry} --bind 127.0.0.1 --port #{port}
  Restart=on-failure
  RestartSec=3
  TimeoutStopSec=25
  UMask=0077
  NoNewPrivileges=true
  PrivateTmp=true
  ProtectSystem=strict
  ProtectHome=read-only
  ReadWritePaths=#{rw_line}

  [Install]
  WantedBy=multi-user.target
  """
end

## Renders `deploy/env.example` documenting required production secrets and optional S3 backup env.
fn render_deploy_env_example(svc_name: Text, host: Text) : Text
  """
  # Environment file installed at /etc/#{svc_name}/#{svc_name}.env (chmod 0600, owned by exedev)
  # Required 64-hex AES-256 secret key (generate with: openssl rand -hex 32)
  ARVO_SECRET_KEY=REPLACE_WITH_64_HEX_BYTES
  ARVO_DEV=0
  ARVO_INSECURE_COOKIES=0
  APP_URL=https://#{host}
  ARVO_ALLOWLIST=ada@example.local
  ARVO_SEED_PASSWORD=replace-with-strong-password

  # Optional S3 / R2 backup configuration for `arvo backup sync`
  # ARVO_S3_BUCKET=my-backups
  # ARVO_S3_REGION=auto
  # ARVO_S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com
  # ARVO_S3_ACCESS_KEY_ID=
  # ARVO_S3_SECRET_ACCESS_KEY=
  """
end

## Appends a `[deploy]` section to `arvo_toml` if absent (or when `force?` is true, appends if missing).
fn upsert_deploy_toml(
  existing: Option(Text),
  host: Text,
  user: Text,
  port: Int,
  svc_name: Text,
  db: Text
) : Text
  deploy_block = """
  [deploy]
  target = "exe.dev"
  host = "#{host}"
  user = "#{user}"
  port = #{port}
  service = "#{svc_name}"
  db = "#{db}"
  data_dirs = ["data"]
  preserve_paths = []
  extra_static = []
  health_checks = ["GET /health=200"]
  """
  case existing
    None: """
      [app]
      entry = "main.mo"

      #{deploy_block}
      """
    Some(raw):
      if raw.contains?("[deploy]")
        raw
      else
        trimmed = raw.trim
        "#{trimmed}\n\n#{deploy_block}\n"
      end
  end
end

## Builds POSIX shell script creating a self-contained release bundle with transitive vendor deps.
fn build_bundle_script(bargs: BuildArgs, cfg: Config.ArvoConfig) : Text
  q = DevCmd.shell_quote
  fdir = cfg.frontend_dir.drop_suffix("/") or cfg.frontend_dir
  extra_copy = cfg.deploy.extra_static.map(fn(s)
    "if [ -e #{q(s)} ]; then mkdir -p \"$(dirname #{q("#{bargs.out_dir}/#{s}")})\"; cp -a #{q(s)} #{q(
      "#{bargs.out_dir}/#{s}"
    )}; fi"
  end).join("\n")

  fe_step = if bargs.skip_frontend?
    "# frontend build skipped via --skip-frontend"
  else
    """
    if [ -f #{q("#{fdir}/package.json")} ]; then
      if [ ! -d #{q("#{fdir}/node_modules")} ]; then
        printf 'arvo build: missing %s/node_modules (run npm --prefix %s install or pass --skip-frontend)\\n' #{q(
      fdir
    )} #{q(fdir)} >&2
        exit 1
      fi
      (cd #{q(fdir)} && npx tsc --noEmit && npm run build)
    fi
    """
  end

  checks_step = if bargs.skip_checks?
    "# pre-bundle checks skipped via --skip-checks"
  else
    """
    "$MO_BIN" check #{q(cfg.entry)}
    """
  end

  # Embedded transitive path-dependency vendorer rewriting root & transitive mo.toml path refs
  vendor_py = """
  python3 - "$PWD" "$OUT_ABS" <<'PY'
  import os, re, shutil, sys

  app_dir, out_dir = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
  vendor_root = os.path.join(out_dir, "vendor")
  os.makedirs(vendor_root, exist_ok=True)
  IGNORE = {".git", "node_modules", ".arvo", "target", "data", ".env", "dist", "strength"}

  def ignore_fn(_dir, names):
    out = []
    for n in names:
      if n in IGNORE or n.endswith(".sqlite") or n.endswith(".sqlite3") or n.endswith(".modb") or n.endswith(".modb.lock"):
        out.append(n)
    return out

  def strip_comment(line):
    in_q, esc = False, False
    buf = []
    for ch in line:
      if esc:
        buf.append(ch); esc = False
      elif ch == "\\\\" and in_q:
        buf.append(ch); esc = True
      elif ch == '"':
        in_q = not in_q; buf.append(ch)
      elif ch == '#' and not in_q:
        break
      else:
        buf.append(ch)
    return "".join(buf).strip()

  def parse_deps(toml_path):
    if not os.path.isfile(toml_path):
      return []
    in_deps = False
    deps = []
    base = os.path.dirname(toml_path)
    with open(toml_path, "r", encoding="utf-8") as f:
      for raw in f:
        s = strip_comment(raw)
        if not s:
          continue
        if s.startswith("["):
          in_deps = (s == "[dependencies]")
          continue
        if not in_deps or "=" not in s:
          continue
        name, rhs = [p.strip() for p in s.split("=", 1)]
        m = re.search(r'\\bpath\\s*=\\s*"([^"]+)"', rhs)
        if m:
          deps.append((name, m.group(1), os.path.realpath(os.path.join(base, m.group(1)))))
    return deps

  def rewrite_toml(toml_path, dep_targets):
    if not os.path.isfile(toml_path):
      return
    base = os.path.dirname(toml_path)
    in_deps = False
    lines = []
    with open(toml_path, "r", encoding="utf-8") as f:
      for raw in f:
        s = strip_comment(raw)
        if s.startswith("["):
          in_deps = (s == "[dependencies]")
          lines.append(raw)
          continue
        if in_deps and "=" in s:
          name = s.split("=", 1)[0].strip()
          if name in dep_targets:
            rel = os.path.relpath(dep_targets[name], base).replace(os.sep, "/")
            raw = re.sub(r'(\\bpath\\s*=\\s*")[^"]+(")', r'\\1' + rel + r'\\2', raw, count=1)
        lines.append(raw)
    with open(toml_path, "w", encoding="utf-8") as f:
      f.writelines(lines)

  copied = {}
  queue = [(name, src_real) for (name, _old, src_real) in parse_deps(os.path.join(app_dir, "mo.toml"))]
  while queue:
    name, src_real = queue.pop(0)
    if name in copied:
      continue
    if not os.path.isdir(src_real):
      sys.stderr.write(f"arvo build: missing path dependency '{name}' at {src_real}\\n")
      sys.exit(1)
    dst = os.path.join(vendor_root, name)
    if os.path.exists(dst):
      shutil.rmtree(dst)
    shutil.copytree(src_real, dst, ignore=ignore_fn, symlinks=False)
    copied[name] = dst
    for sub_name, _sub_old, sub_real in parse_deps(os.path.join(src_real, "mo.toml")):
      if sub_name not in copied:
        queue.append((sub_name, sub_real))

  rewrite_toml(os.path.join(out_dir, "mo.toml"), copied)
  for dep_dst in copied.values():
    rewrite_toml(os.path.join(dep_dst, "mo.toml"), copied)
  PY
  """

  """
  set -euo pipefail
  MO_BIN="${MO_BIN:-${MO:-mo}}"
  OUT_DIR=#{q(bargs.out_dir)}
  #{checks_step}
  #{fe_step}
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR"
  tar --exclude=.git --exclude=node_modules --exclude=.arvo --exclude=data --exclude=.env --exclude=target --exclude='*.sqlite*' --exclude='*.modb*' -cf - . | tar -C "$OUT_DIR" -xf -
  if [ -f "public/manifest.json" ]; then
    mkdir -p "$OUT_DIR/public"
    cp -a "public/manifest.json" "$OUT_DIR/public/"
  fi
  if [ -d "public/assets" ]; then
    mkdir -p "$OUT_DIR/public"
    rm -rf "$OUT_DIR/public/assets"
    cp -a "public/assets" "$OUT_DIR/public/"
  fi
  #{extra_copy}
  OUT_ABS="$(cd "$OUT_DIR" && pwd)"
  #{vendor_py}
  if command -v git >/dev/null 2>&1 && git rev-parse --short HEAD >/dev/null 2>&1; then
    git rev-parse --short HEAD > "$OUT_DIR/REVISION"
  else
    printf 'dev\\n' > "$OUT_DIR/REVISION"
  fi
  "$MO_BIN" check "$OUT_DIR/#{cfg.entry}"
  printf 'Built self-contained Arvo bundle at %s\\n' "$OUT_DIR"
  """
end

fn render_health_check_fn(probes: List(HealthProbe)) : Text
  lines = probes.map(fn(p)
    """
      code="$(curl -s -o /dev/null -w '%{http_code}' -X #{p.method} "http://127.0.0.1:${PORT}#{p
      .path}" || true)"
      if [ "$code" != "#{p.expected_status}" ]; then
        return 1
      fi
    """
  end).join("\n")
  if probes.empty?
    """
    healthy() {
      systemctl is-active --quiet "${SERVICE}.service"
    }
    """
  else
    first_probe = probes.first or HealthProbe(method: "GET", path: "/health", expected_status: 200)
    """
    healthy() {
      local code=""
      for _ in $(seq 30); do
        code="$(curl -s -o /dev/null -w '%{http_code}' -X #{first_probe.method} "http://127.0.0.1:${PORT}#{first_probe
      .path}" || true)"
        [ "$code" = "#{first_probe.expected_status}" ] && break
        sleep 0.5
      done
      systemctl is-active --quiet "${SERVICE}.service" || return 1
    #{lines}
    }
    """
  end
end

## Builds deterministic POSIX `exe.dev` SSH deploy / rollback / status / logs script.
fn build_deploy_script(
  plan: DeployPlan,
  probes: List(HealthProbe),
  build_args: BuildArgs,
  cfg: Config.ArvoConfig,
  allow_dirty?: Bool,
  skip_build?: Bool
) : Text
  q = DevCmd.shell_quote
  target = "#{plan.user}@#{plan.host}"
  health_fn = render_health_check_fn(probes)

  if plan.mode == "status"
    return """
      set -euo pipefail
      TARGET=#{q(target)}
      SERVICE=#{q(plan.service_name)}
      PORT=#{q("#{plan.port}")}
      ssh -o StrictHostKeyChecking=accept-new "$TARGET" bash -s -- "$SERVICE" "$PORT" <<'REMOTE'
      set -euo pipefail
      SERVICE="$1"
      PORT="$2"
      REV="$(cat "$HOME/$SERVICE/REVISION" 2>/dev/null || echo 'unknown')"
      STATUS="$(systemctl is-active "${SERVICE}.service" 2>/dev/null || echo 'inactive')"
      printf 'Service: %s  State: %s  Revision: %s\\n' "$SERVICE" "$STATUS" "$REV"
      #{health_fn}
      if healthy; then
        printf 'Health probes: OK\\n'
      else
        printf 'Health probes: FAILED\\n' >&2
        exit 1
      fi
      REMOTE
      """
  end

  if plan.mode == "logs"
    return """
      set -euo pipefail
      TARGET=#{q(target)}
      SERVICE=#{q(plan.service_name)}
      ssh -o StrictHostKeyChecking=accept-new "$TARGET" "sudo journalctl -u #{plan.service_name}.service -n 60 --no-pager"
      """
  end

  data_mv_next = plan.data_dirs.map(fn(d)
    cd = d.trim.drop_prefix("./") or d.trim
    """
      rm -rf "$NEXT/#{cd}"
      if [ -d "$APP/#{cd}" ]; then
        mv "$APP/#{cd}" "$NEXT/#{cd}"
      else
        mkdir -p "$NEXT/#{cd}"
        chmod 0700 "$NEXT/#{cd}"
      fi
    """
  end).join("\n")

  preserve_mv_next = plan.preserve_paths.map(fn(p)
    cp_clean = p.trim.drop_prefix("./") or p.trim
    """
      if [ -d "$APP/#{cp_clean}" ]; then
        rm -rf "$NEXT/#{cp_clean}"
        mkdir -p "$(dirname "$NEXT/#{cp_clean}")"
        mv "$APP/#{cp_clean}" "$NEXT/#{cp_clean}"
      fi
    """
  end).join("\n")

  data_mv_back = plan.data_dirs.map(fn(d)
    cd = d.trim.drop_prefix("./") or d.trim
    "if [ -d \"$APP/#{cd}\" ]; then rm -rf \"$PREV/#{cd}\"; mv \"$APP/#{cd}\" \"$PREV/#{cd}\"; fi"
  end).join("\n")

  preserve_mv_back = plan.preserve_paths.map(fn(p)
    cp_clean = p.trim.drop_prefix("./") or p.trim
    "if [ -d \"$APP/#{cp_clean}\" ]; then rm -rf \"$PREV/#{cp_clean}\"; mkdir -p \"$(dirname \"$PREV/#{cp_clean}\")\"; mv \"$APP/#{cp_clean}\" \"$PREV/#{cp_clean}\"; fi"
  end).join("\n")

  if plan.mode == "rollback"
    return """
      set -euo pipefail
      TARGET=#{q(target)}
      SERVICE=#{q(plan.service_name)}
      PORT=#{q("#{plan.port}")}
      ssh -o StrictHostKeyChecking=accept-new "$TARGET" bash -s -- "$SERVICE" "$PORT" <<'REMOTE'
      set -euo pipefail
      SERVICE="$1"
      PORT="$2"
      APP="$HOME/$SERVICE"
      NEXT="$APP.next"
      PREV="$APP.prev"
      if [ ! -d "$PREV" ]; then
        printf 'No previous release found at %s\\n' "$PREV" >&2
        exit 1
      fi
      if systemctl is-active --quiet "${SERVICE}.service" 2>/dev/null; then
        sudo systemctl stop "${SERVICE}.service"
      fi
      #{data_mv_back}
      #{preserve_mv_back}
      rm -rf "$NEXT"
      mv "$APP" "$NEXT"
      mv "$PREV" "$APP"
      sudo install -m 0644 "$APP/deploy/${SERVICE}.service" "/etc/systemd/system/${SERVICE}.service"
      sudo systemctl daemon-reload
      sudo systemctl restart "${SERVICE}.service"
      #{health_fn}
      healthy
      printf 'Rolled back %s cleanly on %s\\n' "$SERVICE" "$(hostname)"
      REMOTE
      """
  end

  dirty_guard = if allow_dirty?
    "# --allow-dirty set"
  else
    """
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        printf 'arvo deploy: commit or stash tracked changes first (or pass --allow-dirty).\\n' >&2
        exit 1
      fi
    fi
    """
  end

  build_block = if skip_build?
    """
    if [ ! -d ".arvo/dist" ]; then
      printf 'arvo deploy --skip-build: missing .arvo/dist\\n' >&2
      exit 1
    fi
    """
  else
    build_bundle_script(build_args, cfg)
  end

  mo_upload = if plan.upload_mo?
    """
    if [ ! -x "$MO_BIN" ]; then
      printf 'arvo deploy: mo binary not found at %s\\n' "$MO_BIN" >&2
      exit 1
    fi
    scp -q "$MO_BIN" "$TARGET:~/.local/bin/mo.next"
    """
  else
    "# --no-mo-upload set"
  end

  mo_install_remote = if plan.upload_mo?
    """
    chmod 0755 "$HOME/.local/bin/mo.next"
    mv -f "$HOME/.local/bin/mo.next" "$HOME/.local/bin/mo"
    """
  else
    ""
  end

  unit_text = render_systemd_unit(
    plan.service_name,
    plan.user,
    plan.port,
    plan.entry,
    plan.env_file,
    plan.data_dirs,
    plan.preserve_paths
  )

  bootstrap_val = if plan.bootstrap_env?: "1" else: "0"

  """
  set -euo pipefail
  MO_BIN="${MO_BIN:-${MO:-$HOME/.local/bin/mo}}"
  if ! command -v "$MO_BIN" >/dev/null 2>&1 && [ -x /home/exedev/code/mo/target/release/mo ]; then
    MO_BIN="/home/exedev/code/mo/target/release/mo"
  fi
  TARGET=#{q(target)}
  HOST=#{q(plan.host)}
  SERVICE=#{q(plan.service_name)}
  PORT=#{q("#{plan.port}")}
  ENV_FILE=#{q(plan.env_file)}
  BACKUP_DIR=#{q(plan.backup_dir)}
  BOOTSTRAP_ENV=#{q(bootstrap_val)}
  #{dirty_guard}
  #{build_block}
  ssh -o StrictHostKeyChecking=accept-new "$TARGET" "rm -rf ~/${plan.service_name}.next && mkdir -p ~/${plan.service_name}.next/deploy ~/.local/bin"
  tar -cf - -C ".arvo/dist" . | ssh "$TARGET" "tar -xf - -C ~/${plan.service_name}.next"
  #{mo_upload}
  ssh "$TARGET" "cat > ~/${plan.service_name}.next/deploy/${plan.service_name}.service" <<'UNIT_EOF'
  #{unit_text}
  UNIT_EOF
  ssh "$TARGET" bash -s -- "$SERVICE" "$HOST" "$PORT" "$ENV_FILE" "$BACKUP_DIR" "$BOOTSTRAP_ENV" #{q(
    plan.entry
  )} #{q(plan.db)} <<'REMOTE'
  set -euo pipefail
  SERVICE="$1"
  HOST="$2"
  PORT="$3"
  ENV_FILE="$4"
  BACKUP_DIR="$5"
  BOOTSTRAP_ENV="$6"
  ENTRY="$7"
  DB_KIND="$8"
  APP="$HOME/$SERVICE"
  NEXT="$APP.next"
  PREV="$APP.prev"
  #{mo_install_remote}
  sudo mkdir -p "$BACKUP_DIR" "$(dirname "$ENV_FILE")"
  sudo chown -R "$(id -u):$(id -g)" "$(dirname "$BACKUP_DIR")"
  sudo chmod 0700 "$(dirname "$BACKUP_DIR")"

  if [ ! -f "$ENV_FILE" ]; then
    if [ "$BOOTSTRAP_ENV" = "1" ]; then
      GEN_KEY="$(openssl rand -hex 32 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(32))')"
      ENV_TMP="$(mktemp)"
      cat > "$ENV_TMP" <<ENV_EOF
  ARVO_SECRET_KEY=$GEN_KEY
  ARVO_DEV=0
  ARVO_INSECURE_COOKIES=0
  APP_URL=https://$HOST
  ENV_EOF
      sudo install -m 0600 -o "$(id -u)" -g "$(id -g)" "$ENV_TMP" "$ENV_FILE"
      rm -f "$ENV_TMP"
    else
      printf 'Missing %s on %s! Pass --bootstrap-env or install from deploy/env.example.\\n' "$ENV_FILE" "$(hostname)" >&2
      exit 1
    fi
  fi

  "$HOME/.local/bin/mo" check "$NEXT/$ENTRY"

  if systemctl is-active --quiet "${SERVICE}.service" 2>/dev/null; then
    sudo systemctl stop "${SERVICE}.service"
  fi

  SHA="$(cat "$NEXT/REVISION" 2>/dev/null || echo 'unknown')"
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  if [ "$DB_KIND" = "sqlite" ]; then
    for df in "$APP"/data/*.db "$APP"/data/*.sqlite "$APP"/data/*.sqlite3; do
      if [ -f "$df" ]; then
        if command -v sqlite3 >/dev/null 2>&1; then
          sqlite3 "$df" ".backup '$BACKUP_DIR/predeploy-$SHA-$TS-$(basename "$df")'"
        else
          cp "$df" "$BACKUP_DIR/predeploy-$SHA-$TS-$(basename "$df")"
        fi
      fi
    done
  else
    if [ -d "$APP/data" ]; then
      tar -czf "$BACKUP_DIR/predeploy-$SHA-$TS.tar.gz" -C "$APP" data
    fi
  fi

  #{data_mv_next}
  #{preserve_mv_next}

  activate() {
    sudo install -m 0644 "$APP/deploy/${SERVICE}.service" "/etc/systemd/system/${SERVICE}.service"
    sudo systemctl daemon-reload
    sudo systemctl enable "${SERVICE}.service" >/dev/null 2>&1 || true
    sudo systemctl restart "${SERVICE}.service"
  }

  #{health_fn}

  rm -rf "$PREV"
  if [ -d "$APP" ]; then
    mv "$APP" "$PREV"
  fi
  mv "$NEXT" "$APP"
  activate

  if ! healthy; then
    printf 'Health check failed; rolling back.\\n' >&2
    sudo journalctl -u "${SERVICE}.service" -n 40 --no-pager >&2 || true
    sudo systemctl stop "${SERVICE}.service" || true
    if [ -d "$PREV" ]; then
      #{data_mv_back}
      #{preserve_mv_back}
      mv "$APP" "$NEXT"
      mv "$PREV" "$APP"
      activate
    fi
    exit 1
  fi

  printf 'Deployed %s (%s) cleanly on %s (systemd active, health probes passed).\\n' "$SERVICE" "$SHA" "$(hostname)"
  REMOTE
  """
end

## Executes `arvo build`.
fn run_build(app_dir: Text, bargs: BuildArgs, app_files: Files, console: Console) : Int
  if bargs.help?
    console.print(build_usage())
    return 0
  end
  cfg = case Config.load(app_files.read_only)
    Ok(c): c
    Error(e):
      console.error("arvo build: #{e}")
      return 1
  end
  if not app_files.read_only.exists?(cfg.entry)
    console.error("arvo build: entry '#{cfg.entry}' does not exist")
    return 1
  end
  deps = case app_files.read_only.read_text("mo.toml")
    Ok(mt): parse_mo_toml_path_deps(mt)
    Error(_): []
  end
  script = build_bundle_script(bargs, cfg)
  if bargs.dry_run?
    plan = BuildPlan(
      app_dir: app_dir,
      entry: cfg.entry,
      frontend_dir: cfg.frontend_dir,
      out_dir: bargs.out_dir,
      skip_frontend?: bargs.skip_frontend?,
      skip_checks?: bargs.skip_checks?,
      direct_path_deps: deps,
      script: script
    )
    console.print(plan.to_json.to_text)
    return 0
  end
  if bargs.emit_script?
    console.print(script)
    return 0
  end
  console.print(
    "arvo build requires `bin/arvo` or `--emit-script` / `--dry-run`. Run `arvo build --help`."
  )
  1
end

fn run_deploy_init(app_dir: Text, iargs: DeployInitArgs, app_files: Files, console: Console) : Int
  if iargs.help?
    console.print(deploy_usage())
    return 0
  end
  cfg = case Config.load(app_files.read_only)
    Ok(c): c
    Error(e):
      console.error("arvo deploy init: #{e}")
      return 1
  end
  svc = resolve_service_name(iargs.service_name, cfg, app_files.read_only, app_dir)
  host = (iargs.host or (cfg.deploy.host or "#{svc}.exe.xyz")).trim
  user = (iargs.user or cfg.deploy.user).trim
  port = iargs.port or cfg.deploy.port
  db = (iargs.db or cfg.deploy.db).trim
  env_file = cfg.deploy.env_file or "/etc/#{svc}/#{svc}.env"

  unit_path = "deploy/#{svc}.service"
  env_ex_path = "deploy/env.example"
  if not iargs.force? and app_files.read_only.exists?(unit_path)
    console.error("arvo deploy init: '#{unit_path}' already exists (pass --force to overwrite)")
    return 1
  end

  unit_content = render_systemd_unit(
    svc,
    user,
    port,
    cfg.entry,
    env_file,
    cfg.deploy.data_dirs,
    cfg.deploy.preserve_paths
  )
  env_content = render_deploy_env_example(svc, host)
  existing_toml = case app_files.read_only.read_text("arvo.toml")
    Ok(t): Some(t)
    Error(_): None
  end
  next_toml = upsert_deploy_toml(existing_toml, host, user, port, svc, db)

  if not app_files.read_only.exists?("deploy")
    if app_files.make_folder("deploy") is Error(e)
      console.error("arvo deploy init: failed creating deploy folder: #{e}")
      return 1
    end
  end
  if app_files.write_text(unit_path, unit_content) is Error(e)
    console.error("arvo deploy init: failed writing #{unit_path}: #{e}")
    return 1
  end
  if app_files.write_text(env_ex_path, env_content) is Error(e)
    console.error("arvo deploy init: failed writing #{env_ex_path}: #{e}")
    return 1
  end
  if app_files.write_text("arvo.toml", next_toml) is Error(e)
    console.error("arvo deploy init: failed writing arvo.toml: #{e}")
    return 1
  end
  console.print(
    "Initialized exe.dev deploy files: #{unit_path}, #{env_ex_path}, arvo.toml [deploy]"
  )
  console.print("Next: arvo deploy #{host} --bootstrap-env")
  0
end

## Executes `arvo deploy` (`init`, `--dry-run`, `--emit-script`, `--rollback`, `--status`, `--logs`).
fn run_deploy(app_dir: Text, dargs: DeployArgs, app_files: Files, console: Console) : Int
  case dargs
    InitDeploy(ia): return run_deploy_init(app_dir, ia, app_files, console)
    RunDeploy(ra):
      if ra.help?
        console.print(deploy_usage())
        return 0
      end
      cfg = case Config.load(app_files.read_only)
        Ok(c): c
        Error(e):
          console.error("arvo deploy: #{e}")
          return 1
      end
      svc = resolve_service_name(ra.service_name, cfg, app_files.read_only, app_dir)
      host_opt = case ra.host
        Some(h): Some(h)
        None: cfg.deploy.host
      end
      host = case host_opt
        Some(h): h.trim
        None:
          console.error(
            "arvo deploy: missing target host (pass HOST, --host, or set [deploy].host in arvo.toml)"
          )
          return 1
      end
      if not valid_ssh_host?(host)
        console.error("arvo deploy: invalid host '#{host}'")
        return 1
      end
      user = (ra.user or cfg.deploy.user).trim
      port = ra.port or cfg.deploy.port
      env_file = cfg.deploy.env_file or "/etc/#{svc}/#{svc}.env"
      backup_dir = cfg.deploy.backup_dir or "/var/lib/#{svc}/backups"

      var probes = []
      for raw_p in cfg.deploy.health_checks
        p = case parse_health_probe(raw_p)
          Ok(hp): hp
          Error(e):
            console.error("arvo deploy: #{e}")
            return 1
        end
        probes = probes.append(p)
      end

      mode = if ra.status?
        "status"
      else if ra.logs?
        "logs"
      else if ra.rollback?
        "rollback"
      else
        "deploy"
      end

      draft_plan = DeployPlan(
        mode: mode,
        app_dir: app_dir,
        host: host,
        user: user,
        port: port,
        service_name: svc,
        db: cfg.deploy.db,
        entry: cfg.entry,
        env_file: env_file,
        backup_dir: backup_dir,
        data_dirs: cfg.deploy.data_dirs,
        preserve_paths: cfg.deploy.preserve_paths,
        health_checks: cfg.deploy.health_checks,
        upload_mo?: not ra.no_mo_upload?,
        bootstrap_env?: ra.bootstrap_env?,
        script: ""
      )
      bargs = BuildArgs(
        out_dir: ".arvo/dist",
        skip_frontend?: ra.skip_frontend?,
        skip_checks?: false,
        dry_run?: false,
        emit_script?: false,
        help?: false
      )
      script = build_deploy_script(draft_plan, probes, bargs, cfg, ra.allow_dirty?, ra.skip_build?)
      plan = DeployPlan(
        mode: mode,
        app_dir: app_dir,
        host: host,
        user: user,
        port: port,
        service_name: svc,
        db: cfg.deploy.db,
        entry: cfg.entry,
        env_file: env_file,
        backup_dir: backup_dir,
        data_dirs: cfg.deploy.data_dirs,
        preserve_paths: cfg.deploy.preserve_paths,
        health_checks: cfg.deploy.health_checks,
        upload_mo?: not ra.no_mo_upload?,
        bootstrap_env?: ra.bootstrap_env?,
        script: script
      )
      if ra.dry_run?
        console.print(plan.to_json.to_text)
        return 0
      end
      if ra.emit_script?
        console.print(script)
        return 0
      end
      console.print(
        "arvo deploy requires `bin/arvo` or `--emit-script` / `--dry-run`. Run `arvo deploy --help`."
      )
      1
  end
end

test "DeployCmd parses path deps, rewrites vendor mo.toml, scaffolds systemd, and renders build/deploy plans"
  assert parse_build_args(["--help"]) is Ok(bh) and bh.help?
  assert parse_build_args(["--out", "dist/out", "--skip-frontend", "--dry-run"]) is Ok(ba) and
    ba.out_dir == "dist/out" and
    ba.skip_frontend?
  assert parse_build_args(["--bogus"]) is Error(_)

  assert parse_deploy_args(["init", "--host", "myvm.exe.xyz", "--port", "8080"]) is
    Ok(InitDeploy(ia)) and
    ia.host == Some("myvm.exe.xyz")
  assert parse_deploy_args(["myvm.exe.xyz", "--bootstrap-env", "--rollback", "--dry-run"]) is
    Ok(RunDeploy(ra)) and
    ra.host == Some("myvm.exe.xyz") and
    ra.bootstrap_env? and
    ra.rollback? and
    ra.dry_run?
  assert parse_deploy_args(["--port", "0"]) is Error(_)

  sample_toml = """
    [package]
    name = "vellum"
    version = "0.1.0"

    [dependencies]
    arvo = { path = "../arvo" } # core
    arvo-modb = { path = "../arvo/packages/arvo-modb" }
    modb = { path = "../modb" }
    """
  deps = parse_mo_toml_path_deps(sample_toml)
  assert deps == [
    ("arvo", "../arvo"),
    ("arvo-modb", "../arvo/packages/arvo-modb"),
    ("modb", "../modb")
  ]
  rewritten = rewrite_mo_toml_for_vendor(sample_toml, deps)
  assert rewritten.contains?("arvo = { path = \"vendor/arvo\" }")
  assert rewritten.contains?("arvo-modb = { path = \"vendor/arvo-modb\" }")
  assert rewritten.contains?("modb = { path = \"vendor/modb\" }")

  assert parse_health_probe("GET /health=200") ==
    Ok(HealthProbe(method: "GET", path: "/health", expected_status: 200))
  assert parse_health_probe("bad") is Error(_)

  files = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "mo.toml": sample_toml,
    "main.mo": "module Main\n"
  })
  c_init = Console.fake()
  assert parse_deploy_args(["init", "--host", "vellum.exe.xyz", "--port", "8000", "--db", "modb"]) is
    Ok(init_parsed)
  assert run_deploy("apps/vellum", init_parsed, files, c_init) == 0
  assert files.exists?("deploy/vellum.service")
  assert files.exists?("deploy/env.example")
  assert files.read_only.read_text("deploy/vellum.service") is Ok(unit)
  assert unit.contains?("ProtectSystem=strict")
  assert unit.contains?("NoNewPrivileges=true")
  assert unit.contains?("--bind 127.0.0.1 --port 8000")
  assert files.read_only.read_text("arvo.toml") is Ok(updated_arvo)
  assert updated_arvo.contains?("host = \"vellum.exe.xyz\"")

  c_build = Console.fake()
  assert run_build(".", ba, files, c_build) == 0
  assert (c_build.printed.first or "").contains?("\"out_dir\":\"dist/out\"")

  assert parse_deploy_args(["--bootstrap-env", "--emit-script"]) is Ok(dep_emit)
  c_dep = Console.fake()
  assert run_deploy(".", dep_emit, files, c_dep) == 0
  dep_script = c_dep.printed.first or ""
  assert dep_script.contains?("sudo systemctl stop")
  assert dep_script.contains?("openssl rand -hex 32")
  assert dep_script.contains?("Health check failed; rolling back.")
end
