## Pure-Mo `arvo` verification, contract codegen, feature map, and simulation CLI.
module Main
expose CliCmd(..), CliInvocation(..), parse_args, parse_invocation, usage, run_cli, main
use Arvo.Inertia
use Arvo.Testing.Feature
use Codegen
use Command
use Config
use Control
use Dossier
use FrontendCheck
use Json
use StatechartCmd
use Tamper

## Parsed CLI command and flags.
enum CliCmd
  HelpCmd(topic: Option(Text))
  ContractsCmd(check?: Bool)
  VerifyCmd(tier: Text, json?: Bool, changed?: Bool, base_ref: Option(Text))
  FeatureCmd(validate?: Bool, manifest_out: Option(Text), dir: Option(Text))
  SimCmd(entry: Option(Text), only: Option(Text))
  ControlCmd(sub: Control.ControlCmd)
  RunStatechartCmd(args: StatechartCmd.StatechartArgs)
end

## Parsed CLI invocation combining `--app DIR` target (default `"."`) and `CliCmd`.
struct CliInvocation
  app_dir: Text
  cmd: CliCmd
end

## Returns top-level or subcommand usage help text.
fn usage(topic: Option(Text)) : Text
  case topic
    Some("contracts"): """
      usage: arvo contracts [--app DIR] [--check]

      Generates frontend TypeScript contracts from the app's Json.schema[T]() manifest
      and checks that every PageContract.component resolves to a page .tsx file.

      Flags:
        --app DIR  Target application subdirectory (default: `.`)
        --check    Fail non-zero if generated arvo.gen.ts is stale or tsc --noEmit fails
        -h, --help Show this help
      """
    Some("verify"): """
      usage: arvo verify [--app DIR] [--tier fast|feature|full] [--json] [--changed] [--base REF]

      Runs the Arvo verification ladder, detects contract/promise tampering, and emits
      machine-readable events to .arvo/dossier/verify.jsonl.

      Flags:
        --app DIR    Target application subdirectory (default: `.`)
        --tier TIER  Verification tier: fast (default), feature, or full
        --json       Print NDJSON events to stdout instead of the terminal scorecard
        --changed    Focus checks on changed files where supported
        --base REF   Git base branch/ref for committed+uncommitted tamper comparison
        -h, --help   Show this help
      """
    Some("feature"): """
      usage: arvo feature [--app DIR] [--validate] [--manifest OUT] [DIR]

      Validates .feature.md Executable Feature Maps and optionally exports @browser scenarios.

      Flags:
        --app DIR       Target application subdirectory (default: `.`)
        --validate      Validate all .feature.md files under DIR (default from arvo.toml)
        --manifest OUT  Write @browser scenario manifest JSON to OUT
        -h, --help      Show this help
      """
    Some("sim"): """
      usage: arvo sim [--app DIR] [--entry FILE] [--only NAME]

      Runs Arvo.Sim deterministic web simulation tests via `mo test --json`.

      Flags:
        --app DIR     Target application subdirectory (default: `.`)
        --entry FILE  Entry Mo module (default from arvo.toml)
        --only NAME   Run only the named simulation check
        -h, --help    Show this help
      """
    Some("control"): Control.control_usage()
    Some("statechart"): StatechartCmd.statechart_usage()
    Some(_) | None: """
      Arvo Verification & Testing CLI (pure Mo)

      usage: arvo <command> [--app DIR] [flags]

      Commands:
        contracts [--app DIR] [--check]                         Generate/verify frontend/src/arvo.gen.ts from Json.schema[T]()
        verify [--app DIR] [--tier fast|feature|full] [--json]  Run verification checks, tamper check, and write verify.jsonl
        feature [--app DIR] [--validate] [--manifest OUT] [DIR] Parse .feature.md specs and export @browser manifest
        sim [--app DIR] [--entry FILE] [--only NAME]            Run Arvo.Sim simulation tests
        control <subcmd> [--app DIR] [flags]                    Manage isolated runtime instances (launch, doctor, inspect, reset, drive, cleanup)
        statechart [check|render] [--app DIR] [--out DIR]       Explore Jobs/Session statecharts, replay code, & check sync commits

      Run `arvo <command> --help` for command-specific flags.
      """
  end
end

fn help_flag?(arg: Text) : Bool
  arg == "--help" or arg == "-h"
end

fn parse_contracts_args(rest: List(Text)) : Result(CliCmd, Text)
  var check? = false
  for a in rest
    if help_flag?(a)
      return Ok(HelpCmd(topic: Some("contracts")))
    else if a == "--check"
      check? = true
    else
      return Error("unknown flag '#{a}' for `arvo contracts`. Run `arvo contracts --help`.")
    end
  end
  Ok(ContractsCmd(check?: check?))
end

fn parse_verify_args(rest: List(Text)) : Result(CliCmd, Text)
  var tier = "fast"
  var json? = false
  var changed? = false
  var base_ref = None
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if help_flag?(a)
      return Ok(HelpCmd(topic: Some("verify")))
    else if a == "--json"
      json? = true
    else if a == "--changed"
      changed? = true
    else if a == "--base"
      next_base = rest.get(i + 1) or ""
      if next_base.empty? or next_base.starts_with?("-")
        return Error("`--base` requires a git ref or commit SHA. Run `arvo verify --help`.")
      end
      base_ref = Some(next_base)
      i += 1
    else if a == "--tier"
      next_val = rest.get(i + 1) or ""
      if next_val.empty? or next_val.starts_with?("-")
        return Error(
          "`--tier` requires a value (`fast`, `feature`, or `full`). Run `arvo verify --help`."
        )
      end
      if next_val != "fast" and next_val != "feature" and next_val != "full"
        return Error("unknown tier '#{next_val}'; expected `fast`, `feature`, or `full`.")
      end
      tier = next_val
      i += 1
    else
      return Error("unknown flag '#{a}' for `arvo verify`. Run `arvo verify --help`.")
    end
    i += 1
  end
  Ok(VerifyCmd(tier: tier, json?: json?, changed?: changed?, base_ref: base_ref))
end

fn parse_feature_args(rest: List(Text)) : Result(CliCmd, Text)
  var validate? = false
  var manifest_out = None
  var dir = None
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if help_flag?(a)
      return Ok(HelpCmd(topic: Some("feature")))
    else if a == "--validate"
      validate? = true
    else if a == "--manifest"
      next_val = rest.get(i + 1) or ""
      if next_val.empty? or next_val.starts_with?("-")
        return Error("`--manifest` requires an output path. Run `arvo feature --help`.")
      end
      manifest_out = Some(next_val)
      i += 1
    else if a.starts_with?("-")
      return Error("unknown flag '#{a}' for `arvo feature`. Run `arvo feature --help`.")
    else if dir == None
      dir = Some(a)
    else
      return Error("unexpected extra positional argument '#{a}' for `arvo feature`.")
    end
    i += 1
  end
  Ok(FeatureCmd(validate?: validate?, manifest_out: manifest_out, dir: dir))
end

fn parse_sim_args(rest: List(Text)) : Result(CliCmd, Text)
  var entry = None
  var only = None
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if help_flag?(a)
      return Ok(HelpCmd(topic: Some("sim")))
    else if a == "--entry"
      next_val = rest.get(i + 1) or ""
      if next_val.empty? or next_val.starts_with?("-")
        return Error("`--entry` requires a Mo file path. Run `arvo sim --help`.")
      end
      entry = Some(next_val)
      i += 1
    else if a == "--only"
      next_val = rest.get(i + 1) or ""
      if next_val.empty? or next_val.starts_with?("-")
        return Error("`--only` requires a check name. Run `arvo sim --help`.")
      end
      only = Some(next_val)
      i += 1
    else
      return Error("unknown flag '#{a}' for `arvo sim`. Run `arvo sim --help`.")
    end
    i += 1
  end
  Ok(SimCmd(entry: entry, only: only))
end

## Parses CLI argument list into a typed `CliCmd` or actionable error message.
fn parse_args(args: List(Text)) : Result(CliCmd, Text)
  sub = case args.first
    Some(s): s
    None: return Ok(HelpCmd(topic: None))
  end
  rest = args.drop(1)
  if help_flag?(sub)
    Ok(HelpCmd(topic: None))
  else if sub == "contracts"
    parse_contracts_args(rest)
  else if sub == "verify"
    parse_verify_args(rest)
  else if sub == "feature"
    parse_feature_args(rest)
  else if sub == "sim"
    parse_sim_args(rest)
  else if sub == "control"
    case Control.parse_control_args(rest)
      Ok(Control.ControlHelpCmd): Ok(HelpCmd(topic: Some("control")))
      Ok(c): Ok(ControlCmd(sub: c))
      Error(e): Error(e)
    end
  else if sub == "statechart"
    case StatechartCmd.parse_statechart_args(rest)
      Ok(sa):
        if sa.help?
          Ok(HelpCmd(topic: Some("statechart")))
        else
          Ok(RunStatechartCmd(args: sa))
        end
      Error(e): Error(e)
    end
  else
    Error("unknown command '#{sub}'. Run `arvo --help` to see available commands.")
  end
end

fn normalize_app_dir(raw: Text) : Text
  t = raw.trim
  no_dot = t.drop_prefix("./") or t
  no_slash = no_dot.drop_suffix("/") or no_dot
  if no_slash.empty?: "." else: no_slash
end

fn extract_app_dir(args: List(Text)) : Result((Text, List(Text)), Text)
  var app_dir = "."
  var filtered = []
  var i = 0
  while i < args.size
    a = args.get(i) or ""
    if a == "--app"
      next_val = args.get(i + 1) or ""
      if next_val.empty? or next_val.starts_with?("-")
        return Error("`--app` requires a directory path. Run `arvo --help`.")
      end
      app_dir = normalize_app_dir(next_val)
      i += 1
    else
      filtered = filtered.append(a)
    end
    i += 1
  end
  Ok((app_dir, filtered))
end

## Parses full CLI invocation combining `--app DIR` and subcommand `CliCmd`.
fn parse_invocation(args: List(Text)) : Result(CliInvocation, Text)
  (app_dir, rest) = try extract_app_dir(args)
  cmd = try parse_args(rest)
  Ok(CliInvocation(app_dir: app_dir, cmd: cmd))
end

struct CmdTimeouts
  git_secs: Int
  mo_secs: Int
  tsc_secs: Int
  slow_secs: Int
end

fn default_timeouts() : CmdTimeouts
  CmdTimeouts(git_secs: 15, mo_secs: 30, tsc_secs: 60, slow_secs: 600)
end

fn join_app_path(app_dir: Text, rel: Text) : Text
  if app_dir == ".": rel else: "#{app_dir}/#{rel}"
end

fn strip_repo_prefix(path: Text, prefix: Text) : Option(Text)
  if prefix.empty?: Some(path) else: path.drop_prefix(prefix)
end

fn parent_dir(path: Text) : Text
  parts = path.split("/")
  if parts.size == 1
    "."
  else
    parts.take(parts.size - 1).join("/")
  end
end

fn elapsed_ms(clock: Clock, start: Time) : Int
  ms = (clock.now - start).in_milliseconds
  if ms >= 1: ms else: 0
end

fn skip_scan_dir?(name: Text) : Bool
  examples
    skip_scan_dir?(".arvo")
    skip_scan_dir?(".git")
    skip_scan_dir?("node_modules")
    skip_scan_dir?("public")
    not skip_scan_dir?("specs")
  end

  name.starts_with?(".") or name == "node_modules" or name == "public"
