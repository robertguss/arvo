## Frontend verification phases (`vitest_fixtures`, `browser_e2e`, `stryker`) for `arvo verify`.
## Validates build-SHA-stamped Vitest, Playwright E2E/axe/visual-parity, and Stryker evidence strictly.
module FrontendCheck
expose StrykerSummary(..),
E2eReportSummary(..),
parse_stryker_report,
validate_vitest_evidence,
validate_e2e_report,
run_vitest_phase,
run_browser_e2e_phase,
run_stryker_phase
use Command
use Config
use Control
use Dossier
use Json

## Parsed Stryker JSON mutation report counts.
struct StrykerSummary
  total: Int
  killed: Int
  survived: Int
  kill_rate: Float
end

## Validated Playwright E2E evidence summary.
struct E2eReportSummary
  report_path: Text
  viewports_seen: List(Text)
  scenarios_count: Int
  db_checks_passed: Int
  visual_diff_pixels: Int
  screenshots_count: Int
end

fn trim_frontend_dir(cfg: Config.ArvoConfig) : Text
  t = cfg.frontend_dir.trim
  (t.drop_suffix("/") or t)
end

fn has_frontend_runner?(files: ReadFiles, cfg: Config.ArvoConfig) : Bool
  fdir = trim_frontend_dir(cfg)
  not fdir.empty? and files.exists?("#{fdir}/package.json")
end

fn join_rel(app_dir: Text, rel: Text) : Text
  if app_dir == ".": rel else: "#{app_dir}/#{rel}"
end

fn elapsed_ms(clock: Clock, started: Time) : Int
  ms = (clock.now - started).in_milliseconds
  if ms >= 1: ms else: 0
end

fn not_applicable_event(t: Time, tier: Text, phase: Text, fdir: Text, clock: Clock) : Dossier.VerifyEvent
  ms = elapsed_ms(clock, t)
  var ev = Dossier.new_event(t.to_text, tier, phase, "pass", ms)
  ev.detail = Some("not applicable (no #{fdir}/package.json)")
  ev
end

fn fail_event(t: Time, tier: Text, phase: Text, msg: Text, clock: Clock) : Dossier.VerifyEvent
  ms = elapsed_ms(clock, t)
  var ev = Dossier.new_event(t.to_text, tier, phase, "fail", ms)
  ev.detail = Some(msg)
  ev
end

fn list_files_recursive(files: ReadFiles, dir_rel: Text) : List(Text)
  case files.walk(dir_rel)
    Error(_): []
    Ok(ents):
      ents.filter_map(fn(ent)
        if ent.kind is File: Some(ent.name) else: None
      end).sort
  end
end

fn check_meta_sha(
  files: ReadFiles,
  meta_path: Text,
  expected_sha: Text,
  label: Text,
  repro: Text
) : Result(Unit, Text)
  raw = try files.read_text(meta_path).map_error(
    fn(_) "missing #{meta_path}; run: #{repro}" end
  )
  doc = try Json.parse(raw).map_error(fn(e) "corrupt #{meta_path}: #{e}" end)
  got = doc.text_at("build_sha") or ""
  if got != expected_sha
    return Error("stale #{label} evidence (got #{got}, expected #{expected_sha}); run: #{repro}")
  end
  Ok(Unit)
end

fn json_bool_at(doc: Json, key: Text) : Bool
  case doc.path(key)
    Some(Json.Boolean(b)): b
    Some(_) | None: false
  end
end

