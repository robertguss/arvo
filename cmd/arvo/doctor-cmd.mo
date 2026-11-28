## Pure-Mo preflight readiness checker (`arvo doctor [--prod] [--json]`).
module DoctorCmd
expose DoctorArgs(..),
DoctorCheck(..),
DoctorReport(..),
doctor_usage,
parse_doctor_args,
evaluate_doctor,
run_doctor
use Command
use Config

## Parsed CLI options for `arvo doctor`.
struct DoctorArgs
  prod?: Bool
  json?: Bool
  no_mo_check?: Bool
  help?: Bool
end

## Single preflight diagnostic result (`"pass"`, `"warn"`, or `"fail"`).
struct DoctorCheck
  name: Text
  status: Text
  detail: Text
end

## Aggregate preflight summary emitted by `arvo doctor`.
struct DoctorReport
  ok?: Bool
  prod?: Bool
  app_dir: Text
  passed: Int
  warned: Int
  failed: Int
  checks: List(DoctorCheck)
end

## Usage text for `arvo doctor`.
fn doctor_usage() : Text
  """
    usage: arvo doctor [--app DIR] [--prod] [--json] [--no-mo-check]

    Runs app manifest, frontend build, environment hygiene, deploy systemd hardening,
    and `mo check` preflight checks before local serving or exe.dev deployment.

    Flags:
      --app DIR       Target application subdirectory (default: `.`)
      --prod          Enforce production invariants (real 64-hex secret, ARVO_DEV!=1, built manifest)
      --json          Emit JSON DoctorReport
      --no-mo-check   Skip running `mo check <entry>`
      -h, --help      Show this help
    """
end

## Parses arguments after `arvo doctor`.
fn parse_doctor_args(rest: List(Text)) : Result(DoctorArgs, Text)
  var prod? = false
  var json? = false
  var no_mo_check? = false
  for a in rest
    if a == "--help" or a == "-h"
      return Ok(DoctorArgs(prod?: prod?, json?: json?, no_mo_check?: no_mo_check?, help?: true))
    else if a == "--prod"
      prod? = true
    else if a == "--json"
      json? = true
    else if a == "--no-mo-check"
      no_mo_check? = true
    else
      return Error("unknown flag '#{a}' for `arvo doctor`. Run `arvo doctor --help`.")
    end
  end
  Ok(DoctorArgs(prod?: prod?, json?: json?, no_mo_check?: no_mo_check?, help?: false))
end

fn hex_64?(s: Text) : Bool
  return false if s.byte_count != 64
  for ch in s.chars
    ok? = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')
    return false if not ok?
  end
  true
end

fn dev_placeholder_key?(k: Text) : Bool
  lower = k.ascii_lowercase
  lower == "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20" or
    lower == "1111111111111111111111111111111122222222222222222222222222222222"
end

fn parse_health_spec?(spec: Text) : Bool
  parts = spec.trim.split(" ")
  return false if parts.size != 2
  method = (parts.first or "").ascii_uppercase
  return false if method != "GET" and method != "HEAD" and method != "POST"
  rest = parts.get(1) or ""
  eq_parts = rest.split("=")
  return false if eq_parts.size != 2
  path = eq_parts.first or ""
  code_raw = eq_parts.get(1) or ""
  return false if not path.starts_with?("/")
  case code_raw.to_int
    Some(c): c >= 100 and c <= 599
    None: false
  end
end

fn extract_package_name(mo_toml: Text) : Option(Text)
  var in_pkg? = false
  for raw in mo_toml.lines
    t = raw.trim
    continue if t.empty? or t.starts_with?("#")
    if t.starts_with?("[")
      in_pkg? = t == "[package]"
      continue
    end
    if in_pkg? and t.starts_with?("name")
      parts = t.split("=")
      if parts.size >= 2
        v = parts.drop(1).join("=").trim
        if v.starts_with?("\"") and v.ends_with?("\"") and v.byte_count >= 2
          name = (v.bytes.slice(1, v.byte_count - 1).decode_utf8 or "").trim
          return Some(name) if not name.empty?
        end
      end
    end
  end
  None