end

fn collect_tamper_files(files: ReadFiles, dir: Text, globs: List(Text)) : Map(Text, Text)
  var acc = {}
  case files.entries(dir)
    Error(_): return acc
    Ok(ents):
      for ent in ents
        rel = if dir == ".": ent.name else: "#{dir}/#{ent.name}"
        if ent.kind is Folder
          if not skip_scan_dir?(ent.name)
            for (k, v) in collect_tamper_files(files, rel, globs)
              acc = acc.set(k, v)
            end
          end
        else if ent.kind is File
          if rel.ends_with?(".mo") or globs.any?(fn(g) Tamper.glob_match?(g, rel) end)
            if files.read_text(rel) is Ok(txt)
              acc = acc.set(rel, txt)
            end
          end
        end
      end
  end
  acc
end

fn extract_contracts_json(app_dir: Text, cfg: Config.ArvoConfig, files: Files, cmd: Command) : Result(
  List(Inertia.PageContract),
  Text
)
  timeouts = default_timeouts()
  entry_path = join_app_path(app_dir, cfg.entry)
  out = try cmd.run("mo", ["run", entry_path, "--arvo-contracts"], timeouts.mo_secs.seconds)
    .map_error(fn(e) "failed running `mo run #{entry_path} --arvo-contracts`: #{e}" end)
  raw_json = if out.ok? and out.stdout.trim.starts_with?("[")
    out.stdout.trim
  else
    probe_path = "arvo-contracts-probe.mo"
    probe_cmd_path = join_app_path(app_dir, probe_path)
    probe_src = "module ArvoContractsProbe\nuse #{cfg.contracts_module}\nuse Json\nfn main(console: Console)\n  console.print(Json.encode(#{cfg
      .contracts_module}.#{cfg.contracts_fn}()))\nend\n"
    try files.write_text(probe_path, probe_src).map_error(fn(e) "#{e}" end)
    probe_res = cmd.run("mo", ["run", probe_cmd_path], timeouts.mo_secs.seconds)
    _rm = files.remove(probe_path)
    probe_out = try probe_res.map_error(fn(e) "failed running contract probe: #{e}" end)
    if not probe_out.ok?
      return Error(
        "failed extracting contracts from #{entry_path} or #{cfg.contracts_module}.#{cfg
          .contracts_fn}: #{probe_out.stderr}"
      )
    end
    probe_out.stdout.trim
  end

  Json.decode_strict[List(Inertia.PageContract)](raw_json).map_error(
    fn(e) "invalid PageContract JSON from #{entry_path}: #{e.to_text}" end
  )
end

fn try_tsc_check(app_dir: Text, cfg: Config.ArvoConfig, files: ReadFiles, cmd: Command) : Result(
  Unit,
  Text
)
  timeouts = default_timeouts()
  fdir = cfg.frontend_dir.drop_suffix("/") or cfg.frontend_dir
  tsconfig = "#{fdir}/tsconfig.json"
  tsc_js = "#{fdir}/node_modules/typescript/bin/tsc"
  return Ok(Unit) if not files.exists?(tsconfig) or not files.exists?(tsc_js)

  out = try cmd.within(join_app_path(app_dir, fdir)).allow_programs(["node"]).run(
    "node",
    ["--openssl-config=/dev/null", "./node_modules/typescript/bin/tsc", "--noEmit"],
    timeouts.tsc_secs.seconds
  ).map_error(fn(e) "failed invoking tsc: #{e}" end)
  if out.ok?
    Ok(Unit)
  else
    details = [out.stdout.trim, out.stderr.trim].filter(fn(s) not s.empty? end).join("\n")
    Error("TypeScript check failed (`tsc --noEmit`):\n#{details}")
  end
end

fn run_contracts_flow(
  app_dir: Text,
  check?: Bool,
  cfg: Config.ArvoConfig,
  files: Files,
  cmd: Command
) : Result((Int, Text), Text)
  contracts = try extract_contracts_json(app_dir, cfg, files, cmd)
  missing = Codegen.missing_page_components(files.read_only, cfg.pages_dir, contracts)
  if not missing.empty?
    return Error(
      "missing frontend page component(s): #{missing.join(", ")}. Create the .tsx file(s) or update #{cfg
        .contracts_module}.#{cfg.contracts_fn}()."
    )
  end

  ts_text = Codegen.generate_ts(contracts, None)
  if check?
    case files.read_text(cfg.contracts_out)
      Error(_): return Error(
        "missing generated contracts file #{cfg.contracts_out}. Run `arvo contracts` to generate it."
      )
      Ok(existing):
        if existing != ts_text
          return Error(
            "contract drift detected in #{cfg.contracts_out}. Run `arvo contracts` to regenerate TypeScript types."
          )
        end
    end
    try try_tsc_check(app_dir, cfg, files.read_only, cmd)
    Ok((contracts.size, "Contracts up to date (#{contracts.size} pages, #{cfg.contracts_out})"))
  else
    pdir = parent_dir(cfg.contracts_out)
    if pdir != "."
      try files.make_folder(pdir).map_error(fn(e) "#{e}" end)
    end
    try files.write_text(cfg.contracts_out, ts_text).map_error(fn(e) "#{e}" end)
    Ok((contracts.size, "Generated #{cfg.contracts_out} (#{contracts.size} pages)"))
  end
end

fn collect_feature_files(files: ReadFiles, dir: Text) : Result(List(Text), Text)
  clean = dir.drop_suffix("/") or dir
  if not files.exists?(clean)
    return Error("features directory '#{clean}' does not exist")
  end
  entries = try files.walk(clean).map_error(fn(e) "#{e}" end)
  matched = entries.filter_map(fn(ent)
    if ent.kind is File and ent.name.ends_with?(".feature.md")
      Some("#{clean}/#{ent.name}")
    else
      None
    end
  end)
  Ok(matched.sort)
end

fn strip_leading_spaces(line: Text, count: Int) : Text
  return line if count <= 0
  chars = line.chars
  var drop_n = 0
  while drop_n < count and drop_n < chars.size
    break if (chars.get(drop_n) or ' ') != ' '
    drop_n += 1
  end
  Text.from_chars(chars.drop(drop_n))
end

fn count_leading_spaces(line: Text) : Int
  var n = 0
  for ch in line.chars
    break if ch != ' '
    n += 1
  end
  n
end

fn extract_inline_feature_specs(src: Text) : List((Text, Text))
  lines = src.lines
  var out = []
  var i = 0
  while i < lines.size
    raw = lines.get(i) or ""
    trimmed = raw.trim
    if trimmed.contains?("_feature_spec = \"\"\"")
      var_name = (trimmed.split("=").first or "").trim
      var body = []
      var j = i + 1
      var indent = 0
      var closed? = false
      while j < lines.size
        ln = lines.get(j) or ""
        if ln.trim == "\"\"\""
          indent = count_leading_spaces(ln)
          closed? = true
          break
        end
        body = body.append(ln)
        j += 1
      end
      if closed?
        dedented = body.map(fn(b)
          strip_leading_spaces(b, indent).replace("\\\\", "\\")
        end).join("\n").trim
        out = out.append((var_name, dedented))
        i = j
      end
    end
    i += 1
  end
  out
end

fn verify_inline_feature_copies(
  files: ReadFiles,
  cfg: Config.ArvoConfig,
  docs: List(Feature.FeatureDoc)
) : Result(Unit, Text)
  return Ok(Unit) if not files.exists?(cfg.entry)
  entry_src = try files.read_text(cfg.entry).map_error(fn(e) "#{e}" end)
  inline_specs = extract_inline_feature_specs(entry_src)
  return Ok(Unit) if inline_specs.empty?

  var disk_contents = {}
  for doc in docs
    if files.read_text(doc.path) is Ok(raw)
      disk_contents = disk_contents.set(doc.path, raw.replace("\r\n", "\n").trim)
    end
  end

  for (var_name, raw_inline) in inline_specs
    inline_doc = try Feature.parse("#{cfg.entry}:#{var_name}", raw_inline).map_error(
      fn(pe) "#{pe.path}:#{pe.line}: #{pe.message}" end
    )
    matched = docs.find(fn(d) d.title == inline_doc.title or d.feature_name == inline_doc.feature_name end)
    case matched
      None: return Error(
        "inline feature spec '#{var_name}' in #{cfg.entry} has no matching file under #{cfg.features_dir}"
      )
      Some(disk_doc):
        disk_text = disk_contents.get(disk_doc.path) or ""
        if raw_inline.replace("\r\n", "\n").trim != disk_text
          return Error(
            "inline feature spec '#{var_name}' in #{cfg.entry} drifted from #{disk_doc.path}"
          )
        end
    end
  end
  Ok(Unit)
end

fn load_and_parse_features(files: ReadFiles, cfg: Config.ArvoConfig, dir: Text) : Result(
  List(Feature.FeatureDoc),
  Text
)
  paths = try collect_feature_files(files, dir)
  var docs = []
  var errs = []
  for p in paths
    content = try files.read_text(p).map_error(fn(e) "#{e}" end)
    case Feature.parse(p, content)
      Ok(doc): docs = docs.append(doc)
      Error(pe): errs = errs.append("#{pe.path}:#{pe.line}: #{pe.message}")
    end
  end
  if not errs.empty?
    return Error(errs.join("\n"))
  end
  try verify_inline_feature_copies(files, cfg, docs)
  Ok(docs)
end

fn run_feature_cmd(
  manifest_out: Option(Text),
  dir_opt: Option(Text),
  files: Files,
  console: Console
) : Int
  cfg = case Config.load(files.read_only)
    Ok(c): c
    Error(e):
      console.error("arvo feature: #{e}")
      return 1
  end
  target_dir = dir_opt or cfg.features_dir
  docs = case load_and_parse_features(files.read_only, cfg, target_dir)
    Ok(d): d
    Error(e):
      console.error(e)
      return 1
  end
  if manifest_out is Some(out_path)
    pdir = parent_dir(out_path)
    if pdir != "."
      if files.make_folder(pdir) is Error(e)
        console.error("arvo feature: #{e}")
        return 1
      end
    end
    payload = "#{Feature.browser_manifest_json(docs).pretty}\n"
    if files.write_text(out_path, payload) is Error(e)
      console.error("arvo feature: failed writing manifest #{out_path}: #{e}")
      return 1
    end
  end
  total_scenarios = docs.map(fn(d) d.scenarios.size end).sum
  console.print("Validated #{docs.size} feature file(s), #{total_scenarios} scenario(s)")
  0
end

fn run_sim_cmd(
  app_dir: Text,
  entry_opt: Option(Text),
  only_opt: Option(Text),
  files: ReadFiles,
  cmd: Command,
  console: Console
) : Int
  cfg = case Config.load(files)
    Ok(c): c
    Error(e):
      console.error("arvo sim: #{e}")
      return 1
  end
  timeouts = default_timeouts()
  entry = join_app_path(app_dir, entry_opt or cfg.entry)
  var mo_args = ["test", "--json"]
  if only_opt is Some(name)
    mo_args = mo_args.append("--only").append(name)
  end
  mo_args = mo_args.append(entry)
  out = case cmd.run("mo", mo_args, timeouts.slow_secs.seconds)
    Ok(o): o
    Error(e):
      console.error("arvo sim: failed running `mo #{mo_args.join(" ")}`: #{e}")
      return 1
  end
  summary = Dossier.parse_mo_test_json(out.stdout)
  if out.ok? and summary.failed == 0 and summary.stopped == 0 and summary.errors == 0
    console.print("Arvo Sim: PASS (#{summary.passed} checks passed in #{entry})")
    0
  else
    console.error(
      "Arvo Sim: FAIL (#{summary.passed} passed, #{summary.failed} failed, #{summary.stopped} stopped)"
    )
    1
  end