## Validates `.arvo/fixtures`, `.arvo/evidence/vitest-meta.json`, and `vitest-report.json`.
fn validate_vitest_evidence(
  app_dir: Text,
  cfg: Config.ArvoConfig,
  files: ReadFiles,
  cur_sha: Text
) : Result((Int, Int), Text)
  fdir = trim_frontend_dir(cfg)
  repro = "cd #{join_rel(app_dir, fdir)} && npm run test:ci"
  fixtures = list_files_recursive(files, ".arvo/fixtures").filter(fn(p) p.ends_with?(".json") end)
  if fixtures.empty?
    return Error(
      "missing real Mo Inertia fixtures under .arvo/fixtures/; run: cd #{app_dir} && mo run #{cfg.entry} --arvo-export-fixtures"
    )
  end
  try check_meta_sha(files, ".arvo/evidence/vitest-meta.json", cur_sha, "Vitest", repro)
  raw = try files.read_text(".arvo/evidence/vitest-report.json").map_error(
    fn(_) "missing .arvo/evidence/vitest-report.json; run: #{repro}" end
  )
  doc = try Json.parse(raw).map_error(fn(e) "corrupt vitest-report.json: #{e}" end)
  ok? = json_bool_at(doc, "success")
  passed = doc.int_at("numPassedTests") or 0
  failed = doc.int_at("numFailedTests") or 0
  if not ok? or failed != 0 or passed <= 0
    return Error("Vitest failed or ran 0 tests (success=#{ok?}, passed=#{passed}, failed=#{failed})")
  end
  Ok((passed, failed))
end

## Validates real Mo Inertia fixtures + Vitest RTL report against current build SHA.
fn run_vitest_phase(
  app_dir: Text,
  tier: Text,
  cfg: Config.ArvoConfig,
  files: ReadFiles,
  cmd: Command,
  clock: Clock,
  env: Env
) : Dossier.VerifyEvent
  t = clock.now
  fdir = trim_frontend_dir(cfg)
  return not_applicable_event(t, tier, "vitest_fixtures", fdir, clock) if not has_frontend_runner?(
    files,
    cfg
  )

  cur_sha = Control.compute_build_sha_in_app(app_dir, files, cfg, cmd, env)
  case validate_vitest_evidence(app_dir, cfg, files, cur_sha)
    Error(msg): fail_event(t, tier, "vitest_fixtures", msg, clock)
    Ok((passed, failed)):
      ms = elapsed_ms(clock, t)
      var ev = Dossier.new_event(t.to_text, tier, "vitest_fixtures", "pass", ms)
      ev.passed = Some(passed)
      ev.failed = Some(failed)
      ev.total = Some(passed)
      short_sha = Text.from_chars(cur_sha.chars.take(12))
      ev.detail = Some("#{passed} passed, 0 failed (build_sha=#{short_sha})")
      ev
  end
end

fn text_list_at(doc: Json, key: Text) : Option(List(Text))
  case doc.path(key)
    Some(Json.Array(items)):
      var out = []
      for it in items
        if it is Json.String(s)
          out = out.append(s)
        end
      end
      Some(out)
    Some(_) | None: None
  end
end

fn json_array_len(doc: Json, key: Text) : Result(Int, Text)
  case doc.path(key)
    Some(Json.Array(items)): Ok(items.size)
    Some(_) | None: Error("missing array field '#{key}' in e2e-report.json")
  end
end