end

fn systemd_hardening_missing(unit_text: Text) : List(Text)
  required = [
    "ProtectSystem=strict",
    "NoNewPrivileges=true",
    "UMask=0077",
    "EnvironmentFile=",
    "ReadWritePaths="
  ]
  required.filter(fn(req) not unit_text.contains?(req) end)
end

## Evaluates all readiness checks for `app_dir` without exiting on first failure.
fn evaluate_doctor(app_dir: Text, dargs: DoctorArgs, rf: ReadFiles, cmd: Command, env: Env) : DoctorReport
  var checks = []

  (cfg, cfg_check) = case rf.read_text("arvo.toml")
    Ok(text):
      case Config.parse(text)
        Ok(c): (c, DoctorCheck(name: "arvo_toml", status: "pass", detail: "arvo.toml valid"))
        Error(e): (
          Config.default_config(),
          DoctorCheck(name: "arvo_toml", status: "fail", detail: "arvo.toml parse error: #{e}")
        )
      end
    Error(_): (
      Config.default_config(),
      DoctorCheck(
        name: "arvo_toml",
        status: "warn",
        detail: "arvo.toml absent (using Spec defaults)"
      )
    )
  end
  checks = checks.append(cfg_check)

  entry_ok? = not cfg.entry.trim.empty? and rf.exists?(cfg.entry)
  mo_toml_ok? = rf.exists?("mo.toml")
  manifest_check = if entry_ok? and mo_toml_ok?
    DoctorCheck(
      name: "entry_and_manifest",
      status: "pass",
      detail: "#{cfg.entry} + mo.toml present"
    )
  else if not entry_ok?
    DoctorCheck(
      name: "entry_and_manifest",
      status: "fail",
      detail: "missing entry file '#{cfg.entry}'"
    )
  else
    DoctorCheck(
      name: "entry_and_manifest",
      status: "fail",
      detail: "missing mo.toml package manifest"
    )
  end
  checks = checks.append(manifest_check)

  fdir = cfg.frontend_dir.drop_suffix("/") or cfg.frontend_dir
  fe_check = if rf.exists?("#{fdir}/package.json")
    if rf.exists?("public/manifest.json")
      DoctorCheck(name: "frontend_assets", status: "pass", detail: "public/manifest.json present")
    else if dargs.prod?
      DoctorCheck(
        name: "frontend_assets",
        status: "fail",
        detail: "missing public/manifest.json; run `arvo build` or Vite build"
      )
    else
      DoctorCheck(
        name: "frontend_assets",
        status: "warn",
        detail: "public/manifest.json missing (ok under Vite HMR; run `arvo build` for prod)"
      )
    end
  else
    DoctorCheck(name: "frontend_assets", status: "pass", detail: "backend-only app (no frontend)")
  end
  checks = checks.append(fe_check)

  feat_check = if rf.exists?(cfg.features_dir)
    DoctorCheck(name: "feature_specs", status: "pass", detail: "#{cfg.features_dir} present")
  else
    DoctorCheck(name: "feature_specs", status: "warn", detail: "missing #{cfg.features_dir}")
  end
  checks = checks.append(feat_check)

  raw_key = (env.get("ARVO_SECRET_KEY") or "").trim
  dev_on? = (env.get("ARVO_DEV") or "0") == "1"
  insecure_on? = (env.get("ARVO_INSECURE_COOKIES") or "0") == "1"
  env_check = if dargs.prod?
    if not hex_64?(raw_key) or dev_placeholder_key?(raw_key)
      DoctorCheck(
        name: "env_hygiene",
        status: "fail",
        detail: "production requires non-default 64-hex ARVO_SECRET_KEY"
      )
    else if dev_on? or insecure_on?
      DoctorCheck(
        name: "env_hygiene",
        status: "fail",
        detail: "ARVO_DEV=1 or ARVO_INSECURE_COOKIES=1 forbidden under --prod"
      )
    else
      DoctorCheck(
        name: "env_hygiene",
        status: "pass",
        detail: "prod secret key & secure env verified"
      )
    end
  else if raw_key.empty?
    DoctorCheck(
      name: "env_hygiene",
      status: "warn",
      detail: "ARVO_SECRET_KEY unset (`arvo dev` supplies a dev-only key)"
    )
  else if not hex_64?(raw_key)
    DoctorCheck(
      name: "env_hygiene",
      status: "fail",
      detail: "ARVO_SECRET_KEY is set but not 64 hex chars"
    )
  else if dev_placeholder_key?(raw_key)
    DoctorCheck(
      name: "env_hygiene",
      status: "warn",
      detail: "ARVO_SECRET_KEY uses a dev placeholder key"
    )
  else
    DoctorCheck(name: "env_hygiene", status: "pass", detail: "64-hex ARVO_SECRET_KEY configured")
  end
  checks = checks.append(env_check)

  pkg_name = case rf.read_text("mo.toml")
    Ok(mt): extract_package_name(mt)
    Error(_): None
  end
  svc_opt = case cfg.deploy.service_name
    Some(s): Some(s)
    None: pkg_name
  end
  bad_probes = cfg.deploy.health_checks.filter(fn(p) not parse_health_spec?(p) end)
  deploy_check = if cfg.deploy.port < 1 or cfg.deploy.port > 65535
    DoctorCheck(
      name: "deploy_config",
      status: "fail",
      detail: "invalid deploy.port #{cfg.deploy.port}"
    )
  else if not bad_probes.empty?
    DoctorCheck(
      name: "deploy_config",
      status: "fail",
      detail: "invalid health_checks entry: #{bad_probes.first or ""}"
    )
  else
    case svc_opt
      Some(svc):
        unit_path = "deploy/#{svc}.service"
        case rf.read_text(unit_path)
          Ok(unit_txt):
            missing = systemd_hardening_missing(unit_txt)
            if missing.empty?
              DoctorCheck(
                name: "deploy_config",
                status: "pass",
                detail: "#{unit_path} hardening & probes verified"
              )
            else
              DoctorCheck(
                name: "deploy_config",
                status: "fail",
                detail: "#{unit_path} missing hardening directives: #{missing.join(", ")}"
              )
            end
          Error(_):
            if cfg.deploy.host is Some(_)
              DoctorCheck(
                name: "deploy_config",
                status: "warn",
                detail: "deploy.host set but #{unit_path} missing (run `arvo deploy init`)"
              )
            else
              DoctorCheck(name: "deploy_config", status: "pass", detail: "deploy defaults valid")
            end
        end
      None: DoctorCheck(name: "deploy_config", status: "pass", detail: "deploy defaults valid")
    end
  end
  checks = checks.append(deploy_check)

  if not dargs.no_mo_check?
    mo_chk = if not entry_ok?
      DoctorCheck(name: "mo_check", status: "fail", detail: "skipped (entry missing)")
    else if env.get("ARVO_DOCTOR_MO_CHECK_STATUS") is Some(st)
      if st == "0"
        DoctorCheck(name: "mo_check", status: "pass", detail: "`mo check #{cfg.entry}` passed")
      else
        msg = (env.get("ARVO_DOCTOR_MO_CHECK_OUTPUT") or "").trim
        DoctorCheck(
          name: "mo_check",
          status: "fail",
          detail: "`mo check #{cfg.entry}` failed: #{msg}"
        )
      end
    else
      scoped = if app_dir == ".": cmd else: cmd.within(app_dir)
      case scoped.run("mo", ["check", cfg.entry], 30.seconds)
        Ok(out) if out.status == 0: DoctorCheck(
          name: "mo_check",
          status: "pass",
          detail: "`mo check #{cfg.entry}` passed"
        )
        Ok(out): DoctorCheck(
          name: "mo_check",
          status: "fail",
          detail: "`mo check #{cfg.entry}` failed: #{out.stderr.trim}"
        )
        Error(e): DoctorCheck(
          name: "mo_check",
          status: "fail",
          detail: "failed running mo check: #{e}"
        )
      end
    end
    checks = checks.append(mo_chk)
  end

  passed = checks.count(fn(c) c.status == "pass" end)
  warned = checks.count(fn(c) c.status == "warn" end)
  failed = checks.count(fn(c) c.status == "fail" end)
  DoctorReport(
    ok?: failed == 0,
    prod?: dargs.prod?,
    app_dir: app_dir,
    passed: passed,
    warned: warned,
    failed: failed,
    checks: checks
  )