end

fn resolve_ref_to_merge_base(bref: Text, cmd: Command, git_dur: Duration) : Result(Text, Text)
  if cmd.run("git", ["merge-base", "HEAD", bref], git_dur) is Ok(mb_out)
    mb = mb_out.stdout.trim
    if mb_out.ok? and not mb.empty?
      return Ok(mb)
    end
  end
  if cmd.run("git", ["rev-parse", "--verify", bref], git_dur) is Ok(rv_out)
    if rv_out.ok?
      return Ok(bref)
    end
  end
  Error("cannot resolve tamper --base ref '#{bref}'")
end

fn resolve_default_tamper_base(cmd: Command, git_dur: Duration) : Result(Text, Text)
  for cand in ["origin/main", "main"]
    if cmd.run("git", ["rev-parse", "--verify", cand], git_dur) is Ok(rv_out)
      if rv_out.ok?
        if cmd.run("git", ["merge-base", "HEAD", cand], git_dur) is Ok(mb_out)
          mb = mb_out.stdout.trim
          if mb_out.ok? and not mb.empty?
            return Ok(mb)
          end
        end
        return Error("failed computing git merge-base HEAD #{cand}")
      end
    end
  end
  Ok("HEAD")
end

fn merge_tamper_globs(base: List(Text), extra: List(Text)) : List(Text)
  var merged = base
  for g in extra
    if not g.trim.empty? and not merged.contains?(g)
      merged = merged.append(g)
    end
  end
  merged
end

fn run_tamper_phase(
  app_dir: Text,
  tier: Text,
  base_opt: Option(Text),
  cfg: Config.ArvoConfig,
  root_files: ReadFiles,
  files: Files,
  cmd: Command,
  clock: Clock
) : Dossier.VerifyEvent
  t0 = clock.now
  ts = t0.to_text
  timeouts = default_timeouts()
  git_dur = timeouts.git_secs.seconds
  var git_prefix = ""
  if cmd.run("git", ["rev-parse", "--show-prefix"], git_dur) is Ok(pfx_out)
    if pfx_out.ok?
      git_prefix = pfx_out.stdout.trim
    end
  end
  effective_prefix = if app_dir == ".": git_prefix else: "#{git_prefix}#{app_dir}/"

  fdir_clean = cfg.features_dir.drop_suffix("/") or cfg.features_dir
  sdir_clean = cfg.strength_dir.drop_suffix("/") or cfg.strength_dir
  fedir_clean = cfg.frontend_dir.drop_suffix("/") or cfg.frontend_dir
  var effective_globs = merge_tamper_globs(Config.default_config().tamper_globs, cfg.tamper_globs)
  effective_globs = merge_tamper_globs(
    effective_globs,
    [
      "arvo.toml",
      "#{fdir_clean}/**/*.feature.md",
      "#{sdir_clean}/**/*",
      "#{fedir_clean}/stryker.config.*"
    ]
  )
  repo_toml = if effective_prefix.empty?: "arvo.toml" else: "#{effective_prefix}arvo.toml"

  # Never honor working-tree `arvo.toml` `base_ref`: only accept `--base` or trusted base copy.
  var read_compare_toml? = true
  compare_ref = case base_opt
    Some(explicit_ref):
      case resolve_ref_to_merge_base(explicit_ref, cmd, git_dur)
        Ok(r): r
        Error(berr):
          ms_err = elapsed_ms(clock, t0)
          var ev = Dossier.new_event(ts, tier, "tamper_check", "warn", ms_err)
          ev.detail = Some("tamper base resolution failed: #{berr}")
          return ev
      end
    None:
      default_ref = case resolve_default_tamper_base(cmd, git_dur)
        Ok(r): r
        Error(berr):
          ms_err = elapsed_ms(clock, t0)
          var ev = Dossier.new_event(ts, tier, "tamper_check", "warn", ms_err)
          ev.detail = Some("tamper base resolution failed: #{berr}")
          return ev
      end
      var chosen = default_ref
      read_compare_toml? = false
      if cmd.run("git", ["show", "#{default_ref}:#{repo_toml}"], git_dur) is Ok(def_toml)
        if def_toml.ok?
          if Config.parse(def_toml.stdout) is Ok(def_cfg)
            effective_globs = merge_tamper_globs(effective_globs, def_cfg.tamper_globs)
            if def_cfg.base_ref is Some(trusted_bref)
              case resolve_ref_to_merge_base(trusted_bref, cmd, git_dur)
                Ok(tr):
                  chosen = tr
                  read_compare_toml? = tr != default_ref
                Error(berr):
                  ms_err = elapsed_ms(clock, t0)
                  var ev = Dossier.new_event(ts, tier, "tamper_check", "warn", ms_err)
                  ev.detail = Some("tamper base resolution failed: #{berr}")
                  return ev
              end
            end
          end
        end
      end
      chosen
  end

  if read_compare_toml?
    if cmd.run("git", ["show", "#{compare_ref}:#{repo_toml}"], git_dur) is Ok(base_toml)
      if base_toml.ok?
        if Config.parse(base_toml.stdout) is Ok(base_cfg)
          effective_globs = merge_tamper_globs(effective_globs, base_cfg.tamper_globs)
        end
      end
    end
  end

  var all_repo_changed = []
  var st_ok? = false
  if cmd.run("git", ["status", "--porcelain", "--untracked-files=all"], git_dur) is Ok(st_out)
    if st_out.ok?
      st_ok? = true
      for p in Tamper.parse_git_status_paths(st_out.stdout)
        all_repo_changed = all_repo_changed.append(p)
      end
    end
  end
  var df_ok? = false
  if cmd.run("git", ["diff", "--no-renames", "--name-only", compare_ref], git_dur) is Ok(df_out)
    if df_out.ok?
      df_ok? = true
      for ln in df_out.stdout.lines
        trimmed = ln.trim
        continue if trimmed.empty?
        all_repo_changed = all_repo_changed.append(trimmed)
      end
    end
  end

  if st_ok? and df_ok?
    unique_repo = all_repo_changed.unique
    var app_changed = []
    var repo_mo_checked = []
    var tampered = []

    for rp in unique_repo
      if strip_repo_prefix(rp, effective_prefix) is Some(rel_p)
        app_changed = app_changed.append(rel_p)
      end
      # Check every .mo file under the current working prefix for modified or removed promise blocks
      if strip_repo_prefix(rp, git_prefix) is Some(repo_rel)
        if repo_rel.ends_with?(".mo") and not repo_mo_checked.contains?(repo_rel)
          repo_mo_checked = repo_mo_checked.append(repo_rel)
          old_res = cmd.run("git", ["show", "#{compare_ref}:#{rp}"], git_dur)
          if old_res is Ok(old_out)
            if old_out.ok?
              cur_res = case strip_repo_prefix(rp, effective_prefix)
                Some(in_app): files.read_text(in_app)
                None: root_files.read_text(repo_rel)
              end
              case cur_res
                Ok(cur_src):
                  if Tamper.promise_blocks_changed?(old_out.stdout, cur_src)
                    tampered = tampered.append("#{repo_rel} (promise)")
                  end
                Error(_):
                  if not Tamper.extract_promise_blocks(old_out.stdout).empty?
                    tampered = tampered.append("#{repo_rel} (promise removed)")
                  end
              end
            end
          end
        end
      end
    end

    for tp in Tamper.detect_tampered_paths(app_changed, effective_globs)
      tampered = tampered.append(tp)
    end

    final_tampered = tampered.unique.sort
    ms = elapsed_ms(clock, t0)
    if final_tampered.empty?
      var ev = Dossier.new_event(ts, tier, "tamper_check", "pass", ms)
      ev.detail = Some("0 contract edits (base=#{Text.from_chars(compare_ref.chars.take(12))})")
      return ev
    else
      var ev = Dossier.new_event(ts, tier, "tamper_check", "warn", ms)
      ev.modified_contracts = Some(final_tampered)
      ev.detail = Some("modified: #{final_tampered.join(", ")}")
      return ev
    end
  end

  var fp_inputs = collect_tamper_files(files.read_only, ".", effective_globs)
  for (rk, rv) in collect_tamper_files(root_files, ".", [])
    if not fp_inputs.has?(rk)
      fp_inputs = fp_inputs.set(rk, rv)
    end
  end
  current_fp = Tamper.fingerprint_map(fp_inputs, effective_globs)
  baseline_path = ".arvo/dossier/tamper-baseline.json"
  if files.read_text(baseline_path) is Ok(raw)
    if Json.decode_strict[Map(Text, Text)](raw) is Ok(base_fp)
      changed = Tamper.diff_fingerprints(base_fp, current_fp)
      ms = elapsed_ms(clock, t0)
      if changed.empty?
        var ev = Dossier.new_event(ts, tier, "tamper_check", "pass", ms)
        ev.detail = Some("0 contract edits (baseline; git unavailable)")
        return ev
      else
        var ev = Dossier.new_event(ts, tier, "tamper_check", "warn", ms)
        ev.modified_contracts = Some(changed)
        ev.detail = Some("modified (baseline): #{changed.join(", ")}")
        return ev
      end
    end
  end

  _mk = files.make_folder(".arvo/dossier")
  _wr = files.write_text(baseline_path, Json.encode(current_fp))
  ms_init = elapsed_ms(clock, t0)
  var init_ev = Dossier.new_event(ts, tier, "tamper_check", "warn", ms_init)
  init_ev.detail = Some("git unavailable; recorded baseline (#{baseline_path})")
  init_ev
end

