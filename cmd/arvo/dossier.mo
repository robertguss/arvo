## NDJSON `verify.jsonl` event formatter, `mo test --json` parser, and terminal scorecard renderer.
module Dossier
expose VerifyEvent(..),
MoTestSummary(..),
MoStrengthSummary(..),
DecisionRow(..),
new_event,
event_to_json,
parse_mo_test_json,
parse_mo_strength_json,
render_scorecard,
sanitize_tsv_cell,
decisions_header,
format_decision_row,
append_decision,
parse_decisions_tsv
use Json

## Machine-readable event emitted to `.arvo/dossier/verify.jsonl` and `--json` stdout.
struct VerifyEvent
  ts: Text
  tier: Text
  phase: Text
  status: Text
  ms: Int
  detail: Option(Text)
  pages_checked: Option(Int)
  passed: Option(Int)
  failed: Option(Int)
  total: Option(Int)
  killed: Option(Int)
  survived: Option(Int)
  kill_rate: Option(Float)
  modified_contracts: Option(List(Text))
end

## Aggregated counts parsed from `mo test --json [--mutants]`.
struct MoTestSummary
  passed: Int
  failed: Int
  stopped: Int
  errors: Int
  has_mutants?: Bool
  mutants_total: Int
  mutants_killed: Int
  mutants_survived: Int
  kill_rate: Float
  surviving_locations: List(Text)
end

## Aggregated intent-strength metrics parsed from `mo test --json --strength`.
struct MoStrengthSummary
  original_passed?: Bool
  scored: Int
  killed: Int
  survived: Int
  invalid: Int
  kill_rate: Float
  surviving_versions: List(Text)
  invalid_versions: List(Text)
end

## Constructs a baseline `VerifyEvent` with optional metrics set to `None`.
fn new_event(ts: Text, tier: Text, phase: Text, status: Text, ms: Int) : VerifyEvent
  VerifyEvent(
    ts: ts,
    tier: tier,
    phase: phase,
    status: status,
    ms: ms,
    detail: None,
    pages_checked: None,
    passed: None,
    failed: None,
    total: None,
    killed: None,
    survived: None,
    kill_rate: None,
    modified_contracts: None
  )
end

## Formats one `VerifyEvent` as compact single-line JSON matching Spec Part 6.1.
fn event_to_json(ev: VerifyEvent) : Text
  var obj = {
    "ts": Json.String(ev.ts),
    "tier": Json.String(ev.tier),
    "phase": Json.String(ev.phase),
    "status": Json.String(ev.status)
  }
  if ev.pages_checked is Some(n)
    obj = obj.set("pages_checked", Json.int(n))
  end
  if ev.passed is Some(n)
    obj = obj.set("passed", Json.int(n))
  end
  if ev.failed is Some(n)
    obj = obj.set("failed", Json.int(n))
  end
  if ev.total is Some(n)
    obj = obj.set("total", Json.int(n))
  end
  if ev.killed is Some(n)
    obj = obj.set("killed", Json.int(n))
  end
  if ev.survived is Some(n)
    obj = obj.set("survived", Json.int(n))
  end
  if ev.kill_rate is Some(r)
    if Json.float(r) is Some(jr)
      obj = obj.set("kill_rate", jr)
    end
  end
  if ev.modified_contracts is Some(mods)
    obj = obj.set("modified_contracts", mods.to_json)
  end
  if ev.detail is Some(d)
    obj = obj.set("detail", Json.String(d))
  end
  obj = obj.set("ms", Json.int(ev.ms))
  Json.Object(obj).to_text
end

