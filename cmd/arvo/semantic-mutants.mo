## Mandatory `--strength` runner (`mo_strength`) and Spec 2.4 Web-Semantic Mutant probe
## orchestrator (`semantic_mutants`) for `arvo verify --tier full`.
module SemanticMutants
expose StrengthSuiteOutcome(..),
SemanticProbeOutcome(..),
SmTimeouts(..),
default_timeouts,
discover_strength_suites,
run_strength_phase,
apply_probe_mutation,
run_semantic_mutants_phase
use Command
use Config
use Dossier
use Json

## Timeout budget used by `mo_strength` and `semantic_mutants`.
struct SmTimeouts
  check_secs: Int
  test_secs: Int
  rm_secs: Int
end

## Returns default timeout durations for `--strength` and scratch semantic mutant probes.
fn default_timeouts() : SmTimeouts
  SmTimeouts(check_secs: 60, test_secs: 600, rm_secs: 15)
end

## Outcome of running `mo test --json --strength` on one wrong-version suite directory.
struct StrengthSuiteOutcome
  suite_dir: Text
  target_file: Text
  original_passed?: Bool
  scored: Int
  killed: Int
  survived: Int
  invalid: Int
  kill_rate: Float
  passed?: Bool
  detail: Text
end

## Outcome of one Spec 2.4 Web-Semantic Mutant scratch probe.
struct SemanticProbeOutcome
  name: Text
  status: Text
  detail: Text
  ms: Int
end

fn join_rel(dir: Text, rel: Text) : Text
  if dir == ".": rel else: "#{dir}/#{rel}"
end

fn elapsed_ms(clock: Clock, started: Time) : Int
  ms = (clock.now - started).in_milliseconds
  if ms >= 1: ms else: 0
end

fn resolve_target_for_suite(
  suite_name: Text,
  app_dir: Text,
  app_entry: Text,
  root_files: ReadFiles
) : Option(Text)
  if suite_name.starts_with?("arvo_")
    mod = suite_name.drop_prefix("arvo_") or ""
    hyphen = mod.replace("_", "-")
    candidates = [
      "lib/arvo/#{mod}.mo",
      "lib/arvo/#{hyphen}.mo",
      "lib/arvo/sqlite/#{mod}.mo",
      "lib/arvo/sqlite/#{hyphen}.mo",
      "lib/arvo/testing/#{mod}.mo",
      "lib/arvo/testing/#{hyphen}.mo"
    ]
    for p in candidates
      return Some(p) if root_files.exists?(p)
    end
    None
  else
    a1 = join_rel(app_dir, "#{suite_name}.mo")
    a2 = join_rel(app_dir, "#{suite_name.replace("_", "-")}.mo")
    if root_files.exists?(a1)
      Some(a1)
    else if root_files.exists?(a2)
      Some(a2)
    else
      Some(join_rel(app_dir, app_entry))
    end
  end
end

fn scan_strength_folder(
  files: ReadFiles,
  rel_root: Text,
  path_prefix: Text,
  app_dir: Text,
  app_entry: Text,
  root_files: ReadFiles
) : List((Text, Text))
  return [] if not files.exists?(rel_root)
  ents = case files.walk(rel_root)
    Ok(e): e
    Error(_): return []
  end
  var suites = []
  var out = []
  for ent in ents
    continue if not (ent.kind is File) or not ent.name.ends_with?(".mo")
    parts = ent.name.split("/")
    continue if parts.size < 2
    suite_name = (parts.first or "").trim
    continue if suites.contains?(suite_name)
    suites = suites.append(suite_name)
    if resolve_target_for_suite(suite_name, app_dir, app_entry, root_files) is Some(tgt)
      sdir = join_rel(path_prefix, "#{rel_root}/#{suite_name}")
      out = out.append((sdir, tgt))
    end
  end
  out.sort_by(fn(p) p.0 end)
end

## Discovers all `(strength_dir, target_mo_file)` pairs under `<app>/<strength_dir>` and repo `strength/`.
fn discover_strength_suites(
  app_dir: Text,
  cfg: Config.ArvoConfig,
  root_files: ReadFiles,
  app_files: ReadFiles
) : List((Text, Text))
  app_suites = scan_strength_folder(
    app_files,
    cfg.strength_dir,
    app_dir,
    app_dir,
    cfg.entry,
    root_files
  )
  core_suites = if app_dir == "." and cfg.strength_dir == "strength"
    []
  else
    scan_strength_folder(root_files, "strength", ".", app_dir, cfg.entry, root_files)
  end
  var seen = []
  var combined = []
  for pair in app_suites.concat(core_suites)
    if not seen.contains?(pair.0)
      seen = seen.append(pair.0)
      combined = combined.append(pair)
    end
  end
  combined
end

fn suite_outcome_to_json(o: StrengthSuiteOutcome) : Json
  Json.Object({
    "suite_dir": Json.String(o.suite_dir),
    "target_file": Json.String(o.target_file),
    "original_passed": Json.Boolean(o.original_passed?),
    "scored": Json.int(o.scored),
    "killed": Json.int(o.killed),
    "survived": Json.int(o.survived),
    "invalid": Json.int(o.invalid),
    "kill_rate": Json.float(o.kill_rate) or Json.Null,
    "passed": Json.Boolean(o.passed?),
    "detail": Json.String(o.detail)
  })
end