fn run_verify_cmd(
  app_dir: Text,
  tier: Text,
  json_mode?: Bool,
  _changed?: Bool,
  base_opt: Option(Text),
  root_files: ReadFiles,
  files: Files,
  cmd: Command,
  clock: Clock,
  env: Env,
  console: Console
) : Int
  start_all = clock.now
  timeouts = default_timeouts()
  cfg = case Config.load(files.read_only)
    Ok(c): c
    Error(e):
      console.error("arvo verify: #{e}")
      return 1
  end
  entry_path = join_app_path(app_dir, cfg.entry)

  var events = []

  # 1. mo check
  t_chk = clock.now
  chk_res = cmd.run("mo", ["check", entry_path], timeouts.mo_secs.seconds)
  chk_ev = case chk_res
    Ok(out):
      if out.ok?
        var e = Dossier.new_event(t_chk.to_text, tier, "mo_check", "pass", elapsed_ms(clock, t_chk))
        e.detail = Some(cfg.entry)
        e
      else
        var e = Dossier.new_event(t_chk.to_text, tier, "mo_check", "fail", elapsed_ms(clock, t_chk))
        e.detail = Some(out.stderr.trim)
        e
      end
    Error(err):
      var e = Dossier.new_event(t_chk.to_text, tier, "mo_check", "fail", elapsed_ms(clock, t_chk))
      e.detail = Some("#{err}")
      e
  end
  events = events.append(chk_ev)

  # 2. mo test --json
  t_tst = clock.now
  tst_res = cmd.run("mo", ["test", "--json", entry_path], timeouts.tsc_secs.seconds)
  tst_ev = case tst_res
    Ok(out):
      sum = Dossier.parse_mo_test_json(out.stdout)
      ok? = out.ok? and sum.failed == 0 and sum.stopped == 0 and sum.errors == 0
      var e = Dossier.new_event(
        t_tst.to_text,
        tier,
        "mo_test",
        if ok?: "pass" else: "fail",
        elapsed_ms(clock, t_tst)
      )
      e.passed = Some(sum.passed)
      e.failed = Some(sum.failed + sum.stopped)
      e.detail = Some("#{sum.passed} passed, #{sum.failed + sum.stopped} failed")
      e
    Error(err):
      var e = Dossier.new_event(t_tst.to_text, tier, "mo_test", "fail", elapsed_ms(clock, t_tst))
      e.detail = Some("#{err}")
      e
  end
  events = events.append(tst_ev)

  # 3. Feature Map validation
  t_feat = clock.now
  var parsed_docs = []
  feat_ev = if files.exists?(cfg.features_dir)
    case load_and_parse_features(files.read_only, cfg, cfg.features_dir)
      Ok(docs):
        parsed_docs = docs
        var e = Dossier.new_event(
          t_feat.to_text,
          tier,
          "feature_validate",
          "pass",
          elapsed_ms(clock, t_feat)
        )
        e.passed = Some(docs.size)
        e.detail = Some("#{docs.size} feature file(s)")
        e
      Error(ferr):
        var e = Dossier.new_event(
          t_feat.to_text,
          tier,
          "feature_validate",
          "fail",
          elapsed_ms(clock, t_feat)
        )
        e.detail = Some(ferr)
        e
    end
  else
    var e = Dossier.new_event(
      t_feat.to_text,
      tier,
      "feature_validate",
      "skipped",
      elapsed_ms(clock, t_feat)
    )
    e.detail = Some("no #{cfg.features_dir} directory")
    e
  end
  events = events.append(feat_ev)

  # 4. Contracts & tsc --noEmit
  t_ctr = clock.now
  ctr_ev = case run_contracts_flow(app_dir, true, cfg, files, cmd)
    Ok((pages_count, msg)):
      var e = Dossier.new_event(t_ctr.to_text, tier, "contracts", "pass", elapsed_ms(clock, t_ctr))
      e.pages_checked = Some(pages_count)
      e.detail = Some(msg)
      e
    Error(cerr):
      var e = Dossier.new_event(t_ctr.to_text, tier, "contracts", "fail", elapsed_ms(clock, t_ctr))
      e.detail = Some(cerr)
      e
  end
  events = events.append(ctr_ev)

  # 5. Tamper check
  events = events.append(run_tamper_phase(app_dir, tier, base_opt, cfg, root_files, files, cmd, clock))

  # Tier feature/full gates
  if tier == "feature" or tier == "full"
    t_man = clock.now
    if not parsed_docs.empty?
      _mk = files.make_folder(".arvo/dossier")
      _wr = files.write_text(
        ".arvo/dossier/browser-features.json",
        "#{Feature.browser_manifest_json(parsed_docs).pretty}\n"
      )
      var me = Dossier.new_event(
        t_man.to_text,
        tier,
        "feature_manifest",
        "pass",
        elapsed_ms(clock, t_man)
      )
      me.total = Some(Feature.browser_manifest(parsed_docs).size)
      me.detail = Some(".arvo/dossier/browser-features.json")
      events = events.append(me)
    end

    t_mut = clock.now
    mut_ev = case cmd.run(
      "mo",
      ["test", "--jobs", "4", "--json", "--mutants", entry_path],
      timeouts.slow_secs.seconds
    )
      Ok(mout):
        msum = Dossier.parse_mo_test_json(mout.stdout)
        if msum.has_mutants?
          rate_ok? = msum.kill_rate >= cfg.mo_mutant_min_kill_rate and
            msum.failed == 0 and
            msum.stopped == 0 and
            msum.errors == 0
          var e = Dossier.new_event(
            t_mut.to_text,
            tier,
            "mo_mutants",
            if rate_ok?: "pass" else: "fail",
            elapsed_ms(clock, t_mut)
          )
          e.total = Some(msum.mutants_total)
          e.killed = Some(msum.mutants_killed)
          e.survived = Some(msum.mutants_survived)
          e.kill_rate = Some(msum.kill_rate)
          e.detail = Some(
            "#{msum.mutants_killed}/#{msum.mutants_total} killed (rate=#{msum.kill_rate})"
          )
          e
        else if mout.ok? and msum.errors == 0 and msum.failed == 0 and msum.stopped == 0
          var e = Dossier.new_event(
            t_mut.to_text,
            tier,
            "mo_mutants",
            "pass",
            elapsed_ms(clock, t_mut)
          )
          e.total = Some(0)
          e.killed = Some(0)
          e.survived = Some(0)
          e.kill_rate = Some(1.0)
          e.detail = Some("0/0 killed (rate=1)")
          e
        else
          var e = Dossier.new_event(
            t_mut.to_text,
            tier,
            "mo_mutants",
            "fail",
            elapsed_ms(clock, t_mut)
          )
          e.total = Some(0)
          e.killed = Some(0)
          e.survived = Some(0)
          e.kill_rate = Some(0.0)
          e.detail = Some(
            "mutants did not run (errors=#{msum.errors}, failed=#{msum.failed + msum.stopped})"
          )
          e
        end
      Error(merr):
        var e = Dossier.new_event(
          t_mut.to_text,
          tier,
          "mo_mutants",
          "fail",
          elapsed_ms(clock, t_mut)
        )
        e.detail = Some("#{merr}")
        e
    end
    events = events.append(mut_ev)

    events = events.append(
      FrontendCheck.run_vitest_phase(app_dir, tier, cfg, files.read_only, cmd, clock, env)
    )
    events = events.append(
      FrontendCheck.run_browser_e2e_phase(app_dir, tier, cfg, files.read_only, cmd, clock, env)
    )
  end

  if tier == "full"
    var str_ev = Dossier.new_event(clock.now.to_text, tier, "mo_strength", "skipped", 0)
    str_ev.detail = Some("skipped: pending Phase 4+ strength suites")
    events = events.append(str_ev)

    events = events.append(
      FrontendCheck.run_stryker_phase(app_dir, tier, cfg, files.read_only, cmd, clock, env)
    )

    events = events.append(StatechartCmd.run_statechart_phase(tier, files, cmd, clock, env))
  end

  ndjson_lines = events.map(Dossier.event_to_json)
  if files.make_folder(".arvo/dossier") is Ok(_)
    _w = files.write_text(".arvo/dossier/verify.jsonl", "#{ndjson_lines.join("\n")}\n")
  end

  if json_mode?
    for line in ndjson_lines
      console.print(line)
    end
  else
    console.print(Dossier.render_scorecard(tier, events, elapsed_ms(clock, start_all)))
  end

  if events.any?(fn(e) e.status == "fail" end)
    1
  else
    0
  end
end

## Executes the CLI command using explicit capabilities (usable directly from both `main` and tests).
fn run_cli(
  args: Args,
  console: Console,
  files: Files,
  cmd: Command,
  clock: Clock,
  env: Env,
  net: Network
) : Int
  inv = case parse_invocation(args.list)
    Ok(c): c
    Error(msg):
      console.error("arvo: #{msg}")
      return 2
  end
  app_dir = inv.app_dir
  app_files = if app_dir == ".": files else: files.within(app_dir)

  case inv.cmd
    HelpCmd(topic: t):
      console.print(usage(t))
      0
    ContractsCmd(check?: chk):
      cfg = case Config.load(app_files.read_only)
        Ok(c): c
        Error(e):
          console.error("arvo contracts: #{e}")
          return 1
      end
      case run_contracts_flow(app_dir, chk, cfg, app_files, cmd)
        Ok((_n, msg)):
          console.print(msg)
          0
        Error(msg):
          console.error("arvo contracts: #{msg}")
          1
      end
    VerifyCmd(tier: tier, json?: j, changed?: chg, base_ref: bref): run_verify_cmd(
      app_dir,
      tier,
      j,
      chg,
      bref,
      files.read_only,
      app_files,
      cmd,
      clock,
      env,
      console
    )
    FeatureCmd(validate?: _v, manifest_out: mout, dir: d): run_feature_cmd(
      mout,
      d,
      app_files,
      console
    )
    SimCmd(entry: e, only: o): run_sim_cmd(app_dir, e, o, app_files.read_only, cmd, console)
    ControlCmd(sub: sub_cmd):
      cfg = case Config.load(app_files.read_only)
        Ok(c): c
        Error(e):
          console.error("arvo control: #{e}")
          return 1
      end
      Control.run_control_cmd(app_dir, sub_cmd, cfg, app_files, cmd, clock, env, net, console)
    RunStatechartCmd(args: sa): StatechartCmd.run_statechart_cmd(sa, app_files, cmd, env, console)
  end
end

## Entry point installed as `arvo`.
fn main(
  args: Args,
  console: Console,
  files: Files,
  cmd: Command,
  clock: Clock,
  env: Env,
  net: Network
) : Int
  run_cli(args, console, files, cmd, clock, env, net)
end

struct FakeProps
  title: Text
end

struct FakeShared
  viewer: Option(Text)
end

valid_feature_doc = """
# Login

Sign in safely.

## Sub-features

- `login`: signs in.

## How to get to it (user POV)

- Open `/login`.

## Scenarios

```gherkin
Feature: Login
  @smoke @browser
  Scenario: Valid sign in
    Given I visit "/login"
    Then I see "Sign in"
```

## Gotchas

- Never leak passwords.
"""