## Parses NDJSON output from `mo test --json` or `mo test --json --mutants`.
fn parse_mo_test_json(ndjson: Text) : MoTestSummary
  var passed = 0
  var failed = 0
  var stopped = 0
  var errors = 0
  var has_mutants? = false
  var m_total = 0
  var m_killed = 0
  var m_survived = 0
  var m_rate = 1.0
  var survivors = []

  for raw in ndjson.lines
    trimmed = raw.trim
    continue if not trimmed.starts_with?("{")
    case Json.parse(trimmed)
      Error(_): continue
      Ok(doc):
        rec = doc.text_at("record") or ""
        ev = doc.text_at("event") or ""
        if ev == "mutant_survived"
          f = doc.text_at("file") or ""
          ln = doc.int_at("line") or 0
          fn_name = doc.text_at("fn") or ""
          survivors = survivors.append("#{f}:#{ln} (#{fn_name})")
        else if ev == "mutant_summary"
          has_mutants? = true
          m_total = case doc.int_at("tried")
            Some(n): n
            None: doc.int_at("total") or 0
          end
          m_killed = doc.int_at("killed") or 0
          m_survived = doc.int_at("survived") or 0
          if doc.path("kill_rate") is Some(Json.Number(jn))
            m_rate = jn.to_float or m_rate
          end
        else if rec == "totals"
          passed = doc.int_at("passed") or passed
          failed = doc.int_at("failed") or failed
          stopped = doc.int_at("stopped") or stopped
          errors = doc.int_at("errors") or errors
        end
    end
  end

  MoTestSummary(
    passed: passed,
    failed: failed,
    stopped: stopped,
    errors: errors,
    has_mutants?: has_mutants?,
    mutants_total: m_total,
    mutants_killed: m_killed,
    mutants_survived: m_survived,
    kill_rate: m_rate,
    surviving_locations: survivors
  )
end

## Parses NDJSON output from `mo test --json --strength DIR TARGET`.
fn parse_mo_strength_json(ndjson: Text) : MoStrengthSummary
  var orig_ok? = false
  var scored = 0
  var killed = 0
  var survived = 0
  var invalid = 0
  var rate = 0.0
  var surv_names = []
  var inv_names = []

  for raw in ndjson.lines
    trimmed = raw.trim
    continue if not trimmed.starts_with?("{")
    case Json.parse(trimmed)
      Error(_): continue
      Ok(doc):
        rec = doc.text_at("record") or ""
        if rec == "strength"
          orig_ok? = doc.text_at("original") == Some("passed")
          c_inv = doc.int_at("counts.invalid") or 0
          c_chg = doc.int_at("counts.changes_intent") or 0
          c_def = doc.int_at("counts.defect") or 0
          invalid = c_inv + c_chg + c_def
        else if rec == "strength_case"
          nm = doc.text_at("name") or ""
          out = doc.text_at("outcome") or ""
          if out == "survived"
            surv_names = surv_names.append(nm)
          else if out == "invalid" or out == "defect" or out == "changes_intent"
            inv_names = inv_names.append(nm)
          end
        else if rec == "strength_summary"
          orig_ok? = doc.text_at("original") == Some("passed")
          scored = doc.int_at("scored") or 0
          killed = doc.int_at("killed") or 0
          survived = doc.int_at("survived") or 0
          if doc.path("kill_rate") is Some(Json.Number(jn))
            rate = jn.to_float or 0.0
          end
        end
    end
  end

  MoStrengthSummary(
    original_passed?: orig_ok?,
    scored: scored,
    killed: killed,
    survived: survived,
    invalid: invalid,
    kill_rate: rate,
    surviving_versions: surv_names,
    invalid_versions: inv_names
  )
end

fn status_badge(status: Text) : Text
  if status == "pass"
    "PASS"
  else if status == "warn"
    "WARN"
  else if status == "skipped"
    "SKIP"
  else
    "FAIL"
  end
end

## Renders a concise terminal verification scorecard for `arvo verify`.
fn render_scorecard(tier: Text, events: List(VerifyEvent), total_ms: Int) : Text
  has_fail? = events.any?(fn(e) e.status == "fail" end)
  has_warn? = events.any?(fn(e) e.status == "warn" end)
  verdict = if has_fail?
    "FAIL"
  else if has_warn?
    "PASS WITH CONTRACT CHANGES"
  else
    "PASS"
  end

  var lines = ["Arvo Verify [tier=#{tier}] => #{verdict} (#{total_ms} ms)"]
  for ev in events
    badge = status_badge(ev.status)
    extra = case ev.detail
      Some(d): " — #{d}"
      None: ""
    end
    lines = lines.append("  [#{badge}] #{ev.phase} (#{ev.ms} ms)#{extra}")
  end
  lines.join("\n")