end

## Executes `arvo doctor` against `app_files`, returning 0 when no checks fail.
fn run_doctor(
  app_dir: Text,
  dargs: DoctorArgs,
  app_files: Files,
  cmd: Command,
  env: Env,
  console: Console
) : Int
  if dargs.help?
    console.print(doctor_usage())
    return 0
  end
  rep = evaluate_doctor(app_dir, dargs, app_files.read_only, cmd, env)
  if dargs.json?
    console.print(rep.to_json.to_text)
  else
    for c in rep.checks
      tag = if c.status == "pass"
        "PASS"
      else if c.status == "warn"
        "WARN"
      else
        "FAIL"
      end
      console.print("[#{tag}] #{c.name}: #{c.detail}")
    end
    console.print("Doctor: #{rep.passed} passed, #{rep.warned} warned, #{rep.failed} failed")
  end
  if rep.ok?: 0 else: 1
end

test "DoctorCmd validates app readiness, prod secret hygiene, systemd hardening, and JSON output"
  assert parse_doctor_args(["--help"]) is Ok(h) and h.help?
  assert parse_doctor_args(["--prod", "--json", "--no-mo-check"]) is Ok(da) and
    da.prod? and
    da.json? and
    da.no_mo_check?
  assert parse_doctor_args(["--bogus"]) is Error(_)

  hard_unit = """
    [Service]
    User=exedev
    EnvironmentFile=/etc/demo/demo.env
    UMask=0077
    NoNewPrivileges=true
    ProtectSystem=strict
    ReadWritePaths=/home/exedev/demo/data
    """
  files = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n[deploy]\nhost = \"demo.exe.xyz\"\nservice = \"demo\"\nhealth_checks = [\"GET /health=200\"]\n",
    "mo.toml": "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n",
    "main.mo": "module Main\n",
    "frontend/package.json": "{}\n",
    "public/manifest.json": "{}\n",
    "specs/features/home.feature.md": "# Home\n",
    "deploy/demo.service": hard_unit
  })
  cmd_ok = Command.fake(
    Command.replies([(Command.spec("mo", ["check", "main.mo"]), Command.ok_output(""))])
  )
  prod_key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  c_dev = Console.fake()
  assert run_doctor(
    ".",
    DoctorArgs(prod?: false, json?: false, no_mo_check?: false, help?: false),
    files,
    cmd_ok,
    Env.of({}),
    c_dev
  ) ==
    0

  c_prod_bad = Console.fake()
  assert run_doctor(
    ".",
    DoctorArgs(prod?: true, json?: true, no_mo_check?: false, help?: false),
    files,
    cmd_ok,
    Env.of({
      "ARVO_SECRET_KEY": "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
      "ARVO_DEV": "1"
    }),
    c_prod_bad
  ) ==
    1
  assert (c_prod_bad.printed.first or "").contains?("\"failed\":1")

  c_prod_ok = Console.fake()
  assert run_doctor(
    ".",
    DoctorArgs(prod?: true, json?: true, no_mo_check?: false, help?: false),
    files,
    cmd_ok,
    Env.of({"ARVO_SECRET_KEY": prod_key}),
    c_prod_ok
  ) ==
    0
  assert (c_prod_ok.printed.first or "").contains?("\"ok?\":true")
end