test "parse_args handles all commands, help flags, and rejects unknown options cleanly"
  assert parse_args([]) == Ok(HelpCmd(topic: None))
  assert parse_args(["--help"]) == Ok(HelpCmd(topic: None))
  assert parse_args(["contracts", "--check"]) == Ok(ContractsCmd(check?: true))
  assert parse_args(["contracts", "--help"]) == Ok(HelpCmd(topic: Some("contracts")))
  assert parse_args(["verify"]) ==
    Ok(VerifyCmd(tier: "fast", json?: false, changed?: false, base_ref: None))
  assert parse_args(["verify", "--help"]) == Ok(HelpCmd(topic: Some("verify")))
  assert parse_args(["verify", "--tier", "feature", "--json", "--changed", "--base", "origin/main"]) ==
    Ok(VerifyCmd(tier: "feature", json?: true, changed?: true, base_ref: Some("origin/main")))
  assert parse_args(["verify", "--base"]) is Error(_)
  assert parse_args(["verify", "--base", "-x"]) is Error(_)
  assert parse_args(["feature"]) == Ok(FeatureCmd(validate?: false, manifest_out: None, dir: None))
  assert parse_args(["feature", "--help"]) == Ok(HelpCmd(topic: Some("feature")))
  assert parse_args(["feature", "--validate", "--manifest", "out.json", "specs/features"]) ==
    Ok(FeatureCmd(validate?: true, manifest_out: Some("out.json"), dir: Some("specs/features")))
  assert parse_args(["sim", "--help"]) == Ok(HelpCmd(topic: Some("sim")))
  assert parse_args(["sim", "--entry", "app.mo", "--only", "Sim.test.1"]) ==
    Ok(SimCmd(entry: Some("app.mo"), only: Some("Sim.test.1")))
  assert parse_args(["sim", "--only", "S", "--entry", "e.mo"]) ==
    Ok(SimCmd(entry: Some("e.mo"), only: Some("S")))
  assert parse_args(["control", "--help"]) == Ok(HelpCmd(topic: Some("control")))
  assert parse_args(["control", "doctor", "--run-id", "r1"]) ==
    Ok(ControlCmd(sub: Control.DoctorCmd(run_id: "r1")))
  assert parse_args(["control", "bogus"]) is Error(_)
  assert usage(Some("control")).contains?("cleanup")
  assert parse_args(["statechart", "--help"]) == Ok(HelpCmd(topic: Some("statechart")))
  assert parse_args(["statechart", "render", "--out", "sc_out"]) ==
    Ok(
      RunStatechartCmd(
        args: StatechartCmd.StatechartArgs(
          subcmd: "render",
          out_dir: Some("sc_out"),
          tla_file: None,
          help?: false
        )
      )
    )
  assert parse_args(["statechart", "--bad"]) is Error(_)
  assert usage(Some("statechart")).contains?("Arvo.Jobs")
  assert usage(None).contains?("statechart")

  assert parse_args(["bogus"]) is Error(_)
  assert parse_args(["verify", "--tier", "bogus"]) is Error(_)
  assert case parse_args(["verify", "--tier", "-x"])
    Error(m): m.contains?("requires a value")
    Ok(_): false
  end
  assert case parse_args(["verify", "--tier"])
    Error(m): m.contains?("requires a value")
    Ok(_): false
  end
  assert parse_args(["verify", "--bad"]) is Error(_)
  assert parse_args(["contracts", "--bad"]) is Error(_)
  assert parse_args(["feature", "--manifest"]) is Error(_)
  assert parse_args(["feature", "--manifest", "-x"]) is Error(_)
  assert parse_args(["feature", "--bad"]) is Error(_)
  assert parse_args(["feature", "a", "b"]) is Error(_)
  assert parse_args(["sim", "--entry"]) is Error(_)
  assert parse_args(["sim", "--only"]) is Error(_)
  assert parse_args(["sim", "--bad"]) is Error(_)
  assert usage(None).contains?("Commands:")
  assert usage(Some("verify")).contains?("--tier")
  assert usage(Some("contracts")).contains?("--check")
  assert usage(Some("feature")).contains?("--manifest")
  assert usage(Some("sim")).contains?("--only")

  dt = default_timeouts()
  assert dt.git_secs == 15 and dt.mo_secs == 30 and dt.tsc_secs == 60 and dt.slow_secs == 600
  assert parent_dir("a.mo") == "."
  assert parent_dir("a/b/c.mo") == "a/b"
  assert join_app_path(".", "main.mo") == "main.mo"
  assert join_app_path("examples/app", "main.mo") == "examples/app/main.mo"

  assert parse_invocation(["contracts", "--app", "./examples/app/"]) ==
    Ok(CliInvocation(app_dir: "examples/app", cmd: ContractsCmd(check?: false)))
  assert parse_invocation(["contracts", "--app", "./"]) ==
    Ok(CliInvocation(app_dir: ".", cmd: ContractsCmd(check?: false)))
  assert parse_invocation(["--app", "examples/app", "contracts", "--check"]) ==
    Ok(CliInvocation(app_dir: "examples/app", cmd: ContractsCmd(check?: true)))
  assert case parse_invocation(["contracts", "--app"])
    Error(m): m.contains?("requires a directory")
    Ok(_): false
  end
  assert case parse_invocation(["contracts", "--app", "-x"])
    Error(m): m.contains?("requires a directory")
    Ok(_): false
  end

  t_ref = Time.parse("2026-11-25T15:00:00Z") or stop "t_ref"
  assert elapsed_ms(Clock.fixed(t_ref - 5.milliseconds), t_ref) == 0
  assert elapsed_ms(Clock.fixed(t_ref), t_ref) == 0
  assert elapsed_ms(Clock.fixed(t_ref + 1.millisecond), t_ref) == 1
  assert elapsed_ms(Clock.fixed(t_ref + 15.milliseconds), t_ref) == 15
end