end

## One append-only decision checkpoint stored in `.arvo/dossier/decisions.tsv`.
struct DecisionRow
  ts: Text
  phase: Text
  decision: Text
  why: Text
  evidence: Text
  result: Text
end

## Strips tabs/newlines and neutralizes leading spreadsheet formula prefixes (`=`, `+`, `-`, `@`).
fn sanitize_tsv_cell(s: Text) : Text
  cleaned = s.replace("\t", " ").replace("\r", " ").replace("\n", " ").trim
  if cleaned.starts_with?("=") or
    cleaned.starts_with?("+") or
    cleaned.starts_with?("-") or
    cleaned.starts_with?("@")
    "'#{cleaned}"
  else
    cleaned
  end
end

## Returns the header line for `.arvo/dossier/decisions.tsv`.
fn decisions_header() : Text
  "ts\tphase\tdecision\twhy\tevidence\tresult\n"
end

## Formats one sanitized `DecisionRow` as a single TSV line ending with `\n`.
fn format_decision_row(row: DecisionRow) : Text
  fields = [
    sanitize_tsv_cell(row.ts),
    sanitize_tsv_cell(row.phase),
    sanitize_tsv_cell(row.decision),
    sanitize_tsv_cell(row.why),
    sanitize_tsv_cell(row.evidence),
    sanitize_tsv_cell(row.result)
  ]
  "#{fields.join("\t")}\n"
end

## Appends one sanitized decision row to `.arvo/dossier/decisions.tsv`, writing the header if new.
fn append_decision(app_files: Files, row: DecisionRow) : Result(Unit, Text)
  _mk = try app_files.make_folder(".arvo/dossier").map_error(fn(e) "#{e}" end)
  tsv_path = ".arvo/dossier/decisions.tsv"
  line = format_decision_row(row)
  if app_files.exists?(tsv_path)
    app_files.append_text(tsv_path, line).map_error(fn(e) "#{e}" end)
  else
    app_files.write_text(tsv_path, "#{decisions_header()}#{line}").map_error(fn(e) "#{e}" end)
  end
end

## Parses `.arvo/dossier/decisions.tsv`, skipping blank lines and the header row.
fn parse_decisions_tsv(raw: Text) : List(DecisionRow)
  var out = []
  for line in raw.lines
    continue if line.trim.empty? or line.starts_with?("ts\t")
    parts = line.split("\t")
    out = out.append(
      DecisionRow(
        ts: parts.get(0) or "",
        phase: parts.get(1) or "",
        decision: parts.get(2) or "",
        why: parts.get(3) or "",
        evidence: parts.get(4) or "",
        result: parts.get(5) or ""
      )
    )
  end
  out
end