## Validates one Playwright E2E report JSON and verifies every referenced screenshot/ARIA artifact exists.
fn validate_e2e_report(
  report_path: Text,
  cfg: Config.ArvoConfig,
  files: ReadFiles,
  cur_sha: Text
) : Result(E2eReportSummary, Text)
  raw = try files.read_text(report_path).map_error(fn(_) "missing #{report_path}" end)
  doc = try Json.parse(raw).map_error(fn(e) "corrupt #{report_path}: #{e}" end)
  rep_sha = doc.text_at("build_sha") or ""
  if rep_sha != cur_sha
    return Error("stale E2E report #{report_path} (got #{rep_sha}, expected #{cur_sha})")
  end
  if not json_bool_at(doc, "passed")
    return Error("Playwright E2E failed in #{report_path}")
  end
  c_err = try json_array_len(doc, "console_errors")
  p_err = try json_array_len(doc, "page_errors")
  h_err = try json_array_len(doc, "http_5xx")
  a_err = try json_array_len(doc, "broken_assets")
  axe_err = try json_array_len(doc, "axe_violations")
  if c_err > 0 or p_err > 0 or h_err > 0 or a_err > 0 or axe_err > 0
    return Error(
      "browser violations in #{report_path} (console=#{c_err}, page=#{p_err}, 5xx=#{h_err}, assets=#{a_err}, axe=#{axe_err})"
    )
  end

  db_checks = doc.int_at("db_checks_passed") or 0
  if db_checks <= 0
    return Error("missing @db-check persistence verification in #{report_path}")
  end
  diff_px = try doc.int_at("visual_diff_pixels").or_fail(
    "missing visual_diff_pixels in #{report_path}"
  )
  if diff_px < 0 or diff_px > cfg.visual_parity_max_diff_pixels
    return Error(
      "visual parity exceeded limit in #{report_path}: diff_pixels=#{diff_px} > max=#{cfg.visual_parity_max_diff_pixels}"
    )
  end
  if doc.path("visual_checks") is Some(Json.Array(vchecks))
    for vc in vchecks
      if json_bool_at(vc, "updated")
        lbl = vc.text_at("label") or "unknown"
        return Error(
          "visual parity baseline was updated (#{lbl}) in #{report_path}; re-run without --update-visual to verify parity"
        )
      end
    end
  end

  vps = try text_list_at(doc, "viewports").or_fail("missing viewports list in #{report_path}")
  for req_vp in cfg.viewports
    if not vps.contains?(req_vp.name)
      return Error("missing viewport '#{req_vp.name}' in #{report_path}")
    end
  end

  shots = try text_list_at(doc, "screenshots").or_fail("missing screenshots list in #{report_path}")
  if shots.empty?
    return Error("zero screenshots recorded in #{report_path}")
  end
  for s in shots
    if not files.exists?(s)
      return Error("missing screenshot evidence '#{s}' referenced by #{report_path}")
    end
  end

  arias = try text_list_at(doc, "aria_files").or_fail("missing aria_files list in #{report_path}")
  if arias.empty?
    return Error("zero ARIA snapshots recorded in #{report_path}")
  end
  for a in arias
    if not files.exists?(a)
      return Error("missing ARIA snapshot '#{a}' referenced by #{report_path}")
    end
  end

  scenarios = text_list_at(doc, "scenarios_passed") or []
  Ok(
    E2eReportSummary(
      report_path: report_path,
      viewports_seen: vps,
      scenarios_count: scenarios.size,
      db_checks_passed: db_checks,
      visual_diff_pixels: diff_px,
      screenshots_count: shots.size
    )
  )
end

## Verifies fresh `build_sha`-matching Playwright E2E report + screenshots + ARIA + axe + DB checks.
fn run_browser_e2e_phase(
  app_dir: Text,
  tier: Text,
  cfg: Config.ArvoConfig,
  files: ReadFiles,
  cmd: Command,
  clock: Clock,
  env: Env
) : Dossier.VerifyEvent
  t = clock.now
  fdir = trim_frontend_dir(cfg)
  return not_applicable_event(t, tier, "browser_e2e", fdir, clock) if not has_frontend_runner?(
    files,
    cfg
  )

  cur_sha = Control.compute_build_sha_in_app(app_dir, files, cfg, cmd, env)
  all_reports = list_files_recursive(files, ".arvo/evidence").filter(
    fn(p) p.ends_with?("/e2e-report.json") end
  ).map(fn(p) ".arvo/evidence/#{p}" end)
  if all_reports.empty?
    return fail_event(
      t,
      tier,
      "browser_e2e",
      "missing Playwright E2E evidence under .arvo/evidence/*/e2e-report.json; drive via `arvo control launch --app #{app_dir}` + `node ./scripts/arvo-playwright.mjs --mode drive`",
      clock
    )
  end

  # Select newest matching build_sha report, else report first validation error
  var matched = None
  var first_err = ""
  for rpath in all_reports.reverse
    case validate_e2e_report(rpath, cfg, files, cur_sha)
      Ok(sum):
        matched = Some(sum)
        break
      Error(msg):
        if first_err.empty?
          first_err = msg
        end
    end
  end

  case matched
    None: fail_event(t, tier, "browser_e2e", first_err, clock)
    Some(sum):
      ms = elapsed_ms(clock, t)
      var ev = Dossier.new_event(t.to_text, tier, "browser_e2e", "pass", ms)
      ev.passed = Some(sum.scenarios_count)
      ev.failed = Some(0)
      ev.total = Some(sum.scenarios_count)
      ev.detail = Some(
        "#{sum.scenarios_count} scenarios, viewports=#{sum.viewports_seen.join(",")}, db_checks=#{sum.db_checks_passed}, diff_px=#{sum.visual_diff_pixels}, shots=#{sum.screenshots_count}"
      )
      ev
  end