## Executes all discovered `mo test --jobs 4 --json --strength` suites and writes `strength-report.json`.
fn run_strength_phase(
  app_dir: Text,
  tier: Text,
  cfg: Config.ArvoConfig,
  root_files: ReadFiles,
  app_files: Files,
  cmd: Command,
  clock: Clock
) : Dossier.VerifyEvent
  t0 = clock.now
  suites = discover_strength_suites(app_dir, cfg, root_files, app_files.read_only)
  if suites.empty?
    var ev = Dossier.new_event(t0.to_text, tier, "mo_strength", "pass", elapsed_ms(clock, t0))
    ev.total = Some(0)
    ev.killed = Some(0)
    ev.survived = Some(0)
    ev.kill_rate = Some(1.0)
    ev.detail = Some("0 strength suite(s) discovered")
    return ev
  end

  var outcomes = []
  var tot_scored = 0
  var tot_killed = 0
  var tot_survived = 0
  var tot_invalid = 0
  var all_pass? = true
  var fail_notes = []

  for (sdir, target) in suites
    to = default_timeouts()
    case cmd.run("mo", ["test", "--jobs", "4", "--json", "--strength", sdir, target], to.test_secs.seconds)
      Error(err):
        all_pass? = false
        tot_invalid += 1
        fail_notes = fail_notes.append("#{sdir}: #{err}")
        outcomes = outcomes.append(
          StrengthSuiteOutcome(
            suite_dir: sdir,
            target_file: target,
            original_passed?: false,
            scored: 0,
            killed: 0,
            survived: 0,
            invalid: 1,
            kill_rate: 0.0,
            passed?: false,
            detail: "command error: #{err}"
          )
        )
      Ok(out):
        sum = Dossier.parse_mo_strength_json(out.stdout)
        suite_ok? = out.ok? and
          sum.original_passed? and
          not sum.partial? and
          sum.invalid == 0 and
          sum.survived == 0 and
          sum.scored > 0 and
          sum.kill_rate >= cfg.strength_min_kill_rate
        tot_scored += sum.scored
        tot_killed += sum.killed
        tot_survived += sum.survived
        tot_invalid += sum.invalid
        if not suite_ok?
          all_pass? = false
          fail_notes = fail_notes.append(
            "#{sdir} (#{sum.killed}/#{sum.scored}, invalid=#{sum.invalid}, survived=#{sum.survived})"
          )
        end
        outcomes = outcomes.append(
          StrengthSuiteOutcome(
            suite_dir: sdir,
            target_file: target,
            original_passed?: sum.original_passed?,
            scored: sum.scored,
            killed: sum.killed,
            survived: sum.survived,
            invalid: sum.invalid,
            kill_rate: sum.kill_rate,
            passed?: suite_ok?,
            detail: "#{sum.killed}/#{sum.scored} killed (invalid=#{sum.invalid}, survived=#{sum.survived})"
          )
        )
    end
  end

  overall_rate = if tot_scored > 0
    tot_killed.to_float / tot_scored.to_float
  else
    0.0
  end
  final_ok? = all_pass? and overall_rate >= cfg.strength_min_kill_rate

  if app_files.make_folder(".arvo/dossier") is Ok(_)
    rep_json = Json.Object({
      "passed": Json.Boolean(final_ok?),
      "suites_count": Json.int(outcomes.size),
      "scored": Json.int(tot_scored),
      "killed": Json.int(tot_killed),
      "survived": Json.int(tot_survived),
      "invalid": Json.int(tot_invalid),
      "kill_rate": Json.float(overall_rate) or Json.Null,
      "suites": Json.Array(outcomes.map(suite_outcome_to_json))
    })
    _w = app_files.write_text(".arvo/dossier/strength-report.json", "#{rep_json.pretty}\n")
  end

  var ev = Dossier.new_event(
    t0.to_text,
    tier,
    "mo_strength",
    if final_ok?: "pass" else: "fail",
    elapsed_ms(clock, t0)
  )
  ev.total = Some(tot_scored)
  ev.killed = Some(tot_killed)
  ev.survived = Some(tot_survived)
  ev.kill_rate = Some(overall_rate)
  ev.detail = if final_ok?
    Some("#{outcomes.size} suite(s): #{tot_killed}/#{tot_scored} killed (rate=#{overall_rate})")
  else
    Some("strength gate failed: #{fail_notes.join("; ")}")
  end
  ev
end

fn skip_scratch_copy?(rel: Text) : Bool
  rel.starts_with?(".arvo") or
    rel.starts_with?("frontend") or
    rel.starts_with?("node_modules") or
    rel.starts_with?("strength") or
    rel.starts_with?("snapshots") or
    rel.starts_with?(".git") or
    rel.starts_with?("target")
end

fn copy_scratch_tree(
  probe_dir: Text,
  root_files: ReadFiles,
  app_files: Files
) : Result(Unit, Text)
  _mk = try app_files.make_folder(probe_dir).map_error(fn(e) "#{e}" end)
  entries = try app_files.walk(".").map_error(fn(e) "#{e}" end)
  for ent in entries
    continue if not (ent.kind is File)
    continue if skip_scratch_copy?(ent.name)
    data = try app_files.read_bytes(ent.name).map_error(fn(e) "#{e}" end)
    dst = "#{probe_dir}/#{ent.name}"
    parts = dst.split("/")
    parent = parts.take(parts.size - 1).join("/")
    if not parent.empty?
      _p = app_files.make_folder(parent)
    end
    try app_files.write_bytes(dst, data).map_error(fn(e) "#{e}" end)
  end

  if app_files.exists?("#{probe_dir}/mo.toml")
    mo_toml = try app_files.read_text("#{probe_dir}/mo.toml").map_error(fn(e) "#{e}" end)
    rewritten = mo_toml.replace("path = \"../..\"", "path = \"arvo_dep\"").replace(
      "path = \"..\"",
      "path = \"arvo_dep\""
    )
    try app_files.write_text("#{probe_dir}/mo.toml", rewritten).map_error(fn(e) "#{e}" end)
  end

  dep_root = "#{probe_dir}/arvo_dep"
  _mk_dep = try app_files.make_folder("#{dep_root}/lib/arvo").map_error(fn(e) "#{e}" end)
  if root_files.exists?("mo.toml")
    root_toml = try root_files.read_text("mo.toml").map_error(fn(e) "#{e}" end)
    try app_files.write_text("#{dep_root}/mo.toml", root_toml).map_error(fn(e) "#{e}" end)
  end
  if root_files.exists?("lib/arvo")
    lib_ents = try root_files.walk("lib/arvo").map_error(fn(e) "#{e}" end)
    for lent in lib_ents
      continue if not (lent.kind is File) or not lent.name.ends_with?(".mo")
      ldata = try root_files.read_bytes("lib/arvo/#{lent.name}").map_error(fn(e) "#{e}" end)
      ldst = "#{dep_root}/lib/arvo/#{lent.name}"
      lparts = ldst.split("/")
      lparent = lparts.take(lparts.size - 1).join("/")
      if not lparent.empty?
        _lp = app_files.make_folder(lparent)
      end
      try app_files.write_bytes(ldst, ldata).map_error(fn(e) "#{e}" end)
    end
  end
  Ok(Unit)