test "run_cli executes contracts write/check, feature manifest, sim, and verify with tamper detection"
  contracts_json = Json.encode([
    Inertia.page_contract[FakeProps, FakeShared]("Home", ["/"], Inertia.Of, Inertia.Of)
  ])
  test_json = "{\"record\":\"totals\",\"passed\":4,\"failed\":0,\"stopped\":0,\"errors\":0,\"status\":0}\n"
  mut_json = "{\"record\":\"mutant_summary\",\"event\":\"mutant_summary\",\"total\":5,\"tried\":5,\"killed\":5,\"survived\":0,\"kill_rate\":1.0}\n{\"record\":\"totals\",\"passed\":4,\"failed\":0,\"stopped\":0,\"errors\":0,\"status\":0}\n"
  t0 = Time.parse("2026-11-25T15:00:00Z") or stop "t0"

  files = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": "module Main\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n",
    "frontend/tsconfig.json": "{}",
    "frontend/node_modules/typescript/bin/tsc": "//tsc",
    "specs/features/README.md": "# Feature index\n",
    "specs/features/login.feature.md": valid_feature_doc
  })

  replies_ok = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json)),
    (
      Command.spec(
        "node",
        ["--openssl-config=/dev/null", "./node_modules/typescript/bin/tsc", "--noEmit"]
      ).in_folder("frontend"),
      Command.ok_output("")
    ),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (
      Command.spec("mo", ["test", "--jobs", "4", "--json", "--mutants", "main.mo"]),
      Command.ok_output(mut_json)
    ),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (
      Command.spec("mo", ["test", "--json", "--only", "Sim.1", "main.mo"]),
      Command.ok_output(test_json)
    ),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]), Command.ok_output("")),
    (Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]), Command.ok_output("")),
    (
      Command.spec(
        "git",
        [
          "diff",
          "--name-only",
          "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
          "--",
          "lib/arvo/sqlite/jobs.mo"
        ]
      ),
      Command.ok_output("")
    ),
    (
      Command.spec(
        "git",
        [
          "diff",
          "--name-only",
          "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
          "--",
          "lib/arvo/sqlite/sessions.mo",
          "lib/arvo/session.mo"
        ]
      ),
      Command.ok_output("")
    ),
    (
      Command.spec("mo", ["test", "--json", "lib/arvo/testing/statechart.mo"]),
      Command.ok_output("{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":0,\"errors\":0}\n")
    )
  ])

  # 0. Help and invalid arg exit codes
  c_help = Console.fake()
  assert run_cli(
    Args.of(["--help"]),
    c_help,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert c_help.printed.any?(fn(l) l.contains?("Commands:") end)
  assert run_cli(
    Args.of(["badcmd"]),
    c_help,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    2

  # 1. `arvo contracts` generates frontend/src/arvo.gen.ts and `--check` passes (with tsc)
  c_gen = Console.fake()
  assert run_cli(
    Args.of(["contracts"]),
    c_gen,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files.exists?("frontend/src/arvo.gen.ts")
  assert files.read_text("frontend/src/arvo.gen.ts") is Ok(gen_ts)
  assert gen_ts.contains?("export interface HomeProps")

  c_chk = Console.fake()
  assert run_cli(
    Args.of(["contracts", "--check"]),
    c_chk,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0

  # 2. `arvo feature --validate --manifest` validates and exports @browser scenarios
  c_feat = Console.fake()
  assert run_cli(
    Args.of(["feature", "--validate", "--manifest", ".arvo/manifest.json"]),
    c_feat,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files.exists?(".arvo/manifest.json")
  assert files.read_text(".arvo/manifest.json") is Ok(man_txt)
  assert man_txt.contains?("Valid sign in")

  # 3. `arvo sim` runs simulation test cleanly
  c_sim = Console.fake()
  assert run_cli(
    Args.of(["sim", "--only", "Sim.1"]),
    c_sim,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert c_sim.printed.any?(fn(l) l.contains?("Arvo Sim: PASS") end)

  # 4. `arvo verify --tier fast --json` passes and writes verify.jsonl
  c_vf = Console.fake()
  assert run_cli(
    Args.of(["verify", "--tier", "fast", "--json"]),
    c_vf,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files.exists?(".arvo/dossier/verify.jsonl")
  assert files.read_text(".arvo/dossier/verify.jsonl") is Ok(v_jsonl)
  assert v_jsonl.contains?("\"phase\":\"tamper_check\",\"status\":\"pass\"")
  assert c_vf.printed.any?(fn(l) l.contains?("\"phase\":\"contracts\"") end)

  # 5. `arvo verify --tier feature` vs `--tier full`
  c_vfeat = Console.fake()
  assert run_cli(
    Args.of(["verify", "--tier", "feature"]),
    c_vfeat,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files.read_text(".arvo/dossier/verify.jsonl") is Ok(vfeat_jsonl)
  assert vfeat_jsonl.contains?("\"phase\":\"mo_mutants\"")
  assert vfeat_jsonl.contains?("\"phase\":\"feature_manifest\"")
  assert vfeat_jsonl.contains?("\"phase\":\"vitest_fixtures\",\"status\":\"pass\"")
  assert vfeat_jsonl.contains?("\"phase\":\"browser_e2e\",\"status\":\"pass\"")
  assert not vfeat_jsonl.contains?("\"phase\":\"mo_strength\"")

  c_vfull = Console.fake()
  assert run_cli(
    Args.of(["verify", "--tier", "full"]),
    c_vfull,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert c_vfull.printed.any?(fn(l) l.contains?("[PASS] browser_e2e") end)
  assert c_vfull.printed.any?(fn(l) l.contains?("[PASS] mo_mutants") end)
  assert c_vfull.printed.any?(fn(l) l.contains?("[PASS] statechart") end)
  assert files.read_text(".arvo/dossier/verify.jsonl") is Ok(vfull_jsonl)
  assert vfull_jsonl.contains?("\"phase\":\"vitest_fixtures\",\"status\":\"pass\"")
  assert vfull_jsonl.contains?(
    "\"phase\":\"mo_strength\",\"status\":\"skipped\",\"detail\":\"skipped: pending Phase 4+ strength suites\",\"ms\":0"
  )
  assert vfull_jsonl.contains?("\"phase\":\"stryker\",\"status\":\"pass\"")
  assert vfull_jsonl.contains?("\"phase\":\"statechart\",\"status\":\"pass\"")
  assert files.read_text(".arvo/dossier/statecharts/jobs.mmd") is Ok(j_mmd)
  assert j_mmd.contains?("stateDiagram-v2")
  assert files.read_text(".arvo/dossier/statecharts/session.mmd") is Ok(s_mmd)
  assert s_mmd.contains?("stateDiagram-v2")

  c_sc = Console.fake()
  assert run_cli(
    Args.of(["statechart", "check", "--out", "sc_check"]),
    c_sc,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert c_sc.printed.any?(fn(l) l.contains?("\"ok\":true") end)

  c_sc_render = Console.fake()
  assert run_cli(
    Args.of(["statechart", "render", "--out", "sc_render"]),
    c_sc_render,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert c_sc_render.printed.any?(fn(l) l.contains?("stateDiagram-v2") end)

  # App with frontend/package.json fails fail-closed if Vitest/E2E/Stryker evidence is missing
  files_with_pkg = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": "module Main\n",
    "frontend/package.json": "{}",
    "frontend/src/pages/Login.tsx": "export default function Login() { return null; }\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n",
    "frontend/src/arvo.gen.ts": gen_ts
  })
  assert run_cli(
    Args.of(["verify", "--tier", "full"]),
    Console.fake(),
    files_with_pkg,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert files_with_pkg.read_text(".arvo/dossier/verify.jsonl") is Ok(vp_fail_jsonl)
  assert vp_fail_jsonl.contains?("\"phase\":\"vitest_fixtures\",\"status\":\"fail\"")
  assert vp_fail_jsonl.contains?("\"phase\":\"browser_e2e\",\"status\":\"fail\"")
  assert vp_fail_jsonl.contains?("\"phase\":\"stryker\",\"status\":\"fail\"")

  # 6. Tamper detection: committed branch edits, arvo.toml hardening, renames, repo-wide promises, & T5 inline feature drift
  files_tamper = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n[testing.tamper_protected]\nglobs = []\n",
    "main.mo": "module Main\nfn f(x: Int) : Int\n  promise\n    true\n  end\n  x\nend\n",
    "lib/other.mo": "module Other\nfn g(x: Int) : Int\n  promise\n    true\n  end\n  x\nend\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n",
    "frontend/src/arvo.gen.ts": gen_ts,
    "specs/features/login.feature.md": valid_feature_doc
  })
  replies_tamper = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json)),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (Command.spec("git", ["merge-base", "HEAD", "origin/main"]), Command.ok_output("base_111\n")),
    (
      Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]),
      Command.ok_output(
        "R  specs/features/login.feature.md -> specs/login_moved.md\n M lib/other.mo\n?? main.mo\n"
      )
    ),
    (
      Command.spec("git", ["diff", "--no-renames", "--name-only", "base_111"]),
      Command.ok_output("specs/features/login.feature.md\nmain.mo\nlib/deleted_promise.mo\n")
    ),
    (
      Command.spec("git", ["show", "base_111:arvo.toml"]),
      Command.ok_output("[testing.tamper_protected]\nglobs = [\"extra_base/**/*\"]\n")
    ),
    (
      Command.spec("git", ["show", "base_111:main.mo"]),
      Command.ok_output(
        "module Main\nfn f(x: Int) : Int\n  promise\n    result == x\n  end\n  x\nend\n"
      )
    ),
    (
      Command.spec("git", ["show", "base_111:lib/other.mo"]),
      Command.ok_output(
        "module Other\nfn g(x: Int) : Int\n  promise\n    result >= 0\n  end\n  x\nend\n"
      )
    ),
    (
      Command.spec("git", ["show", "base_111:lib/deleted_promise.mo"]),
      Command.ok_output(
        "module Deleted\nfn h(x: Int) : Int\n  promise\n    result == x\n  end\n  x\nend\n"
      )
    )
  ])
  c_tamper = Console.fake()
  assert run_cli(
    Args.of(["verify", "--tier", "fast", "--base", "origin/main"]),
    c_tamper,
    files_tamper,
    Command.fake(replies_tamper),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert c_tamper.printed.any?(fn(l) l.contains?("PASS WITH CONTRACT CHANGES") end)
  assert files_tamper.read_text(".arvo/dossier/verify.jsonl") is Ok(vt_jsonl)
  assert vt_jsonl.contains?("specs/features/login.feature.md")
  assert vt_jsonl.contains?("main.mo (promise)")
  assert vt_jsonl.contains?("lib/other.mo (promise)")
  assert vt_jsonl.contains?("lib/deleted_promise.mo (promise removed)")

  gen_empty_r2 = Codegen.generate_ts([], None)
  # Security R2-1: working-tree arvo.toml setting base_ref="HEAD" must NOT hide edits from origin/main
  files_sneaky = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n[testing]\nbase_ref = \"HEAD\"\n",
    "main.mo": "module Main\nfn f(x: Int) : Int\n  promise\n    true\n  end\n  x\nend\n",
    "frontend/src/arvo.gen.ts": gen_empty_r2
  })
  replies_sneaky = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output("[]")),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (Command.spec("git", ["rev-parse", "--verify", "origin/main"]), Command.ok_output("origin/main\n")),
    (Command.spec("git", ["merge-base", "HEAD", "origin/main"]), Command.ok_output("trusted_base\n")),
    (Command.spec("git", ["show", "trusted_base:arvo.toml"]), Command.ok_output("[app]\nentry = \"main.mo\"\n")),
    (Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]), Command.ok_output("")),
    (Command.spec("git", ["diff", "--no-renames", "--name-only", "trusted_base"]), Command.ok_output("arvo.toml\nmain.mo\n")),
    (
      Command.spec("git", ["show", "trusted_base:main.mo"]),
      Command.ok_output("module Main\nfn f(x: Int) : Int\n  promise\n    result == x\n  end\n  x\nend\n")
    )
  ])
  c_sneaky = Console.fake()
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    c_sneaky,
    files_sneaky,
    Command.fake(replies_sneaky),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert c_sneaky.printed.any?(fn(l) l.contains?("PASS WITH CONTRACT CHANGES") end)
  assert files_sneaky.read_text(".arvo/dossier/verify.jsonl") is Ok(sneaky_jsonl)
  assert sneaky_jsonl.contains?("\"phase\":\"tamper_check\",\"status\":\"warn\"")
  assert sneaky_jsonl.contains?("arvo.toml")
  assert sneaky_jsonl.contains?("main.mo (promise)")

  # Trusted base_ref read from <default_ref>:arvo.toml is honored cleanly
  files_trusted_cfg = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": "module Main\n",
    "frontend/src/arvo.gen.ts": gen_empty_r2
  })
  replies_trusted_cfg = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output("[]")),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (Command.spec("git", ["rev-parse", "--verify", "origin/main"]), Command.ok_output("origin/main\n")),
    (Command.spec("git", ["merge-base", "HEAD", "origin/main"]), Command.ok_output("def_sha\n")),
    (
      Command.spec("git", ["show", "def_sha:arvo.toml"]),
      Command.ok_output("[app]\nentry = \"main.mo\"\n[testing]\nbase_ref = \"release/v1\"\n")
    ),
    (Command.spec("git", ["merge-base", "HEAD", "release/v1"]), Command.ok_output("rel_sha\n")),
    (Command.spec("git", ["show", "rel_sha:arvo.toml"]), Command.ok_output("[app]\nentry = \"main.mo\"\n")),
    (Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]), Command.ok_output("")),
    (Command.spec("git", ["diff", "--no-renames", "--name-only", "rel_sha"]), Command.ok_output(""))
  ])
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_trusted_cfg,
    Command.fake(replies_trusted_cfg),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_trusted_cfg.read_text(".arvo/dossier/verify.jsonl") is Ok(trusted_jsonl)
  assert trusted_jsonl.contains?("0 contract edits (base=rel_sha)")

  # Finding R2-4: subfolder cwd (git_prefix != "") must not flag sibling .mo outside cwd as promise removed
  files_sub = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": "module Main\n",
    "frontend/src/arvo.gen.ts": gen_empty_r2
  })
  replies_sub = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output("[]")),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("apps/web/\n")),
    (Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]), Command.ok_output(" M lib/outside.mo\n")),
    (Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]), Command.ok_output("lib/outside.mo\n")),
    (
      Command.spec("git", ["show", "HEAD:lib/outside.mo"]),
      Command.ok_output("module Outside\nfn k() : Int\n  promise\n    true\n  end\n  1\nend\n")
    )
  ])
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_sub,
    Command.fake(replies_sub),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_sub.read_text(".arvo/dossier/verify.jsonl") is Ok(sub_jsonl)
  assert sub_jsonl.contains?("\"phase\":\"tamper_check\",\"status\":\"pass\"")
  assert not sub_jsonl.contains?("outside.mo")

  # T5: inline *_feature_spec drift in main.mo fails `feature --validate` and `verify`
  drifted_main = "module Main\nlogin_feature_spec = \"\"\"\n#{valid_feature_doc}\n- drifted gotcha\n\"\"\"\n"
  files_drift = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": drifted_main,
    "specs/features/login.feature.md": valid_feature_doc
  })
  c_drift = Console.fake()
  assert run_cli(
    Args.of(["feature", "--validate"]),
    c_drift,
    files_drift,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert c_drift.printed_errors.any?(fn(e) e.contains?("drifted from specs/features/login.feature.md") end)

  # 7. Contract error paths: fallback probe, tsc fail, missing file, drift, missing page, nested out dir & root out file
  assert files_tamper.write_text("frontend/src/arvo.gen.ts", "// stale") == Ok(Unit)
  c_stale = Console.fake()
  assert run_cli(
    Args.of(["contracts", "--check"]),
    c_stale,
    files_tamper,
    Command.fake(replies_tamper),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert c_stale.printed_errors.any?(fn(e) e.contains?("contract drift detected") end)

  # Missing arvo.gen.ts -> exit 1
  files_no_gen = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\ncontracts_out = \"gen_out/arvo.gen.ts\"\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n"
  })
  assert run_cli(
    Args.of(["contracts", "--check"]),
    Console.fake(),
    files_no_gen,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  # Create new parent dir gen_out/ when missing + generate at root pdir="."
  assert run_cli(
    Args.of(["contracts"]),
    Console.fake(),
    files_no_gen,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_no_gen.exists?("gen_out/arvo.gen.ts")
  files_root_out = Files.in_memory({
    "arvo.toml": "[app]\ncontracts_out = \"arvo.gen.ts\"\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n"
  })
  assert run_cli(
    Args.of(["contracts"]),
    Console.fake(),
    files_root_out,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_root_out.exists?("arvo.gen.ts")

  # Fallback probe succeeds and fails
  replies_probe_ok = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.output(1, "", "no flag")),
    (Command.spec("mo", ["run", "arvo-contracts-probe.mo"]), Command.ok_output(contracts_json))
  ])
  assert run_cli(
    Args.of(["contracts"]),
    Console.fake(),
    files_root_out,
    Command.fake(replies_probe_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert not files_root_out.exists?("arvo-contracts-probe.mo")

  replies_probe_bad = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.output(1, "", "err")),
    (Command.spec("mo", ["run", "arvo-contracts-probe.mo"]), Command.output(1, "", "probe bad"))
  ])
  c_pbad = Console.fake()
  assert run_cli(
    Args.of(["contracts"]),
    c_pbad,
    files_root_out,
    Command.fake(replies_probe_bad),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert c_pbad.printed_errors.any?(fn(e) e.contains?("probe bad") end)

  # tsc --noEmit failure propagates stdout+stderr
  replies_tsc_bad = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json)),
    (
      Command.spec(
        "node",
        ["--openssl-config=/dev/null", "./node_modules/typescript/bin/tsc", "--noEmit"]
      ).in_folder("frontend"),
      Command.output(2, "ts out err", "ts stderr err")
    )
  ])
  c_tsc_bad = Console.fake()
  assert run_cli(
    Args.of(["contracts", "--check"]),
    c_tsc_bad,
    files,
    Command.fake(replies_tsc_bad),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert c_tsc_bad.printed_errors.any?(fn(e)
    e.contains?("ts out err") and e.contains?("ts stderr err")
  end)

  # 8. Missing page component + bad config / feature / sim / verify failure exit codes
  files_missing_page = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": "module Main\n"
  })
  c_miss = Console.fake()
  assert run_cli(
    Args.of(["contracts", "--check"]),
    c_miss,
    files_missing_page,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert c_miss.printed_errors.any?(fn(e) e.contains?("missing frontend page component") end)

  files_bad_cfg = Files.in_memory({"arvo.toml": "[app]\nbad"})
  assert run_cli(
    Args.of(["contracts"]),
    Console.fake(),
    files_bad_cfg,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert run_cli(
    Args.of(["feature", "--validate"]),
    Console.fake(),
    files_bad_cfg,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert run_cli(
    Args.of(["sim"]),
    Console.fake(),
    files_bad_cfg,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert run_cli(
    Args.of(["verify"]),
    Console.fake(),
    files_bad_cfg,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1

  # Feature error exits (missing dir, invalid doc, bad manifest folder/file)
  assert run_cli(
    Args.of(["feature", "missing_dir"]),
    Console.fake(),
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  files_bad_feat = Files.in_memory({
    "arvo.toml": "[app]\n",
    "specs/features/bad.feature.md": "# Only title\n",
    "blocker": "regular_file"
  })
  assert run_cli(
    Args.of(["feature", "--validate"]),
    Console.fake(),
    files_bad_feat,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  files_bad_manifest = Files.in_memory({
    "arvo.toml": "[app]\n",
    "specs/features/ok.feature.md": valid_feature_doc,
    "blocker": "regular_file",
    "dir_blocker/inside": "ok"
  })
  assert run_cli(
    Args.of(["feature", "--manifest", "blocker/m.json"]),
    Console.fake(),
    files_bad_manifest,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert run_cli(
    Args.of(["feature", "--manifest", "dir_blocker"]),
    Console.fake(),
    files_bad_manifest,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1

  # Sim error exits + Verify failure exit (test fail, mutant fail, missing features dir, command error)
  fail_test_json = "{\"record\":\"totals\",\"passed\":1,\"failed\":1,\"stopped\":1,\"errors\":0,\"status\":1}\n"
  low_mut_json = "{\"record\":\"mutant_summary\",\"event\":\"mutant_summary\",\"total\":2,\"tried\":2,\"killed\":1,\"survived\":1,\"kill_rate\":0.5}\n{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":0,\"errors\":0,\"status\":0}\n"
  replies_fail_verify = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json)),
    (Command.spec("mo", ["check", "main.mo"]), Command.output(1, "", "check err")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(fail_test_json)),
    (
      Command.spec("mo", ["test", "--jobs", "4", "--json", "--mutants", "main.mo"]),
      Command.ok_output(low_mut_json)
    ),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]), Command.ok_output("")),
    (Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]), Command.ok_output("")),
    (
      Command.spec(
        "git",
        [
          "diff",
          "--name-only",
          "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
          "--",
          "lib/arvo/sqlite/jobs.mo"
        ]
      ),
      Command.ok_output("")
    ),
    (
      Command.spec(
        "git",
        [
          "diff",
          "--name-only",
          "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
          "--",
          "lib/arvo/sqlite/sessions.mo",
          "lib/arvo/session.mo"
        ]
      ),
      Command.ok_output("")
    ),
    (
      Command.spec("mo", ["test", "--json", "lib/arvo/testing/statechart.mo"]),
      Command.ok_output("{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":0,\"errors\":0}\n")
    )
  ])
  assert run_cli(
    Args.of(["sim"]),
    Console.fake(),
    files_missing_page,
    Command.fake(replies_fail_verify),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert run_cli(
    Args.of(["sim"]),
    Console.fake(),
    files_missing_page,
    Command.fake(replies_ok).allow_programs([]),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert run_cli(
    Args.of(["verify", "--tier", "full"]),
    Console.fake(),
    files_missing_page,
    Command.fake(replies_fail_verify),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert files_missing_page.read_text(".arvo/dossier/verify.jsonl") is Ok(vf_bad)
  assert vf_bad.contains?("\"phase\":\"feature_validate\",\"status\":\"skipped\"")
  assert vf_bad.contains?("\"failed\":2")
  assert vf_bad.contains?("1 passed, 2 failed")
  assert vf_bad.contains?("\"phase\":\"mo_mutants\",\"status\":\"fail\"")

  # Verify contracts check mode in run_verify_cmd does not write missing arvo.gen.ts
  files_verify_no_gen = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\ncontracts_out = \"gen_out/arvo.gen.ts\"\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n"
  })
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_verify_no_gen,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
  assert not files_verify_no_gen.exists?("gen_out/arvo.gen.ts")

  # try_tsc_check skips node when only tsconfig OR only tsc binary is present
  files_only_tsconfig = Files.in_memory({
    "arvo.toml": "[app]\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n",
    "frontend/src/arvo.gen.ts": gen_ts,
    "frontend/tsconfig.json": "{}"
  })
  replies_no_tsc = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json))
  ])
  assert run_cli(
    Args.of(["contracts", "--check"]),
    Console.fake(),
    files_only_tsconfig,
    Command.fake(replies_no_tsc),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  files_only_tsc = Files.in_memory({
    "arvo.toml": "[app]\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n",
    "frontend/src/arvo.gen.ts": gen_ts,
    "frontend/node_modules/typescript/bin/tsc": "//tsc"
  })
  assert run_cli(
    Args.of(["contracts", "--check"]),
    Console.fake(),
    files_only_tsc,
    Command.fake(replies_no_tsc),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0

  # extract_contracts_json runs fallback probe even when failing first command outputs `[`
  replies_probe_bracket = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.output(1, "[bad", "err")),
    (Command.spec("mo", ["run", "arvo-contracts-probe.mo"]), Command.ok_output(contracts_json))
  ])
  assert run_cli(
    Args.of(["contracts"]),
    Console.fake(),
    files_only_tsconfig,
    Command.fake(replies_probe_bracket),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0

  # sim & verify reject single-flag failures (`errors=1`, `stopped=1`, `failed=1`, exit=1)
  err_only_json = "{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":0,\"errors\":1,\"status\":0}\n"
  stop_only_json = "{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":1,\"errors\":0,\"status\":0}\n"
  fail_only_json = "{\"record\":\"totals\",\"passed\":1,\"failed\":1,\"stopped\":0,\"errors\":0,\"status\":0}\n"
  for bad_json in [err_only_json, stop_only_json, fail_only_json]
    rep_one = Command.replies([
      (
        Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]),
        Command.ok_output(contracts_json)
      ),
      (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
      (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(bad_json)),
      (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
      (
        Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]),
        Command.ok_output("")
      ),
      (Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]), Command.ok_output(""))
    ])
    assert run_cli(
      Args.of(["sim"]),
      Console.fake(),
      files_only_tsconfig,
      Command.fake(rep_one),
      Clock.fixed(t0),
      Env.of({}),
      Network.fake({})
    ) ==
      1
    assert run_cli(
      Args.of(["verify", "--tier", "fast"]),
      Console.fake(),
      files_only_tsconfig,
      Command.fake(rep_one),
      Clock.fixed(t0),
      Env.of({}),
      Network.fake({})
    ) ==
      1
  end

  rep_nonzero_okjson = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json)),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.output(1, test_json, "nonzero")),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]), Command.ok_output("")),
    (Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]), Command.ok_output("")),
    (
      Command.spec(
        "git",
        [
          "diff",
          "--name-only",
          "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
          "--",
          "lib/arvo/sqlite/jobs.mo"
        ]
      ),
      Command.ok_output("")
    ),
    (
      Command.spec(
        "git",
        [
          "diff",
          "--name-only",
          "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
          "--",
          "lib/arvo/sqlite/sessions.mo",
          "lib/arvo/session.mo"
        ]
      ),
      Command.ok_output("")
    ),
    (
      Command.spec("mo", ["test", "--json", "lib/arvo/testing/statechart.mo"]),
      Command.ok_output("{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":0,\"errors\":0}\n")
    )
  ])
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_only_tsconfig,
    Command.fake(rep_nonzero_okjson),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1

  # Tamper check ignores blank lines from `git diff` even with `"**"` glob
  files_star_glob = Files.in_memory({
    "arvo.toml": "[app]\n[testing.tamper_protected]\nglobs = [\"**\"]\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n",
    "frontend/src/arvo.gen.ts": gen_ts
  })
  rep_blank_diff = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json)),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]), Command.ok_output("")),
    (Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]), Command.ok_output("\n\n"))
  ])
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_star_glob,
    Command.fake(rep_blank_diff),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_star_glob.read_text(".arvo/dossier/verify.jsonl") is Ok(v_star)
  assert v_star.contains?("\"phase\":\"tamper_check\",\"status\":\"pass\"")

  # `--app DIR` targets a monorepo subdirectory cleanly across contracts, tsc, feature, sim, and verify
  files_mono = Files.in_memory({
    "examples/app/arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "examples/app/main.mo": "module Main\nfn f(x: Int) : Int\n  promise\n    true\n  end\n  x\nend\n",
    "examples/app/frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n",
    "examples/app/frontend/tsconfig.json": "{}",
    "examples/app/frontend/node_modules/typescript/bin/tsc": "//tsc",
    "examples/app/specs/features/login.feature.md": valid_feature_doc
  })
  replies_mono = Command.replies([
    (
      Command.spec("mo", ["run", "examples/app/main.mo", "--arvo-contracts"]),
      Command.output(1, "", "use probe")
    ),
    (
      Command.spec("mo", ["run", "examples/app/arvo-contracts-probe.mo"]),
      Command.ok_output(contracts_json)
    ),
    (
      Command.spec(
        "node",
        ["--openssl-config=/dev/null", "./node_modules/typescript/bin/tsc", "--noEmit"]
      ).in_folder("examples/app/frontend"),
      Command.ok_output("")
    ),
    (Command.spec("mo", ["check", "examples/app/main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "examples/app/main.mo"]), Command.ok_output(test_json)),
    (
      Command.spec("mo", ["test", "--jobs", "4", "--json", "--mutants", "examples/app/main.mo"]),
      Command.ok_output(mut_json)
    ),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (
      Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]),
      Command.ok_output(" M examples/app/main.mo\n M lib/other.mo\n")
    ),
    (
      Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]),
      Command.ok_output("examples/app/specs/features/login.feature.md\nlib/other.mo\n\n")
    ),
    (
      Command.spec("git", ["show", "HEAD:examples/app/main.mo"]),
      Command.ok_output(
        "module Main\nfn f(x: Int) : Int\n  promise\n    result == x\n  end\n  x\nend\n"
      )
    ),
    (
      Command.spec(
        "git",
        [
          "diff",
          "--name-only",
          "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
          "--",
          "lib/arvo/sqlite/jobs.mo"
        ]
      ),
      Command.ok_output("")
    ),
    (
      Command.spec(
        "git",
        [
          "diff",
          "--name-only",
          "dbaaf0311d379d828af75ab08b6fa2b61ce9e839",
          "--",
          "lib/arvo/sqlite/sessions.mo",
          "lib/arvo/session.mo"
        ]
      ),
      Command.ok_output("")
    ),
    (
      Command.spec("mo", ["test", "--json", "lib/arvo/testing/statechart.mo"]),
      Command.ok_output("{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":0,\"errors\":0}\n")
    )
  ])
  assert run_cli(
    Args.of(["contracts", "--app", "examples/app"]),
    Console.fake(),
    files_mono,
    Command.fake(replies_mono),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_mono.exists?("examples/app/frontend/src/arvo.gen.ts")
  assert not files_mono.exists?("examples/app/arvo-contracts-probe.mo")
  assert run_cli(
    Args.of(["contracts", "--app", "examples/app", "--check"]),
    Console.fake(),
    files_mono,
    Command.fake(replies_mono),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert run_cli(
    Args.of(["feature", "--app", "examples/app", "--validate"]),
    Console.fake(),
    files_mono,
    Command.fake(replies_mono),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert run_cli(
    Args.of(["sim", "--app", "examples/app"]),
    Console.fake(),
    files_mono,
    Command.fake(replies_mono),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  c_mono_v = Console.fake()
  assert run_cli(
    Args.of(["verify", "--app", "examples/app", "--tier", "full"]),
    c_mono_v,
    files_mono,
    Command.fake(replies_mono),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_mono.exists?("examples/app/.arvo/dossier/browser-features.json")
  assert files_mono.read_text("examples/app/.arvo/dossier/verify.jsonl") is Ok(mono_jsonl)
  assert mono_jsonl.contains?("main.mo (promise)")
  assert mono_jsonl.contains?("specs/features/login.feature.md")
  assert not mono_jsonl.contains?("lib/other.mo")

  # Command.NotPermitted inside verify exercises Error(err) branches on mo commands
  assert run_cli(
    Args.of(["verify", "--tier", "full"]),
    Console.fake(),
    files_missing_page,
    Command.fake(replies_ok).allow_programs([]),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1

  # Worktree/Landlock tamper baseline fallback (git inaccessible) + mo_mutants null/error handling
  gen_wt_ts = Codegen.generate_ts(
    [Inertia.page_contract[FakeProps, FakeShared]("Home", ["/"], Inertia.Of, Inertia.Of)],
    None
  )
  gen_empty_ts = Codegen.generate_ts([], None)
  files_worktree = Files.in_memory({
    "arvo.toml": "[app]\nentry = \"main.mo\"\n",
    "main.mo": "module Main\nfn safe(x: Int) : Int\n  promise \"same\"\n    result == x\n  end\n  x\nend\n",
    "frontend/src/pages/Home.tsx": "export default function Home() { return null; }\n",
    "frontend/src/arvo.gen.ts": gen_wt_ts,
    "node_modules/ignored.mo": "module Ignored\nfn bad(x: Int) : Int\n  promise \"never_seen\"\n    result == x\n  end\n  x\nend\n",
    "specs/features/login.feature.md": valid_feature_doc
  })
  git_fail_replies = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json)),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (
      Command.spec("git", ["rev-parse", "--show-prefix"]),
      Command.output(128, "", "fatal: not a git repo")
    ),
    (
      Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]),
      Command.output(128, "", "fatal: not a git repo")
    ),
    (
      Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]),
      Command.output(128, "", "fatal: not a git repo")
    )
  ])
  # 1st run records baseline and warns
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_worktree,
    Command.fake(git_fail_replies),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_worktree.read_text(".arvo/dossier/verify.jsonl") is Ok(wt_init_j)
  assert wt_init_j.contains?("\"phase\":\"tamper_check\",\"status\":\"warn\"")
  assert wt_init_j.contains?("recorded baseline")
  assert files_worktree.read_text(".arvo/dossier/tamper-baseline.json") is Ok(wt_base_json)
  assert not wt_base_json.contains?("ignored.mo")

  # Partial git failure (status OK, diff HEAD fails) still uses baseline and passes cleanly
  partial_git_fail_replies = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json)),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]), Command.ok_output("")),
    (
      Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]),
      Command.output(128, "", "fatal: bad HEAD")
    )
  ])
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_worktree,
    Command.fake(partial_git_fail_replies),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_worktree.read_text(".arvo/dossier/verify.jsonl") is Ok(wt_clean_j)
  assert wt_clean_j.contains?("\"phase\":\"tamper_check\",\"status\":\"pass\"")
  assert wt_clean_j.contains?("0 contract edits (baseline; git unavailable)")

  # Partial git failure (status fails, diff HEAD OK) also uses baseline (never treats st_ok? as true)
  status_fail_diff_ok_replies = Command.replies([
    (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output(contracts_json)),
    (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
    (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
    (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
    (
      Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]),
      Command.output(128, "", "fatal: status failed")
    ),
    (Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]), Command.ok_output(""))
  ])
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_worktree,
    Command.fake(status_fail_diff_ok_replies),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_worktree.read_text(".arvo/dossier/verify.jsonl") is Ok(wt_stfail_j)
  assert wt_stfail_j.contains?("0 contract edits (baseline; git unavailable)")

  # Edit spec + promise block -> warn naming both without overwriting baseline
  assert files_worktree.write_text(
    "specs/features/login.feature.md",
    "#{valid_feature_doc}\n- Gotcha edit.\n"
  ) ==
    Ok(Unit)
  assert files_worktree.write_text(
    "main.mo",
    "module Main\nfn safe(x: Int) : Int\n  promise \"weakened\"\n    true\n  end\n  x\nend\n"
  ) ==
    Ok(Unit)
  c_wt_warn = Console.fake()
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    c_wt_warn,
    files_worktree,
    Command.fake(git_fail_replies),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert c_wt_warn.printed.any?(fn(l) l.contains?("PASS WITH CONTRACT CHANGES") end)
  assert files_worktree.read_text(".arvo/dossier/verify.jsonl") is Ok(wt_warn_j)
  assert wt_warn_j.contains?("\"phase\":\"tamper_check\",\"status\":\"warn\"")
  assert wt_warn_j.contains?("main.mo (promise)")
  assert wt_warn_j.contains?("specs/features/login.feature.md")

  # Re-verify still warns while edits persist, and passes once reverted
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_worktree,
    Command.fake(git_fail_replies),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_worktree.read_text(".arvo/dossier/verify.jsonl") is Ok(wt_warn2_j)
  assert wt_warn2_j.contains?("\"phase\":\"tamper_check\",\"status\":\"warn\"")

  assert files_worktree.write_text("specs/features/login.feature.md", valid_feature_doc) == Ok(Unit)
  assert files_worktree.write_text(
    "main.mo",
    "module Main\nfn safe(x: Int) : Int\n  promise \"same\"\n    result == x\n  end\n  x\nend\n"
  ) ==
    Ok(Unit)
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_worktree,
    Command.fake(git_fail_replies),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_worktree.read_text(".arvo/dossier/verify.jsonl") is Ok(wt_rev_j)
  assert wt_rev_j.contains?("\"phase\":\"tamper_check\",\"status\":\"pass\"")

  # Corrupt baseline JSON re-records cleanly with warn
  assert files_worktree.write_text(".arvo/dossier/tamper-baseline.json", "not-json") == Ok(Unit)
  assert run_cli(
    Args.of(["verify", "--tier", "fast"]),
    Console.fake(),
    files_worktree,
    Command.fake(git_fail_replies),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert files_worktree.read_text(".arvo/dossier/verify.jsonl") is Ok(wt_corrupt_j)
  assert wt_corrupt_j.contains?("recorded baseline")

  # Check missing entry .arvo/dossier/tamper-baseline.json inside empty dir with app_dir "." missing specs
  # Clean 0-mutant pass vs null-mutant failures (errors, nonzero exit, failed+stopped) & has_mutants+errors fail
  null_clean = "{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":0,\"errors\":0,\"mutants\":null,\"status\":0}\n"
  null_err = "{\"record\":\"totals\",\"passed\":4,\"failed\":0,\"stopped\":0,\"errors\":3,\"mutants\":null,\"status\":1}\n"
  null_fail_stop = "{\"record\":\"totals\",\"passed\":1,\"failed\":1,\"stopped\":1,\"errors\":0,\"mutants\":null,\"status\":1}\n"
  mut_err_json = "{\"record\":\"mutant_summary\",\"event\":\"mutant_summary\",\"total\":5,\"tried\":5,\"killed\":5,\"survived\":0,\"kill_rate\":1.0}\n{\"record\":\"totals\",\"passed\":4,\"failed\":0,\"stopped\":0,\"errors\":1,\"status\":1}\n"

  for (mut_reply, expect_code, expect_frag) in [
    (
      Command.ok_output(null_clean),
      0,
      "\"status\":\"pass\",\"total\":0,\"killed\":0,\"survived\":0,\"kill_rate\":1,\"detail\":\"0/0 killed (rate=1)\""
    ),
    (
      Command.ok_output(null_err),
      1,
      "\"status\":\"fail\",\"total\":0,\"killed\":0,\"survived\":0,\"kill_rate\":0,\"detail\":\"mutants did not run (errors=3, failed=0)\""
    ),
    (
      Command.output(1, null_clean, "boom"),
      1,
      "\"status\":\"fail\",\"total\":0,\"killed\":0,\"survived\":0,\"kill_rate\":0"
    ),
    (
      Command.ok_output(null_fail_stop),
      1,
      "\"detail\":\"mutants did not run (errors=0, failed=2)\""
    ),
    (Command.ok_output(mut_err_json), 1, "\"phase\":\"mo_mutants\",\"status\":\"fail\"")
  ]
    f_mut = Files.in_memory({
      "arvo.toml": "[app]\nentry = \"main.mo\"\n",
      "main.mo": "module Main\n",
      "frontend/src/arvo.gen.ts": gen_empty_ts
    })
    rep_mut = Command.replies([
      (Command.spec("mo", ["run", "main.mo", "--arvo-contracts"]), Command.ok_output("[]")),
      (Command.spec("mo", ["check", "main.mo"]), Command.ok_output("")),
      (Command.spec("mo", ["test", "--json", "main.mo"]), Command.ok_output(test_json)),
      (Command.spec("mo", ["test", "--jobs", "4", "--json", "--mutants", "main.mo"]), mut_reply),
      (Command.spec("git", ["rev-parse", "--show-prefix"]), Command.ok_output("")),
      (
        Command.spec("git", ["status", "--porcelain", "--untracked-files=all"]),
        Command.ok_output("")
      ),
      (Command.spec("git", ["diff", "--no-renames", "--name-only", "HEAD"]), Command.ok_output(""))
    ])
    assert run_cli(
      Args.of(["verify", "--tier", "feature"]),
      Console.fake(),
      f_mut,
      Command.fake(rep_mut),
      Clock.fixed(t0),
      Env.of({}),
      Network.fake({})
    ) ==
      expect_code
    assert f_mut.read_text(".arvo/dossier/verify.jsonl") is Ok(mj)
    assert mj.contains?(expect_frag)
  end

  # `arvo control --help` and bad config error exit
  c_ctl_h = Console.fake()
  assert run_cli(
    Args.of(["control", "--help"]),
    c_ctl_h,
    files,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    0
  assert c_ctl_h.printed.any?(fn(l) l.contains?("cleanup") end)
  assert run_cli(
    Args.of(["control", "doctor", "--run-id", "r1"]),
    Console.fake(),
    files_bad_cfg,
    Command.fake(replies_ok),
    Clock.fixed(t0),
    Env.of({}),
    Network.fake({})
  ) ==
    1
end