end

## Aggregates Stryker JSON mutant statuses (`Killed`+`Timeout` vs `Survived`+`NoCoverage`).
fn parse_stryker_report(raw: Text) : Result(StrykerSummary, Text)
  doc = try Json.parse(raw).map_error(fn(e) "corrupt stryker-report.json: #{e}" end)
  files_map = case doc.path("files")
    Some(Json.Object(m)): m
    Some(_) | None: return Error("missing 'files' object in stryker-report.json")
  end
  var killed = 0
  var survived = 0
  for (_fname, fdoc) in files_map
    muts = case fdoc.path("mutants")
      Some(Json.Array(items)): items
      Some(_) | None: []
    end
    for m in muts
      st = m.text_at("status") or ""
      if st == "Killed" or st == "Timeout"
        killed += 1
      else if st == "Survived" or st == "NoCoverage"
        survived += 1
      end
    end
  end
  total = killed + survived
  rate = if total == 0: 0.0 else: killed.to_float / total.to_float
  Ok(StrykerSummary(total: total, killed: killed, survived: survived, kill_rate: rate))
end

## Validates Stryker mutation score >= `ts_stryker_min_kill_rate` against current build SHA.
fn run_stryker_phase(
  app_dir: Text,
  tier: Text,
  cfg: Config.ArvoConfig,
  files: ReadFiles,
  cmd: Command,
  clock: Clock,
  env: Env
) : Dossier.VerifyEvent
  t = clock.now
  fdir = trim_frontend_dir(cfg)
  return not_applicable_event(t, tier, "stryker", fdir, clock) if not has_frontend_runner?(
    files,
    cfg
  )

  cur_sha = Control.compute_build_sha_in_app(app_dir, files, cfg, cmd, env)
  repro = "cd #{join_rel(app_dir, fdir)} && npm run stryker"
  if check_meta_sha(files, ".arvo/evidence/stryker-meta.json", cur_sha, "Stryker", repro) is
    Error(msg)
    return fail_event(t, tier, "stryker", msg, clock)
  end
  raw = case files.read_text(".arvo/evidence/stryker-report.json")
    Ok(s): s
    Error(_): return fail_event(
      t,
      tier,
      "stryker",
      "missing .arvo/evidence/stryker-report.json; run: #{repro}",
      clock
    )
  end
  sum = case parse_stryker_report(raw)
    Ok(s): s
    Error(e): return fail_event(t, tier, "stryker", e, clock)
  end
  ms = elapsed_ms(clock, t)
  ok? = sum.total > 0 and sum.kill_rate >= cfg.ts_stryker_min_kill_rate
  var ev = Dossier.new_event(t.to_text, tier, "stryker", if ok?: "pass" else: "fail", ms)
  ev.total = Some(sum.total)
  ev.killed = Some(sum.killed)
  ev.survived = Some(sum.survived)
  ev.kill_rate = Some(sum.kill_rate)
  ev.detail = Some("#{sum.killed}/#{sum.total} killed (rate=#{sum.kill_rate})")
  ev
end