end

## Applies one named Spec 2.4 semantic mutant inside a scratch copy and returns `(file, mutated)` or error.
fn apply_probe_mutation(probe: Text, target_rel: Text, src: Text) : Result(Text, Text)
  if probe == "strip_require_csrf"
    pat = "return Error(Forbidden) if not Auth.require_csrf(req, member.session)"
    return Error("pattern not found in #{target_rel}") if not src.contains?(pat)
    Ok(src.replace(pat, "_csrf_bypass = Auth.require_csrf(req, member.session)"))
  else if probe == "weaken_required_auth"
    sig = "fn post_logout(req: Api.Request, member: Member, db: Sqlite.Database, env: Env)"
    body = "  return Error(Forbidden) if not Auth.require_csrf(req, member.session)\n  _rev = try Sessions.revoke(db, member.session.id).map_error(fn(e) ServerFailed(reason: \"\#{e}\") end)\n  Ok(Auth.logout_response(Inertia.redirect(\"/login\"), session_cfg(env)))"
    return Error("post_logout signature/body not found") if not src.contains?(sig) or
      not src.contains?(body)
    new_sig = "fn post_logout(req: Api.Request, viewer: Option(Member), db: Sqlite.Database, env: Env)"
    new_body = "  if viewer is Some(member)\n    return Error(Forbidden) if not Auth.require_csrf(req, member.session)\n    _rev = try Sessions.revoke(db, member.session.id).map_error(fn(e) ServerFailed(reason: \"\#{e}\") end)\n  end\n  Ok(Auth.logout_response(Inertia.redirect(\"/\"), session_cfg(env)))"
    Ok(src.replace(sig, new_sig).replace(body, new_body))
  else if probe == "drop_optimistic_lock"
    pat = "\"UPDATE bills SET status = 'in_flight', version = version + 1 WHERE id = ? AND version = ?\",\n    [Sqlite.Integer(id), Sqlite.Integer(input.expected_version)]"
    return Error("optimistic lock SQL not found") if not src.contains?(pat)
    Ok(
      src.replace(
        pat,
        "\"UPDATE bills SET status = 'in_flight', version = version + 1 WHERE id = ?\",\n    [Sqlite.Integer(id)]"
      )
    )
  else if probe == "bypass_escape_html"
    pat = "raw.replace(\"&\", \"&amp;\").replace(\"\\\"\", \"&quot;\").replace(\"'\", \"&#39;\").replace(\"<\", \"&lt;\")\n    .replace(\">\", \"&gt;\")"
    return Error("escape_html body not found") if not src.contains?(pat)
    Ok(src.replace(pat, "raw"))
  else if probe == "disable_foreign_keys"
    pat = "  count_rows = try db.query(\"SELECT id FROM members LIMIT 1\", []).map_error("
    return Error("bootstrap_db hook not found") if not src.contains?(pat)
    Ok(
      src.replace(
        pat,
        "  _fk = db.run(\"PRAGMA foreign_keys = OFF\", [])\n#{pat}"
      )
    )
  else
    Error("unknown semantic mutant probe '#{probe}'")
  end
end

fn cleanup_scratch(app_dir: Text, app_files: Files, cmd: Command) : Unit
  to = default_timeouts()
  if app_files.walk(".arvo/tmp/sm") is Ok(ents)
    for ent in ents
      if ent.kind is File
        _rm = app_files.remove(".arvo/tmp/sm/#{ent.name}")
      end
    end
  end
  _rm_fs = cmd.run("rm", ["-rf", join_rel(app_dir, ".arvo/tmp/sm")], to.rm_secs.seconds)
end

fn semantic_probe_list() : List((Text, Text))
  [
    ("strip_require_csrf", "routes.mo"),
    ("weaken_required_auth", "routes.mo"),
    ("drop_optimistic_lock", "routes.mo"),
    ("bypass_escape_html", "arvo_dep/lib/arvo/inertia.mo"),
    ("disable_foreign_keys", "routes.mo")
  ]
end