test "Dossier formats Spec 6.1 NDJSON events, parses mo test --json --mutants, and renders scorecards"
  var ev1 = new_event("2026-11-25T15:02:01Z", "fast", "contracts", "pass", 180)
  ev1.pages_checked = Some(2)
  j1 = event_to_json(ev1)
  assert Json.parse(j1) is Ok(p1)
  assert p1.text_at("phase") == Some("contracts")
  assert p1.int_at("pages_checked") == Some(2)

  var ev2 = new_event("2026-11-25T15:02:10Z", "full", "mo_mutants", "fail", 500)
  ev2.total = Some(10)
  ev2.killed = Some(9)
  ev2.survived = Some(1)
  ev2.kill_rate = Some(0.9)
  ev2.detail = Some("1 surviving mutant")
  j2 = event_to_json(ev2)
  assert j2.contains?("\"kill_rate\":0.9")

  var ev3 = new_event("2026-11-25T15:02:11Z", "fast", "tamper_check", "warn", 12)
  ev3.modified_contracts = Some(["specs/features/bills.feature.md"])
  assert event_to_json(ev3).contains?("specs/features/bills.feature.md")

  var ev4 = new_event("2026-11-25T15:02:12Z", "feature", "browser_e2e", "skipped", 0)
  ev4.detail = Some("pending Phase 3+")

  ndjson = """
    {"record":"version","format":"1.0","mo":"0.3.0","command":"test"}
    {"record":"mutant_survived","event":"mutant_survived","file":"routes.mo","line":42,"fn":"pay"}
    {"record":"mutant_summary","event":"mutant_summary","total":10,"tried":10,"killed":9,"survived":1,"kill_rate":0.9}
    {"record":"totals","errors":1,"passed":8,"failed":0,"stopped":0,"status":1}
    """
  parsed = parse_mo_test_json(ndjson)
  assert parsed.has_mutants?
  assert parsed.passed == 8 and parsed.failed == 0 and parsed.stopped == 0 and parsed.errors == 1
  assert parsed.mutants_total == 10 and parsed.mutants_killed == 9 and parsed.mutants_survived == 1
  assert parsed.kill_rate == 0.9
  assert parsed.surviving_locations == ["routes.mo:42 (pay)"]

  empty_p = parse_mo_test_json("")
  assert empty_p.passed == 0 and
    empty_p.failed == 0 and
    empty_p.stopped == 0 and
    empty_p.errors == 0
  assert not empty_p.has_mutants?
  assert empty_p.mutants_total == 0 and
    empty_p.mutants_killed == 0 and
    empty_p.mutants_survived == 0
  assert empty_p.kill_rate == 1.0

  fallback_ndjson = """
    {"record":"mutant_survived","event":"mutant_survived"}
    {"record":"mutant_summary","event":"mutant_summary","total":4}
    {"record":"totals","passed":0,"failed":1,"stopped":2,"errors":0}
    """
  fb = parse_mo_test_json(fallback_ndjson)
  assert fb.surviving_locations == [":0 ()"]
  assert fb.mutants_total == 4 and fb.mutants_killed == 0 and fb.mutants_survived == 0
  assert fb.failed == 1 and fb.stopped == 2

  fb_zero = parse_mo_test_json("{\"record\":\"mutant_summary\",\"event\":\"mutant_summary\"}")
  assert fb_zero.has_mutants? and fb_zero.mutants_total == 0

  assert render_scorecard("fast", [ev1], 180).contains?("=> PASS (180 ms)")
  assert render_scorecard("fast", [ev1, ev3], 192).contains?("=> PASS WITH CONTRACT CHANGES")
  sc_fail = render_scorecard("full", [ev1, ev2, ev4], 680)
  assert sc_fail.contains?("=> FAIL (680 ms)")
  assert sc_fail.contains?("[SKIP] browser_e2e")

  str_pass_ndjson = """
    {"record":"version","format":"1.0","mo":"0.3.0","command":"test"}
    {"record":"strength","version":2,"set":"strength/arvo_csrf","original":"passed","counts":{"invalid":0,"changes_intent":0,"defect":0}}
    {"record":"strength_case","event":"strength_case","name":"01.mo","outcome":"killed_by_example","killed":true,"scored":true}
    {"record":"strength_summary","event":"strength_summary","set":"strength/arvo_csrf","original":"passed","scored":2,"killed":2,"survived":0,"kill_rate":1.0}
    """
  sp = parse_mo_strength_json(str_pass_ndjson)
  assert sp.original_passed? and
    sp.scored == 2 and
    sp.killed == 2 and
    sp.survived == 0 and
    sp.invalid == 0
  assert sp.kill_rate == 1.0 and sp.surviving_versions.empty? and sp.invalid_versions.empty?

  str_fail_ndjson = """
    not-json
    {"record":"strength","version":2,"original":"passed","counts":{"invalid":1,"changes_intent":1,"defect":1}}
    {"record":"strength_case","event":"strength_case","name":"bad_surv.mo","outcome":"survived"}
    {"record":"strength_case","event":"strength_case","name":"bad_inv.mo","outcome":"invalid"}
    {"record":"strength_case","event":"strength_case","name":"bad_def.mo","outcome":"defect"}
    {"record":"strength_case","event":"strength_case","name":"bad_int.mo","outcome":"changes_intent"}
    {"record":"strength_summary","event":"strength_summary","original":"failed","scored":1,"killed":0,"survived":1,"kill_rate":null}
    """
  sf = parse_mo_strength_json(str_fail_ndjson)
  assert not sf.original_passed? and
    sf.invalid == 3 and
    sf.scored == 1 and
    sf.survived == 1 and
    sf.kill_rate == 0.0
  assert sf.surviving_versions == ["bad_surv.mo"]
  assert sf.invalid_versions == ["bad_inv.mo", "bad_def.mo", "bad_int.mo"]

  empty_s = parse_mo_strength_json("")
  assert not empty_s.original_passed? and
    empty_s.scored == 0 and
    empty_s.killed == 0 and
    empty_s.survived == 0 and
    empty_s.invalid == 0 and
    empty_s.kill_rate == 0.0

  only_hdr = parse_mo_strength_json(
    "{\"record\":\"strength\",\"original\":\"passed\"}\n{\"record\":\"totals\",\"original\":\"failed\",\"scored\":9,\"killed\":9,\"survived\":9}\n"
  )
  assert only_hdr.original_passed? and only_hdr.invalid == 0 and only_hdr.scored == 0

  zero_sum = parse_mo_strength_json("{\"record\":\"strength_summary\"}\n")
  assert not zero_sum.original_passed? and
    zero_sum.scored == 0 and
    zero_sum.killed == 0 and
    zero_sum.survived == 0

  assert sanitize_tsv_cell("  a\tb\rc\nd  ") == "a b c d"
  assert sanitize_tsv_cell("=CMD()") == "'=CMD()"
  assert sanitize_tsv_cell("+1+2") == "'+1+2"
  assert sanitize_tsv_cell("-rf") == "'-rf"
  assert sanitize_tsv_cell("@SUM(A1)") == "'@SUM(A1)"
  assert decisions_header() == "ts\tphase\tdecision\twhy\tevidence\tresult\n"

  f_dec = Files.in_memory({})
  r1 = DecisionRow(
    ts: "2026-11-25T23:45:00Z",
    phase: "verify",
    decision: "Run\tfull",
    why: "=calc",
    evidence: "verify.jsonl",
    result: "pass"
  )
  r2 = DecisionRow(
    ts: "2026-11-25T23:46:00Z",
    phase: "release",
    decision: "Approve",
    why: "+all green",
    evidence: "index.html",
    result: "pass"
  )
  assert append_decision(f_dec, r1) == Ok(Unit)
  assert append_decision(f_dec, r2) == Ok(Unit)
  assert f_dec.read_text(".arvo/dossier/decisions.tsv") is Ok(tsv_txt)
  assert tsv_txt ==
    "ts\tphase\tdecision\twhy\tevidence\tresult\n2026-11-25T23:45:00Z\tverify\tRun full\t'=calc\tverify.jsonl\tpass\n2026-11-25T23:46:00Z\trelease\tApprove\t'+all green\tindex.html\tpass\n"

  parsed_rows = parse_decisions_tsv("\n  \n#{tsv_txt}t3\tp3\n")
  assert parsed_rows == [
    DecisionRow(
      ts: "2026-11-25T23:45:00Z",
      phase: "verify",
      decision: "Run full",
      why: "'=calc",
      evidence: "verify.jsonl",
      result: "pass"
    ),
    DecisionRow(
      ts: "2026-11-25T23:46:00Z",
      phase: "release",
      decision: "Approve",
      why: "'+all green",
      evidence: "index.html",
      result: "pass"
    ),
    DecisionRow(ts: "t3", phase: "p3", decision: "", why: "", evidence: "", result: "")
  ]
  assert parse_decisions_tsv("") == []

  f_blk_dec = Files.in_memory({".arvo": "blocker"})
  assert append_decision(f_blk_dec, r1) is Error(_)
  f_dir_dec = Files.in_memory({".arvo/dossier/decisions.tsv/sub": "dir"})
  assert append_decision(f_dir_dec, r1) is Error(_)
end
