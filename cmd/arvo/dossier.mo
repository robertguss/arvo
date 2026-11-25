## NDJSON `verify.jsonl` event formatter, `mo test --json` parser, and terminal scorecard renderer.
module Dossier
expose VerifyEvent(..),
MoTestSummary(..),
new_event,
event_to_json,
parse_mo_test_json,
render_scorecard
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
end