## Executes all 5 Spec 2.4 Web-Semantic Mutant probes in scratch copies and fails with `E_SEMANTIC_MUTANT_SURVIVED` if any stays green.
fn run_semantic_mutants_phase(
  app_dir: Text,
  tier: Text,
  cfg: Config.ArvoConfig,
  root_files: ReadFiles,
  app_files: Files,
  cmd: Command,
  clock: Clock
) : Dossier.VerifyEvent
  t0 = clock.now
  if not app_files.exists?("routes.mo")
    var ev = Dossier.new_event(
      t0.to_text,
      tier,
      "semantic_mutants",
      "pass",
      elapsed_ms(clock, t0)
    )
    ev.total = Some(0)
    ev.killed = Some(0)
    ev.survived = Some(0)
    ev.kill_rate = Some(1.0)
    ev.detail = Some("0 semantic probes applicable (no routes.mo)")
    return ev
  end

  cleanup_scratch(app_dir, app_files, cmd)
  probes = semantic_probe_list()
  var outcomes = []
  var killed_cnt = 0
  var survived_cnt = 0
  var err_msgs = []

  for (probe, target_rel) in probes
    p_start = clock.now
    probe_rel = ".arvo/tmp/sm/#{probe}"
    case copy_scratch_tree(probe_rel, root_files, app_files)
      Error(e):
        survived_cnt += 1
        err_msgs = err_msgs.append("#{probe}: scratch copy failed (#{e})")
        outcomes = outcomes.append(
          SemanticProbeOutcome(
            name: probe,
            status: "error",
            detail: e,
            ms: elapsed_ms(clock, p_start)
          )
        )
        continue
      Ok(_): Unit
    end

    target_file = "#{probe_rel}/#{target_rel}"
    src = case app_files.read_text(target_file)
      Ok(s): s
      Error(e):
        err_msgs = err_msgs.append("#{probe}: missing #{target_rel} (#{e})")
        outcomes = outcomes.append(
          SemanticProbeOutcome(
            name: probe,
            status: "error",
            detail: "#{e}",
            ms: elapsed_ms(clock, p_start)
          )
        )
        continue
    end

    mutated = case apply_probe_mutation(probe, target_rel, src)
      Ok(m): m
      Error(e):
        err_msgs = err_msgs.append("#{probe}: #{e}")
        outcomes = outcomes.append(
          SemanticProbeOutcome(
            name: probe,
            status: "error",
            detail: e,
            ms: elapsed_ms(clock, p_start)
          )
        )
        continue
    end
    if app_files.write_text(target_file, mutated) is Error(e)
      err_msgs = err_msgs.append("#{probe}: writing #{target_rel} failed (#{e})")
      outcomes = outcomes.append(
        SemanticProbeOutcome(name: probe, status: "error", detail: "#{e}", ms: elapsed_ms(clock, p_start))
      )
      continue
    end

    to = default_timeouts()
    entry_arg = join_rel(app_dir, "#{probe_rel}/#{cfg.entry}")
    case cmd.run("mo", ["check", entry_arg], to.check_secs.seconds)
      Error(e):
        err_msgs = err_msgs.append("E_SEMANTIC_MUTANT_COMPILE_ERROR (#{probe}): #{e}")
        outcomes = outcomes.append(
          SemanticProbeOutcome(
            name: probe,
            status: "compile_error",
            detail: "#{e}",
            ms: elapsed_ms(clock, p_start)
          )
        )
        continue
      Ok(chk_out):
        if not chk_out.ok?
          err_msgs = err_msgs.append(
            "E_SEMANTIC_MUTANT_COMPILE_ERROR (#{probe}): #{chk_out.stderr.trim}"
          )
          outcomes = outcomes.append(
            SemanticProbeOutcome(
              name: probe,
              status: "compile_error",
              detail: chk_out.stderr.trim,
              ms: elapsed_ms(clock, p_start)
            )
          )
          continue
        end
    end

    case cmd.run("mo", ["test", "--jobs", "4", "--json", entry_arg], to.test_secs.seconds)
      Error(e):
        err_msgs = err_msgs.append("#{probe}: runner error #{e}")
        outcomes = outcomes.append(
          SemanticProbeOutcome(
            name: probe,
            status: "error",
            detail: "#{e}",
            ms: elapsed_ms(clock, p_start)
          )
        )
      Ok(test_out):
        sum = Dossier.parse_mo_test_json(test_out.stdout)
        caught? = sum.errors == 0 and (sum.failed > 0 or sum.stopped > 0)
        if caught?
          killed_cnt += 1
          outcomes = outcomes.append(
            SemanticProbeOutcome(
              name: probe,
              status: "killed",
              detail: "caught (failed=#{sum.failed + sum.stopped}, errors=#{sum.errors})",
              ms: elapsed_ms(clock, p_start)
            )
          )
        else if not test_out.ok? or sum.errors > 0 or sum.passed == 0
          err_msgs = err_msgs.append("#{probe}: test runner did not report a completed test run (#{test_out.stderr.trim})")
          outcomes = outcomes.append(
            SemanticProbeOutcome(
              name: probe,
              status: "error",
              detail: "test runner did not report a completed test run (errors=#{sum.errors})",
              ms: elapsed_ms(clock, p_start)
            )
          )
        else
          survived_cnt += 1
          err_msgs = err_msgs.append("E_SEMANTIC_MUTANT_SURVIVED: #{probe}")
          outcomes = outcomes.append(
            SemanticProbeOutcome(
              name: probe,
              status: "survived",
              detail: "E_SEMANTIC_MUTANT_SURVIVED",
              ms: elapsed_ms(clock, p_start)
            )
          )
        end
    end
  end

  cleanup_scratch(app_dir, app_files, cmd)

  passed? = killed_cnt == probes.size
  rate = killed_cnt.to_float / probes.size.to_float
  if app_files.make_folder(".arvo/dossier") is Ok(_)
    rep = Json.Object({
      "passed": Json.Boolean(passed?),
      "total": Json.int(probes.size),
      "killed": Json.int(killed_cnt),
      "survived": Json.int(survived_cnt),
      "kill_rate": Json.float(rate) or Json.Null,
      "probes": Json.Array(
        outcomes.map(fn(o)
          Json.Object({
            "name": Json.String(o.name),
            "status": Json.String(o.status),
            "detail": Json.String(o.detail),
            "ms": Json.int(o.ms)
          })
        end)
      )
    })
    _wrep = app_files.write_text(".arvo/dossier/semantic-mutants.json", "#{rep.pretty}\n")
  end

  var ev = Dossier.new_event(
    t0.to_text,
    tier,
    "semantic_mutants",
    if passed?: "pass" else: "fail",
    elapsed_ms(clock, t0)
  )
  ev.total = Some(probes.size)
  ev.killed = Some(killed_cnt)
  ev.survived = Some(survived_cnt)
  ev.kill_rate = Some(rate)
  ev.detail = if passed?
    Some("#{killed_cnt}/#{probes.size} Spec 2.4 semantic mutants caught")
  else
    Some(err_msgs.join("; "))
  end
  ev