test "FrontendCheck validates Vitest, Playwright E2E + visual/ARIA/DB evidence, and Stryker scores"
  t0 = Time.parse("2026-11-25T22:00:00Z") or stop "t0"
  assert elapsed_ms(Clock.fixed(t0 - 5.milliseconds), t0) == 0
  assert elapsed_ms(Clock.fixed(t0), t0) == 0
  assert elapsed_ms(Clock.fixed(t0 + 1.millisecond), t0) == 1
  assert elapsed_ms(Clock.fixed(t0 + 15.milliseconds), t0) == 15

  cfg = Config.default_config()
  long_sha = "sha_1234567890abcdef"
  rep_git = Command.fake(Command.replies([(Command.spec("git", ["rev-parse", "HEAD"]), Command.ok_output("#{long_sha}\n"))]))

  # No package.json -> not applicable (pass, never skipped)
  files_no_pkg = Files.in_memory({"arvo.toml": "[app]\nentry=\"main.mo\"\n"}).read_only
  for ev_na in [
    run_vitest_phase("examples/app", "feature", cfg, files_no_pkg, rep_git, Clock.fixed(t0), Env.of({})),
    run_browser_e2e_phase("examples/app", "feature", cfg, files_no_pkg, rep_git, Clock.fixed(t0), Env.of({})),
    run_stryker_phase("examples/app", "full", cfg, files_no_pkg, rep_git, Clock.fixed(t0), Env.of({}))
  ]
    assert ev_na.status == "pass"
    assert (ev_na.detail or "").contains?("not applicable")
  end

  good_vitest = "{\"success\":true,\"numPassedTests\":7,\"numFailedTests\":0}"
  good_stryker = """
    {"files":{
      "src/lib/format.ts":{"mutants":[{"status":"Killed"},{"status":"Timeout"},{"status":"Killed"},{"status":"Killed"},{"status":"Killed"}]},
      "src/pages/Home.tsx":{"mutants":[{"status":"Killed"},{"status":"Killed"},{"status":"Killed"},{"status":"Killed"},{"status":"Killed"},{"status":"Killed"},{"status":"Killed"},{"status":"Survived"},{"status":"NoCoverage"},{"status":"Ignored"}]}
    }}
    """
  good_e2e = """
    {
      "build_sha":"#{long_sha}",
      "passed":true,
      "viewports":["mobile","desktop"],
      "scenarios_passed":["auth","create","pay"],
      "console_errors":[],
      "page_errors":[],
      "http_5xx":[],
      "broken_assets":[],
      "axe_violations":[],
      "db_checks_passed":4,
      "visual_diff_pixels":0,
      "screenshots":[".arvo/evidence/r1/login-mobile.png"],
      "aria_files":[".arvo/evidence/r1/login-mobile.aria.txt"]
    }
    """
  files_ok = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/fixtures/Login/login_guest.json": "{}",
    ".arvo/evidence/vitest-meta.json": "{\"build_sha\":\"#{long_sha}\"}",
    ".arvo/evidence/vitest-report.json": good_vitest,
    ".arvo/evidence/stryker-meta.json": "{\"build_sha\":\"#{long_sha}\"}",
    ".arvo/evidence/stryker-report.json": good_stryker,
    ".arvo/evidence/r0/e2e-report.json": "{\"build_sha\":\"stale_old\",\"passed\":true}",
    ".arvo/evidence/r1/e2e-report.json": good_e2e,
    ".arvo/evidence/r1/login-mobile.png": "PNG",
    ".arvo/evidence/r1/login-mobile.aria.txt": "- heading"
  }).read_only

  v_ev = run_vitest_phase(".", "feature", cfg, files_ok, rep_git, Clock.fixed(t0), Env.of({}))
  assert v_ev.status == "pass" and v_ev.passed == Some(7) and v_ev.failed == Some(0) and v_ev.total == Some(7)
  assert v_ev.detail == Some("7 passed, 0 failed (build_sha=sha_12345678)")
  e_ev = run_browser_e2e_phase("examples/app", "feature", cfg, files_ok, rep_git, Clock.fixed(t0), Env.of({}))
  assert e_ev.status == "pass" and e_ev.passed == Some(3) and e_ev.failed == Some(0)
  assert (e_ev.detail or "").contains?("diff_px=0")
  s_ev = run_stryker_phase("examples/app", "full", cfg, files_ok, rep_git, Clock.fixed(t0), Env.of({}))
  assert s_ev.status == "pass" and s_ev.killed == Some(12) and s_ev.survived == Some(2) and s_ev.total == Some(14)

  # Boundary: Stryker statuses singly, exact 0.85 boundary, and 0 mutants under min=0.0
  assert parse_stryker_report("not-json") is Error(_)
  assert parse_stryker_report("{}") is Error(_)
  assert parse_stryker_report("{\"files\":{\"a.ts\":{\"other\":[]}}}") ==
    Ok(StrykerSummary(total: 0, killed: 0, survived: 0, kill_rate: 0.0))
  assert parse_stryker_report("{\"files\":{\"a.ts\":{\"mutants\":[{\"status\":\"Survived\"}]}}}") ==
    Ok(StrykerSummary(total: 1, killed: 0, survived: 1, kill_rate: 0.0))
  assert parse_stryker_report("{\"files\":{\"a.ts\":{\"mutants\":[{\"status\":\"NoCoverage\"}]}}}") ==
    Ok(StrykerSummary(total: 1, killed: 0, survived: 1, kill_rate: 0.0))
  assert parse_stryker_report("{\"files\":{\"a.ts\":{\"mutants\":[{\"status\":\"Ignored\"}]}}}") ==
    Ok(StrykerSummary(total: 0, killed: 0, survived: 0, kill_rate: 0.0))
  assert parse_stryker_report(
    "{\"files\":{\"a.ts\":{\"mutants\":[{\"status\":\"Killed\"},{\"status\":\"Survived\"}]}}}"
  ) ==
    Ok(StrykerSummary(total: 2, killed: 1, survived: 1, kill_rate: 0.5))

  # 17/20 == 0.85 exact boundary must PASS; 1/1 under min=0.0 passes while 0/0 under min=0.0 FAILS
  mut_exact = "#{"{\"status\":\"Killed\"},".repeat(17)}{\"status\":\"Survived\"},{\"status\":\"Survived\"},{\"status\":\"Survived\"}"
  f_exact_stk = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/evidence/stryker-meta.json": "{\"build_sha\":\"#{long_sha}\"}",
    ".arvo/evidence/stryker-report.json": "{\"files\":{\"a.ts\":{\"mutants\":[#{mut_exact}]}}}"
  }).read_only
  assert run_stryker_phase(".", "full", cfg, f_exact_stk, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "pass"

  assert Config.parse("[testing]\nts_stryker_min_kill_rate = 0.0\n") is Ok(cfg_zero)
  f_empty_stk = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/evidence/stryker-meta.json": "{\"build_sha\":\"#{long_sha}\"}",
    ".arvo/evidence/stryker-report.json": "{\"files\":{\"a.ts\":{\"mutants\":[]}}}"
  }).read_only
  assert run_stryker_phase(".", "full", cfg_zero, f_empty_stk, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "fail"
  f_one_stk = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/evidence/stryker-meta.json": "{\"build_sha\":\"#{long_sha}\"}",
    ".arvo/evidence/stryker-report.json": "{\"files\":{\"a.ts\":{\"mutants\":[{\"status\":\"Killed\"}]}}}"
  }).read_only
  assert run_stryker_phase(".", "full", cfg_zero, f_one_stk, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "pass"
  assert run_stryker_phase(".", "full", cfg, f_one_stk, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "pass"

  low_stryker = "{\"files\":{\"a.ts\":{\"mutants\":[{\"status\":\"Survived\"}]}}}"
  f_low_stk = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/evidence/stryker-meta.json": "{\"build_sha\":\"#{long_sha}\"}",
    ".arvo/evidence/stryker-report.json": low_stryker
  }).read_only
  assert run_stryker_phase(".", "full", cfg, f_low_stk, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "fail"

  # Vitest min boundary (1 passed, 0 failed, omitted numFailedTests) + repro cmd join_rel check
  f_vit_min = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/fixtures/a.json": "{}",
    ".arvo/evidence/vitest-meta.json": "{\"build_sha\":\"#{long_sha}\"}",
    ".arvo/evidence/vitest-report.json": "{\"success\":true,\"numPassedTests\":1}"
  }).read_only
  assert run_vitest_phase("examples/app", "feature", cfg, f_vit_min, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "pass"

  # Fail branches: missing fixtures (checks join_rel "." vs subdir), stale vitest meta, failing/missing vitest
  f_nofix = Files.in_memory({"frontend/package.json": "{}"}).read_only
  v_dot_fail = run_vitest_phase(".", "feature", cfg, f_nofix, rep_git, Clock.fixed(t0), Env.of({}))
  assert v_dot_fail.status == "fail"
  v_sub_fail = run_vitest_phase("examples/app", "feature", cfg, Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/fixtures/a.json": "{}"
  }).read_only, rep_git, Clock.fixed(t0), Env.of({}))
  assert v_sub_fail.status == "fail" and (v_sub_fail.detail or "").contains?("cd examples/app/frontend &&")
  v_root_fail = run_vitest_phase(".", "feature", cfg, Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/fixtures/a.json": "{}"
  }).read_only, rep_git, Clock.fixed(t0), Env.of({}))
  assert v_root_fail.status == "fail" and (v_root_fail.detail or "").contains?("cd frontend &&")
  assert run_browser_e2e_phase(".", "feature", cfg, f_nofix, rep_git, Clock.fixed(t0), Env.of({}))
    .status ==
    "fail"
  assert run_stryker_phase(".", "full", cfg, f_nofix, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "fail"

  f_stale_v = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/fixtures/a.json": "{}",
    ".arvo/evidence/vitest-meta.json": "{\"build_sha\":\"wrong\"}",
    ".arvo/evidence/vitest-report.json": good_vitest
  }).read_only
  assert run_vitest_phase(".", "feature", cfg, f_stale_v, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "fail"

  for bad_vit in [
    "{}",
    "{\"success\":\"yes\",\"numPassedTests\":7,\"numFailedTests\":0}",
    "{\"success\":false,\"numPassedTests\":7,\"numFailedTests\":0}",
    "{\"success\":true,\"numFailedTests\":0}",
    "{\"success\":true,\"numPassedTests\":7,\"numFailedTests\":1}",
    "{\"success\":true,\"numPassedTests\":0,\"numFailedTests\":0}",
    "not-json"
  ]
    f_bv = Files.in_memory({
      "frontend/package.json": "{}",
      ".arvo/fixtures/a.json": "{}",
      ".arvo/evidence/vitest-meta.json": "{\"build_sha\":\"#{long_sha}\"}",
      ".arvo/evidence/vitest-report.json": bad_vit
    }).read_only
    assert run_vitest_phase(".", "feature", cfg, f_bv, rep_git, Clock.fixed(t0), Env.of({})).status ==
      "fail"
  end

  f_no_vitrep = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/fixtures/a.json": "{}",
    ".arvo/evidence/vitest-meta.json": "{\"build_sha\":\"#{long_sha}\"}"
  }).read_only
  assert run_vitest_phase(".", "feature", cfg, f_no_vitrep, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "fail"

  f_no_stkrep = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/evidence/stryker-meta.json": "{\"build_sha\":\"#{long_sha}\"}"
  }).read_only
  assert run_stryker_phase(".", "full", cfg, f_no_stkrep, rep_git, Clock.fixed(t0), Env.of({})).status ==
    "fail"
  assert run_stryker_phase(
    ".",
    "full",
    cfg,
    Files.in_memory({
      "frontend/package.json": "{}",
      ".arvo/evidence/stryker-meta.json": "{\"build_sha\":\"#{long_sha}\"}",
      ".arvo/evidence/stryker-report.json": "bad-json"
    }).read_only,
    rep_git,
    Clock.fixed(t0),
    Env.of({})
  ).status ==
    "fail"

  # Complete E2E failure branches: each case isolates ONE violated condition against otherwise valid fields
  e2e_base = {
    "build_sha": Json.String(long_sha),
    "passed": Json.Boolean(true),
    "console_errors": Json.Array([]),
    "page_errors": Json.Array([]),
    "http_5xx": Json.Array([]),
    "broken_assets": Json.Array([]),
    "axe_violations": Json.Array([]),
    "db_checks_passed": Json.int(1),
    "visual_diff_pixels": Json.int(0),
    "viewports": Json.Array([Json.String("mobile"), Json.String("desktop")]),
    "screenshots": Json.Array([Json.String(".arvo/evidence/r1/login-mobile.png")]),
    "aria_files": Json.Array([Json.String(".arvo/evidence/r1/login-mobile.aria.txt")])
  }
  bad_e2es = [
    "not-json",
    Json.Object(e2e_base.set("build_sha", Json.String("other"))).to_text,
    Json.Object(e2e_base.set("passed", Json.Boolean(false))).to_text,
    Json.Object(e2e_base.set("console_errors", Json.Array([Json.String("e")]))).to_text,
    Json.Object(e2e_base.set("page_errors", Json.Array([Json.String("p")]))).to_text,
    Json.Object(e2e_base.set("http_5xx", Json.Array([Json.String("500")]))).to_text,
    Json.Object(e2e_base.set("broken_assets", Json.Array([Json.String("404")]))).to_text,
    Json.Object(e2e_base.set("axe_violations", Json.Array([Json.Object({})]))).to_text,
    Json.Object(e2e_base.set("db_checks_passed", Json.int(0))).to_text,
    Json.Object(e2e_base.remove("db_checks_passed")).to_text,
    Json.Object(e2e_base.remove("visual_diff_pixels")).to_text,
    Json.Object(e2e_base.set("visual_diff_pixels", Json.int(-1))).to_text,
    Json.Object(e2e_base.set("visual_diff_pixels", Json.int(1))).to_text,
    Json.Object(
      e2e_base.set(
        "visual_checks",
        Json.Array([
          Json.Object({
            "label": Json.String("home-desktop"),
            "diffPixels": Json.int(0),
            "updated": Json.Boolean(true)
          })
        ])
      )
    ).to_text,
    Json.Object(e2e_base.set("viewports", Json.Array([Json.String("mobile")]))).to_text,
    Json.Object(e2e_base.set("screenshots", Json.Array([]))).to_text,
    Json.Object(e2e_base.set("screenshots", Json.Array([Json.String(".arvo/evidence/r1/missing.png")])))
      .to_text,
    Json.Object(e2e_base.set("aria_files", Json.Array([]))).to_text,
    Json.Object(e2e_base.set("aria_files", Json.Array([Json.String(".arvo/evidence/r1/missing.aria.txt")])))
      .to_text
  ]
  for bad_e in bad_e2es
    f_be = Files.in_memory({
      "frontend/package.json": "{}",
      ".arvo/evidence/r1/e2e-report.json": bad_e,
      ".arvo/evidence/r1/login-mobile.png": "PNG",
      ".arvo/evidence/r1/login-mobile.aria.txt": "- heading"
    }).read_only
    assert run_browser_e2e_phase(".", "feature", cfg, f_be, rep_git, Clock.fixed(t0), Env.of({})).status ==
      "fail"
  end
  # Also assert exact minimum db_checks_passed == 1 and visual_diff_pixels == 0 PASSES
  f_min_e2e = Files.in_memory({
    "frontend/package.json": "{}",
    ".arvo/evidence/r1/e2e-report.json": Json.Object(e2e_base).to_text,
    ".arvo/evidence/r1/login-mobile.png": "PNG",
    ".arvo/evidence/r1/login-mobile.aria.txt": "- heading"
  }).read_only
  assert run_browser_e2e_phase(".", "feature", cfg, f_min_e2e, rep_git, Clock.fixed(t0), Env.of({}))
    .status ==
    "pass"
  assert validate_e2e_report(".arvo/evidence/absent.json", cfg, files_ok, long_sha) is Error(_)
end