end

test "SemanticMutants runs --strength discovery/scoring and Spec 2.4 Web-Semantic Mutant probes"
  dt = default_timeouts()
  assert dt.check_secs == 60 and dt.test_secs == 600 and dt.rm_secs == 15
  t0 = Time.parse("2026-11-25T23:15:00Z") or stop "t0"
  assert elapsed_ms(Clock.fixed(t0 - 2.milliseconds), t0) == 0
  assert elapsed_ms(Clock.fixed(t0), t0) == 0
  assert elapsed_ms(Clock.fixed(t0 + 1.millisecond), t0) == 1
  assert elapsed_ms(Clock.fixed(t0 + 5.milliseconds), t0) == 5
  cfg = Config.default_config()

  # 1. Empty strength discovery returns 0/0 without skipped status
  f_empty = Files.in_memory({"arvo.toml": "[app]\nentry=\"main.mo\"\n"})
  ev_empty = run_strength_phase(
    "examples/app",
    "full",
    cfg,
    f_empty.read_only,
    f_empty,
    Command.fake(Command.replies([])),
    Clock.fixed(t0)
  )
  assert ev_empty.status == "pass" and
    ev_empty.total == Some(0) and
    ev_empty.killed == Some(0) and
    ev_empty.survived == Some(0) and
    ev_empty.kill_rate == Some(1.0) and
    ev_empty.detail == Some("0 strength suite(s) discovered")

  # 2. Discovers both app-local strength/routes and root strength/arvo_csrf, ignoring non-.mo files
  f_str = Files.in_memory({
    "lib/arvo/csrf.mo": "module Arvo.Csrf\n",
    "strength/top_level.mo": "ignored",
    "strength/bad_dir.mo/inside.txt": "ignored dir ending in .mo",
    "strength/arvo_csrf/README.md": "ignored docs",
    "strength/arvo_csrf/01.mo": "module Arvo.Csrf\n",
    "examples/app/main.mo": "module Main\n",
    "examples/app/strength/routes/01.mo": "module Routes\n",
    "examples/app/strength/routes/02.mo": "module Routes\n"
  })
  app_str = f_str.within("examples/app")
  discovered = discover_strength_suites("examples/app", cfg, f_str.read_only, app_str.read_only)
  assert discovered == [
    ("examples/app/strength/routes", "examples/app/main.mo"),
    ("strength/arvo_csrf", "lib/arvo/csrf.mo")
  ]
  # Root app avoids scanning `strength` twice, unless strength_dir differs
  f_root_s = Files.in_memory({
    "lib/arvo/csrf.mo": "module Arvo.Csrf\n",
    "main.mo": "module Main\n",
    "strength/arvo_csrf/01.mo": "module Arvo.Csrf\n",
    "custom_str/routes/01.mo": "module Routes\n"
  })
  assert discover_strength_suites(".", cfg, f_root_s.read_only, f_root_s.read_only) == [
    ("strength/arvo_csrf", "lib/arvo/csrf.mo")
  ]
  var cfg_custom = Config.default_config()
  cfg_custom.strength_dir = "custom_str"
  assert discover_strength_suites(".", cfg_custom, f_root_s.read_only, f_root_s.read_only) == [
    ("custom_str/routes", "main.mo"),
    ("strength/arvo_csrf", "lib/arvo/csrf.mo")
  ]

  ok_routes = """
    {"record":"strength","version":2,"original":"passed","counts":{"invalid":0,"changes_intent":0,"defect":0}}
    {"record":"strength_summary","event":"strength_summary","original":"passed","scored":2,"killed":2,"survived":0,"kill_rate":1.0}
    """
  ok_csrf = """
    {"record":"strength","version":2,"original":"passed","counts":{"invalid":0,"changes_intent":0,"defect":0}}
    {"record":"strength_summary","event":"strength_summary","original":"passed","scored":1,"killed":1,"survived":0,"kill_rate":1.0}
    """
  rep_str_ok = Command.replies([
    (
      Command.spec(
        "mo",
        ["test", "--jobs", "4", "--json", "--strength", "examples/app/strength/routes", "examples/app/main.mo"]
      ),
      Command.ok_output(ok_routes)
    ),
    (
      Command.spec(
        "mo",
        ["test", "--jobs", "4", "--json", "--strength", "strength/arvo_csrf", "lib/arvo/csrf.mo"]
      ),
      Command.ok_output(ok_csrf)
    )
  ])
  ev_str_ok = run_strength_phase(
    "examples/app",
    "full",
    cfg,
    f_str.read_only,
    app_str,
    Command.fake(rep_str_ok),
    Clock.fixed(t0)
  )
  assert ev_str_ok.status == "pass" and ev_str_ok.total == Some(3) and
    ev_str_ok.killed == Some(3) and
    ev_str_ok.survived == Some(0)
  assert f_str.exists?("examples/app/.arvo/dossier/strength-report.json")

  bad_csrf = """
    {"record":"strength","version":2,"original":"passed","counts":{"invalid":0,"changes_intent":0,"defect":0}}
    {"record":"strength_summary","event":"strength_summary","original":"passed","scored":3,"killed":1,"survived":1,"kill_rate":0.333}
    """
  rep_str_fail = Command.replies([
    (
      Command.spec(
        "mo",
        ["test", "--jobs", "4", "--json", "--strength", "examples/app/strength/routes", "examples/app/main.mo"]
      ),
      Command.ok_output(ok_routes)
    ),
    (
      Command.spec(
        "mo",
        ["test", "--jobs", "4", "--json", "--strength", "strength/arvo_csrf", "lib/arvo/csrf.mo"]
      ),
      Command.output(1, bad_csrf, "survived")
    )
  ])
  ev_str_fail = run_strength_phase(
    "examples/app",
    "full",
    cfg,
    f_str.read_only,
    app_str,
    Command.fake(rep_str_fail),
    Clock.fixed(t0)
  )
  assert ev_str_fail.status == "fail" and ev_str_fail.survived == Some(1) and
    ev_str_fail.kill_rate == Some(0.6)

  # Strength command Error(NotPermitted) and each individual suite_ok? guard fails cleanly
  ev_str_err = run_strength_phase(
    "examples/app",
    "full",
    cfg,
    f_str.read_only,
    app_str,
    Command.fake(rep_str_ok).allow_programs([]),
    Clock.fixed(t0)
  )
  assert ev_str_err.status == "fail" and ev_str_err.total == Some(0) and
    ev_str_err.killed == Some(0) and
    ev_str_err.survived == Some(0) and
    ev_str_err.kill_rate == Some(0.0)
  assert f_str.read_text("examples/app/.arvo/dossier/strength-report.json") is Ok(srep_err)
  assert Json.parse(srep_err) is Ok(sdoc_err)
  assert sdoc_err.bool_at("passed") == Some(false) and
    sdoc_err.int_at("invalid") == Some(2) and
    sdoc_err.bool_at("suites.0.original_passed") == Some(false) and
    sdoc_err.int_at("suites.0.scored") == Some(0) and
    sdoc_err.int_at("suites.0.killed") == Some(0) and
    sdoc_err.int_at("suites.0.survived") == Some(0) and
    sdoc_err.int_at("suites.0.invalid") == Some(1) and
    sdoc_err.bool_at("suites.0.passed") == Some(false)

  for bad_json in [
    "{\"record\":\"strength\",\"version\":2,\"original\":\"failed\",\"counts\":{\"invalid\":0}}\n{\"record\":\"strength_summary\",\"original\":\"failed\",\"scored\":2,\"killed\":2,\"survived\":0,\"kill_rate\":1.0}\n",
    "{\"record\":\"strength\",\"version\":2,\"original\":\"passed\",\"counts\":{\"invalid\":1}}\n{\"record\":\"strength_summary\",\"original\":\"passed\",\"scored\":2,\"killed\":2,\"survived\":0,\"kill_rate\":1.0}\n",
    "{\"record\":\"strength\",\"version\":2,\"original\":\"passed\",\"counts\":{\"invalid\":0}}\n{\"record\":\"strength_summary\",\"original\":\"passed\",\"scored\":0,\"killed\":0,\"survived\":0,\"kill_rate\":1.0}\n"
  ]
    rep_one_bad = Command.replies([
      (
        Command.spec(
          "mo",
          ["test", "--jobs", "4", "--json", "--strength", "examples/app/strength/routes", "examples/app/main.mo"]
        ),
        Command.ok_output(ok_routes)
      ),
      (
        Command.spec(
          "mo",
          ["test", "--jobs", "4", "--json", "--strength", "strength/arvo_csrf", "lib/arvo/csrf.mo"]
        ),
        Command.ok_output(bad_json)
      )
    ])
    ev_ob = run_strength_phase(
      "examples/app",
      "full",
      cfg,
      f_str.read_only,
      app_str,
      Command.fake(rep_one_bad),
      Clock.fixed(t0)
    )
    assert ev_ob.status == "fail"
  end

  # All suites scoring 0 sets overall_rate = 0.0 cleanly
  f_z = Files.in_memory({"examples/app/main.mo": "module M\n", "examples/app/strength/routes/01.mo": "module R\n"})
  ev_z = run_strength_phase(
    "examples/app",
    "full",
    cfg,
    f_z.read_only,
    f_z.within("examples/app"),
    Command.fake(
      Command.replies([
        (
          Command.spec(
            "mo",
            ["test", "--jobs", "4", "--json", "--strength", "examples/app/strength/routes", "examples/app/main.mo"]
          ),
          Command.ok_output(
            "{\"record\":\"strength\",\"version\":2,\"original\":\"passed\",\"counts\":{\"invalid\":0}}\n{\"record\":\"strength_summary\",\"original\":\"passed\",\"scored\":0,\"killed\":0,\"survived\":0,\"kill_rate\":1.0}\n"
          )
        )
      ])
    ),
    Clock.fixed(t0)
  )
  assert ev_z.status == "fail" and ev_z.kill_rate == Some(0.0)

  # Partial 1/1 suite + 1 command Error sets overall_rate = 1.0 while status remains fail (kills all_pass? & tot_scored > 0)
  f_part = Files.in_memory({
    "lib/arvo/csrf.mo": "module C\n",
    "examples/app/main.mo": "module M\n",
    "examples/app/strength/routes/01.mo": "module R\n",
    "strength/arvo_csrf/01.mo": "module C\n"
  })
  ev_part = run_strength_phase(
    "examples/app",
    "full",
    cfg,
    f_part.read_only,
    f_part.within("examples/app"),
    Command.fake(
      Command.replies([
        (
          Command.spec(
            "mo",
            ["test", "--jobs", "4", "--json", "--strength", "examples/app/strength/routes", "examples/app/main.mo"]
          ),
          Command.ok_output(ok_csrf)
        )
      ])
    ),
    Clock.fixed(t0)
  )
  assert ev_part.status == "fail" and ev_part.kill_rate == Some(1.0) and ev_part.total == Some(1)

  # No routes.mo semantic check sets exact zero metrics
  ev_no_routes = run_semantic_mutants_phase(
    "examples/app",
    "full",
    cfg,
    f_empty.read_only,
    f_empty,
    Command.fake(Command.replies([])),
    Clock.fixed(t0)
  )
  assert ev_no_routes.status == "pass" and
    ev_no_routes.total == Some(0) and
    ev_no_routes.killed == Some(0) and
    ev_no_routes.survived == Some(0)

  # 3. Spec 2.4 semantic mutants: all 5 caught vs E_SEMANTIC_MUTANT_SURVIVED + scratch cleanup
  routes_fixture = """
    module Routes
    fn bootstrap_db(db: Sqlite.Database, rng: SecureRandom, clock: Clock, env: Env) : Result(Unit, AppError)
      count_rows = try db.query("SELECT id FROM members LIMIT 1", []).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Unit)
    end
    fn post_logout(req: Api.Request, member: Member, db: Sqlite.Database, env: Env) : Result(Api.Response, AppError)
      return Error(Forbidden) if not Auth.require_csrf(req, member.session)
      _rev = try Sessions.revoke(db, member.session.id).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Auth.logout_response(Inertia.redirect("/login"), session_cfg(env)))
    end
    fn pay_bill()
      return Error(Forbidden) if not Auth.require_csrf(req, member.session)
      upd = try db.execute(
        "UPDATE bills SET status = 'in_flight', version = version + 1 WHERE id = ? AND version = ?",
        [Sqlite.Integer(id), Sqlite.Integer(input.expected_version)]
      )
    end
    """
  inertia_fixture = """
    module Arvo.Inertia
    fn escape_html(raw: Text) : Text
      raw.replace("&", "&amp;").replace("\\"", "&quot;").replace("'", "&#39;").replace("<", "&lt;")
        .replace(">", "&gt;")
    end
    """
  f_sm = Files.in_memory({
    "mo.toml": "[package]\nname = \"arvo\"\n",
    "lib/arvo/inertia.mo": inertia_fixture,
    "lib/arvo/bad_lib.mo/ignored.txt": "folder ending in .mo",
    "lib/arvo/nested/helper.mo": "module Arvo.Helper\n",
    "examples/app/mo.toml": "[package]\nname = \"starter\"\n[dependencies]\narvo = { path = \"../..\" }\n",
    "examples/app/main.mo": "module Main\n",
    "examples/app/routes.mo": routes_fixture,
    "examples/app/nested/extra.mo": "module Extra\n",
    "examples/app/.arvo/ignored.mo": "x",
    "examples/app/frontend/ignored.ts": "x",
    "examples/app/node_modules/ignored.js": "x",
    "examples/app/strength/ignored.mo": "x",
    "examples/app/snapshots/ignored.json": "x",
    "examples/app/.git/HEAD": "ref: refs/heads/main\n"
  })
  app_sm = f_sm.within("examples/app")

  assert copy_scratch_tree(".arvo/tmp/sm/check_skip", f_sm.read_only, app_sm) == Ok(Unit)
  assert f_sm.exists?("examples/app/.arvo/tmp/sm/check_skip/nested/extra.mo")
  assert f_sm.exists?("examples/app/.arvo/tmp/sm/check_skip/arvo_dep/lib/arvo/nested/helper.mo")
  assert not f_sm.exists?("examples/app/.arvo/tmp/sm/check_skip/.arvo/ignored.mo")
  assert not f_sm.exists?("examples/app/.arvo/tmp/sm/check_skip/frontend/ignored.ts")
  assert not f_sm.exists?("examples/app/.arvo/tmp/sm/check_skip/node_modules/ignored.js")
  assert not f_sm.exists?("examples/app/.arvo/tmp/sm/check_skip/strength/ignored.mo")
  assert not f_sm.exists?("examples/app/.arvo/tmp/sm/check_skip/snapshots/ignored.json")
  assert not f_sm.exists?("examples/app/.arvo/tmp/sm/check_skip/.git/HEAD")
  cleanup_scratch("examples/app", app_sm, Command.fake(Command.replies([])))

  fail_json = "{\"record\":\"totals\",\"passed\":4,\"failed\":1,\"stopped\":0,\"errors\":0}\n"
  stop_json = "{\"record\":\"totals\",\"passed\":4,\"failed\":0,\"stopped\":1,\"errors\":0}\n"
  err_json = "{\"record\":\"totals\",\"passed\":4,\"failed\":0,\"stopped\":0,\"errors\":1}\n"
  pass_json = "{\"record\":\"totals\",\"passed\":5,\"failed\":0,\"stopped\":0,\"errors\":0}\n"
  var sm_ok_replies = []
  var sm_surv_replies = []
  for (probe, _) in semantic_probe_list()
    entry_p = "examples/app/.arvo/tmp/sm/#{probe}/main.mo"
    sm_ok_replies = sm_ok_replies.append((Command.spec("mo", ["check", entry_p]), Command.ok_output("")))
    ok_test_out = if probe == "weaken_required_auth"
      Command.ok_output(stop_json)
    else if probe == "bypass_escape_html"
      Command.ok_output(fail_json)
    else
      Command.output(1, fail_json, "fail")
    end
    sm_ok_replies = sm_ok_replies.append(
      (Command.spec("mo", ["test", "--jobs", "4", "--json", entry_p]), ok_test_out)
    )
    sm_surv_replies = sm_surv_replies.append(
      (Command.spec("mo", ["check", entry_p]), Command.ok_output(""))
    )
    t_out = if probe == "strip_require_csrf"
      Command.ok_output(pass_json)
    else if probe == "drop_optimistic_lock"
      Command.ok_output(err_json)
    else if probe == "disable_foreign_keys"
      Command.output(1, pass_json, "nonzero exit")
    else
      Command.output(1, fail_json, "fail")
    end
    sm_surv_replies = sm_surv_replies.append(
      (Command.spec("mo", ["test", "--jobs", "4", "--json", entry_p]), t_out)
    )
  end
  sm_ok_replies = sm_ok_replies.append(
    (Command.spec("rm", ["-rf", "examples/app/.arvo/tmp/sm"]), Command.ok_output(""))
  )
  sm_surv_replies = sm_surv_replies.append(
    (Command.spec("rm", ["-rf", "examples/app/.arvo/tmp/sm"]), Command.ok_output(""))
  )

  ev_sm_ok = run_semantic_mutants_phase(
    "examples/app",
    "full",
    cfg,
    f_sm.read_only,
    app_sm,
    Command.fake(Command.replies(sm_ok_replies)),
    Clock.fixed(t0)
  )
  assert ev_sm_ok.status == "pass" and ev_sm_ok.total == Some(5) and
    ev_sm_ok.killed == Some(5) and
    ev_sm_ok.survived == Some(0)
  assert not f_sm.exists?("examples/app/.arvo/tmp/sm/strip_require_csrf/main.mo")
  assert f_sm.read_text("examples/app/.arvo/dossier/semantic-mutants.json") is Ok(sm_ok_txt)
  assert sm_ok_txt.split("caught (failed=1, errors=0)").size == 6

  ev_sm_surv = run_semantic_mutants_phase(
    "examples/app",
    "full",
    cfg,
    f_sm.read_only,
    app_sm,
    Command.fake(Command.replies(sm_surv_replies)),
    Clock.fixed(t0)
  )
  assert ev_sm_surv.status == "fail" and ev_sm_surv.survived == Some(1) and
    ev_sm_surv.kill_rate == Some(0.4)
  assert (ev_sm_surv.detail or "").contains?("E_SEMANTIC_MUTANT_SURVIVED")
  assert f_sm.read_text("examples/app/.arvo/dossier/semantic-mutants.json") is Ok(sm_fail_txt)
  assert sm_fail_txt.split("\"status\": \"error\"").size == 3

  # Blocked scratch dir / compile error / missing body failures all fail closed cleanly
  f_blk_sm = Files.in_memory({"routes.mo": routes_fixture, ".arvo": "blocker"})
  ev_blk_sm = run_semantic_mutants_phase(
    ".",
    "full",
    cfg,
    f_empty.read_only,
    f_blk_sm,
    Command.fake(Command.replies([])),
    Clock.fixed(t0)
  )
  assert ev_blk_sm.status == "fail" and ev_blk_sm.survived == Some(5)

  assert apply_probe_mutation("bogus", "routes.mo", routes_fixture) is Error(_)
  assert apply_probe_mutation("strip_require_csrf", "routes.mo", "clean") is Error(_)
  assert apply_probe_mutation(
    "strip_require_csrf",
    "routes.mo",
    "return Error(Forbidden) if not Auth.require_csrf(req, member.session)"
  ) == Ok("_csrf_bypass = Auth.require_csrf(req, member.session)")
  assert apply_probe_mutation(
    "disable_foreign_keys",
    "routes.mo",
    "  count_rows = try db.query(\"SELECT id FROM members LIMIT 1\", []).map_error(fn(e) \"\#{e}\" end)"
  ) ==
    Ok(
      "  _fk = db.run(\"PRAGMA foreign_keys = OFF\", [])\n  count_rows = try db.query(\"SELECT id FROM members LIMIT 1\", []).map_error(fn(e) \"\#{e}\" end)"
    )
  assert apply_probe_mutation(
    "weaken_required_auth",
    "routes.mo",
    "fn post_logout(req: Api.Request, member: Member, db: Sqlite.Database, env: Env)\n"
  ) is
    Error(_)

  f_targets = Files.in_memory({
    "lib/arvo/web-test.mo": "module Arvo.WebTest\n",
    "lib/arvo/sqlite/jobs.mo": "module Arvo.Sqlite.Jobs\n",
    "lib/arvo/testing/sim.mo": "module Arvo.Testing.Sim\n",
    "examples/app/main.mo": "module Main\n",
    "examples/app/routes.mo": "module Routes\n",
    "examples/app/bill-rules.mo": "module BillRules\n"
  }).read_only
  assert resolve_target_for_suite("arvo_web_test", "examples/app", "main.mo", f_targets) ==
    Some("lib/arvo/web-test.mo")
  assert resolve_target_for_suite("arvo_jobs", "examples/app", "main.mo", f_targets) ==
    Some("lib/arvo/sqlite/jobs.mo")
  assert resolve_target_for_suite("arvo_sim", "examples/app", "main.mo", f_targets) ==
    Some("lib/arvo/testing/sim.mo")
  assert resolve_target_for_suite("routes", "examples/app", "main.mo", f_targets) ==
    Some("examples/app/routes.mo")
  assert resolve_target_for_suite("bill_rules", "examples/app", "main.mo", f_targets) ==
    Some("examples/app/bill-rules.mo")
  assert resolve_target_for_suite("domain", "examples/app", "main.mo", f_targets) ==
    Some("examples/app/main.mo")
end
