## Unified Executable Feature Map (`.feature.md`) parser, in-memory `WebTest` runner,
## and `@browser` JSON manifest exporter for Phase 3 Playwright execution.
module Arvo.Feature
expose StepKind(..),
Step(..),
Scenario(..),
FeatureDoc(..),
ParseError(..),
StepBinding(..),
ScenarioResult(..),
RunReport(..),
BrowserScenarioManifest(..),
parse,
match_pattern,
run_feature,
browser_manifest,
browser_manifest_json,
format_report
use Api
use Arvo.Fixtures.FeatureApp
use Arvo.WebTest
use Json

## Canonical Gherkin step role (`And`/`But` inherit the preceding step's kind).
enum StepKind
  Given
  When
  Then
end

## One parsed Gherkin step with optional attached pipe data table.
struct Step
  kind: StepKind
  raw_keyword: Text
  text: Text
  table: List(List(Text))
  line: Int
end

## One executable scenario extracted from a `## Scenarios` fenced `gherkin` block.
struct Scenario
  name: Text
  tags: List(Text)
  steps: List(Step)
  line: Int
end

## Fully parsed `.feature.md` Executable Feature Map enforcing the 4-H2 contract.
struct FeatureDoc
  path: Text
  title: Text
  feature_name: Text
  sub_features: List(Text)
  entry_points: List(Text)
  gotchas: List(Text)
  background: List(Step)
  scenarios: List(Scenario)
end

## Structural or Gherkin parse failure inside a `.feature.md` file.
struct ParseError
  path: Text
  line: Int
  message: Text
end

## Typed step binding matching `pattern` (`{param}` placeholders) and running against `WebTest.Session` + `ApiTest.App`.
struct StepBinding(W)
  kind: Option(StepKind)
  pattern: Text
  handler: fn(
    W,
    WebTest.Session,
    Map(Text, Text),
    List(List(Text)),
    Sqlite.Database,
    Clock,
    SecureRandom,
    Env,
    ApiTest.App
  ) : Result((W, WebTest.Session), Text)
end

## Execution outcome of one scenario.
struct ScenarioResult
  feature_path: Text
  scenario_name: Text
  tags: List(Text)
  passed?: Bool
  steps_run: Int
  error: Option(Text)
end

## Aggregate execution report over all matched scenarios in a feature run.
struct RunReport
  total: Int
  passed: Int
  failed: Int
  results: List(ScenarioResult)
end

## Structured `@browser` scenario descriptor exported for Phase 3 Playwright drivers.
struct BrowserScenarioManifest
  feature_path: Text
  feature_title: Text
  scenario_name: Text
  tags: List(Text)
  background: List(Step)
  steps: List(Step)
end

fn split_pattern_tokens(pattern: Text) : List((Bool, Text))
  var tokens = []
  var cur = []
  var in_param = false
  for ch in pattern.chars
    if not in_param and ch == '{'
      lit = Text.from_chars(cur)
      if not lit.empty?
        tokens = tokens.append((false, lit))
      end
      cur = []
      in_param = true
    else if in_param and ch == '}'
      pname = Text.from_chars(cur)
      tokens = tokens.append((true, pname))
      cur = []
      in_param = false
    else
      cur = cur.append(ch)
    end
  end
  tail = Text.from_chars(cur)
  if not tail.empty?
    tokens = tokens.append((in_param, tail))
  end
  tokens
end

## Matches a step `pattern` containing `{param}` placeholders against `text`.
fn match_pattern(pattern: Text, text: Text) : Option(Map(Text, Text))
  examples
    match_pattern("seed profile \"{name}\"", "seed profile \"baseline\"") ==
      Some({"name": "baseline"})
    match_pattern("I visit \"{path}\"", "I visit \"/bills?status=due\"") ==
      Some({"path": "/bills?status=due"})
    match_pattern("bill \"{name}\" shows \"{st}\"", "bill \"Gas & Power\" shows \"due\"") ==
      Some({"name": "Gas & Power", "st": "due"})
    match_pattern("I reload the page", "I reload the page") == Some({})
    match_pattern("I reload the page", "I leave the page") == None
    match_pattern("status is {code}", "status is 409") == Some({"code": "409"})
    match_pattern("{a}{b}", "ab") == None
  end

  tokens = split_pattern_tokens(pattern)
  var rest = text
  var captures = {}

  for (ti, token) in tokens.enumerate
    (is_param?, tok) = token
    if not is_param?
      rest = try rest.drop_prefix(tok)
    else
      case tokens.get(ti + 1)
        None:
          captures = captures.set(tok, rest)
          rest = ""
        Some((next_is_param?, next_lit)):
          return None if next_is_param? or not rest.contains?(next_lit)
          val = rest.split(next_lit).first or ""
          captures = captures.set(tok, val)
          rest = rest.drop_prefix(val) or ""
      end
    end
  end

  return None if not rest.empty?
  Some(captures)
end

fn parse_table_row(line: Text) : List(Text)
  inner = (line.trim.drop_prefix("|") or "").drop_suffix("|") or line.trim
  inner.split("|").map(fn(cell) cell.trim end)
end

fn parse_step_line(trimmed: Text, prev_kind: Option(StepKind)) : Option((StepKind, Text, Text))
  if trimmed.drop_prefix("Given ") is Some(rest)
    Some((Given, "Given", rest.trim))
  else if trimmed.drop_prefix("When ") is Some(rest)
    Some((When, "When", rest.trim))
  else if trimmed.drop_prefix("Then ") is Some(rest)
    Some((Then, "Then", rest.trim))
  else if trimmed.drop_prefix("And ") is Some(rest)
    case prev_kind
      Some(k): Some((k, "And", rest.trim))
      None: None
    end
  else if trimmed.drop_prefix("But ") is Some(rest)
    case prev_kind
      Some(k): Some((k, "But", rest.trim))
      None: None
    end
  else
    None
  end
end

enum FenceState
  FenceClosed
  FenceOpen(lang: Text, start_line: Int, lines: List(Text))
end

fn parse_gherkin_block(path: Text, start_line: Int, lines: List(Text)) : Result(
  (Text, List(Step), List(Scenario)),
  ParseError
)
  var feature_name = ""
  var background = []
  var scenarios = []
  var in_background? = false
  var cur_scen = None
  var cur_steps = []
  var pending_tags = []
  var prev_kind = None

  flush_scenario = fn(sc_opt, sc_steps, existing)
    case sc_opt
      Some((sname, sc_tags, sc_line)):
        if sc_steps.empty?
          Error(ParseError(path: path, line: sc_line, message: "Scenario '#{sname}' contains no steps"))
        else
          Ok(existing.append(Scenario(name: sname, tags: sc_tags, steps: sc_steps, line: sc_line)))
        end
      None: Ok(existing)
    end
  end

  for (offset, raw_line) in lines.enumerate
    lnum = start_line + offset
    trimmed = raw_line.trim
    continue if trimmed.empty? or trimmed.starts_with?("#")

    if trimmed.drop_prefix("Feature:") is Some(fname)
      feature_name = fname.trim
      continue
    end

    if trimmed.starts_with?("@")
      tags = trimmed.words.filter(fn(w) w.starts_with?("@") end)
      pending_tags = pending_tags.concat(tags)
      continue
    end

    if trimmed == "Background:"
      if not pending_tags.empty?
        return Error(ParseError(path: path, line: lnum, message: "tags cannot precede Background:"))
      end
      if in_background? or cur_scen is Some(_) or not scenarios.empty?
        return Error(
          ParseError(
            path: path,
            line: lnum,
            message: "Background: must appear before any Scenario: and at most once"
          )
        )
      end
      in_background? = true
      prev_kind = None
      continue
    end

    if trimmed.drop_prefix("Scenario:") is Some(sname)
      if in_background?
        background = cur_steps
        in_background? = false
      else
        scenarios = try flush_scenario(cur_scen, cur_steps, scenarios)
      end
      clean_name = sname.trim
      if clean_name.empty?
        return Error(ParseError(path: path, line: lnum, message: "Scenario title cannot be empty"))
      end
      cur_scen = Some((clean_name, pending_tags, lnum))
      cur_steps = []
      pending_tags = []
      prev_kind = None
      continue
    end

    if trimmed.starts_with?("|")
      last_idx = cur_steps.size - 1
      if last_idx < 0
        return Error(
          ParseError(path: path, line: lnum, message: "data table row has no preceding step")
        )
      end
      last_step = cur_steps.get(last_idx) or stop "step idx"
      updated_step = Step(
        kind: last_step.kind,
        raw_keyword: last_step.raw_keyword,
        text: last_step.text,
        table: last_step.table.append(parse_table_row(trimmed)),
        line: last_step.line
      )
      cur_steps = cur_steps.set(last_idx, updated_step) or cur_steps
      continue
    end

    case parse_step_line(trimmed, prev_kind)
      Some((skind, raw_kw, stext)):
        if not in_background? and cur_scen == None
          return Error(
            ParseError(
              path: path,
              line: lnum,
              message: "step '#{trimmed}' must appear inside Background or Scenario"
            )
          )
        end
        if stext.empty?
          return Error(
            ParseError(path: path, line: lnum, message: "step text after '#{raw_kw}' is empty")
          )
        end
        prev_kind = Some(skind)
        cur_steps = cur_steps.append(
          Step(kind: skind, raw_keyword: raw_kw, text: stext, table: [], line: lnum)
        )
      None: return Error(
        ParseError(path: path, line: lnum, message: "unrecognized Gherkin line '#{trimmed}'")
      )
    end
  end

  if not pending_tags.empty?
    return Error(
      ParseError(
        path: path,
        line: start_line + lines.size,
        message: "dangling tags without Scenario:"
      )
    )
  end

  if in_background?
    background = cur_steps
  else
    scenarios = try flush_scenario(cur_scen, cur_steps, scenarios)
  end

  if scenarios.empty?
    return Error(
      ParseError(path: path, line: start_line, message: "gherkin block contains no Scenario:")
    )
  end

  Ok((feature_name, background, scenarios))
end

required_h2_headings = ["Sub-features", "How to get to it (user POV)", "Scenarios", "Gotchas"]

## Parses a `.feature.md` Executable Feature Map, strictly enforcing the 4-H2 structure,
## fenced `gherkin` blocks, tags, Background, Given/When/Then/And/But steps, and pipe tables.
fn parse(path: Text, content: Text) : Result(FeatureDoc, ParseError)
  var title = None
  var active_h2 = None
  var seen_h2 = []
  var sub_features = []
  var entry_points = []
  var gotchas = []
  var gherkin_blocks = []
  var fence = FenceClosed

  for (idx, raw_line) in content.lines.enumerate
    lnum = idx + 1
    trimmed = raw_line.trim

    case fence
      FenceOpen(lang: f_lang, start_line: f_start, lines: f_lines):
        if trimmed == "```"
          if f_lang == "gherkin"
            if active_h2 != Some("Scenarios")
              return Error(
                ParseError(
                  path: path,
                  line: f_start,
                  message: "gherkin block must live under '## Scenarios'"
                )
              )
            end
            gherkin_blocks = gherkin_blocks.append((f_start + 1, f_lines))
          end
          fence = FenceClosed
        else
          fence = FenceOpen(lang: f_lang, start_line: f_start, lines: f_lines.append(raw_line))
        end
        continue
      FenceClosed: Unit
    end

    if trimmed.starts_with?("```")
      f_lang = (trimmed.drop_prefix("```") or "").trim.ascii_lowercase
      fence = FenceOpen(lang: f_lang, start_line: lnum, lines: [])
      continue
    end

    if trimmed.drop_prefix("# ") is Some(h1_text)
      if title == None
        clean_h1 = h1_text.trim
        if clean_h1.empty?
          return Error(ParseError(path: path, line: lnum, message: "H1 title cannot be empty"))
        end
        title = Some(clean_h1)
      end
      continue
    end

    if trimmed.drop_prefix("## ") is Some(h2_raw)
      h2 = h2_raw.trim
      if not required_h2_headings.contains?(h2)
        return Error(
          ParseError(
            path: path,
            line: lnum,
            message: "unexpected H2 heading '## #{h2}'; allowed headings: #{required_h2_headings
              .join(", ")}"
          )
        )
      end
      if seen_h2.contains?(h2)
        return Error(ParseError(path: path, line: lnum, message: "duplicate H2 heading '## #{h2}'"))
      end
      seen_h2 = seen_h2.append(h2)
      active_h2 = Some(h2)
      continue
    end

    if trimmed.drop_prefix("- ") is Some(bullet_raw)
      bullet = bullet_raw.trim
      if active_h2 == Some("Sub-features")
        sub_features = sub_features.append(bullet)
      else if active_h2 == Some("How to get to it (user POV)")
        entry_points = entry_points.append(bullet)
      else if active_h2 == Some("Gotchas")
        gotchas = gotchas.append(bullet)
      end
    end
  end

  case fence
    FenceOpen(lang: _, start_line: f_start, lines: _): return Error(
      ParseError(path: path, line: f_start, message: "unclosed code fence in feature file")
    )
    FenceClosed: Unit
  end

  doc_title = case title
    Some(t): t
    None: return Error(
      ParseError(path: path, line: 1, message: "missing '# <Feature Title>' H1 heading")
    )
  end

  for req_h2 in required_h2_headings
    if not seen_h2.contains?(req_h2)
      return Error(
        ParseError(path: path, line: 1, message: "missing required H2 heading '## #{req_h2}'")
      )
    end
  end

  if gherkin_blocks.empty?
    return Error(
      ParseError(path: path, line: 1, message: "missing ```gherkin``` block inside '## Scenarios'")
    )
  end

  var feature_name = doc_title
  var background = []
  var all_scenarios = []
  for (bline, blines) in gherkin_blocks
    (fname, bg, scens) = try parse_gherkin_block(path, bline, blines)
    if not fname.empty?
      feature_name = fname
    end
    if not bg.empty?
      background = background.concat(bg)
    end
    all_scenarios = all_scenarios.concat(scens)
  end

  Ok(
    FeatureDoc(
      path: path,
      title: doc_title,
      feature_name: feature_name,
      sub_features: sub_features,
      entry_points: entry_points,
      gotchas: gotchas,
      background: background,
      scenarios: all_scenarios
    )
  )
end

fn find_matching_binding(bindings: List(StepBinding(W)), step: Step) : Option(
  (StepBinding(W), Map(Text, Text))
)
  for b in bindings
    kind_ok? = case b.kind
      None: true
      Some(k): k == step.kind
    end
    if kind_ok?
      if match_pattern(b.pattern, step.text) is Some(params)
        return Some((b, params))
      end
    end
  end
  None
end

## Executes all scenarios in `doc` (optionally filtered by `tag_filter`) using in-memory `bindings`.
fn run_feature(
  doc: FeatureDoc,
  tag_filter: Option(Text),
  bindings: List(StepBinding(W)),
  init_world: fn() : (W, WebTest.Session, Sqlite.Database, Clock, SecureRandom, Env, ApiTest.App)
) : RunReport
  selected = case tag_filter
    Some(tag): doc.scenarios.filter(fn(s) s.tags.contains?(tag) end)
    None: doc.scenarios
  end

  var results = []
  var passed = 0
  var failed = 0

  for scen in selected
    (init_w, init_sess, db, clock, rng, env, app) = init_world()
    var world = init_w
    var sess = init_sess
    var steps_run = 0
    var failure = None

    all_steps = doc.background.concat(scen.steps)
    for step in all_steps
      case find_matching_binding(bindings, step)
        None:
          failure = Some(
            "unmatched step at #{doc.path}:#{step.line}: #{step.raw_keyword} #{step.text}"
          )
          break
        Some((binding, params)):
          steps_run += 1
          case binding.handler(world, sess, params, step.table, db, clock, rng, env, app)
            Ok((next_w, next_s)):
              world = next_w
              sess = next_s
            Error(msg):
              failure = Some(
                "step failed at #{doc.path}:#{step.line} (#{step.raw_keyword} #{step.text}): #{msg}"
              )
              break
          end
      end
    end

    ok? = failure == None
    if ok?
      passed += 1
    else
      failed += 1
    end
    results = results.append(
      ScenarioResult(
        feature_path: doc.path,
        scenario_name: scen.name,
        tags: scen.tags,
        passed?: ok?,
        steps_run: steps_run,
        error: failure
      )
    )
  end

  RunReport(total: selected.size, passed: passed, failed: failed, results: results)
end

## Extracts `@browser`-tagged scenarios across `docs` for Phase 3 Playwright runner consumption.
fn browser_manifest(docs: List(FeatureDoc)) : List(BrowserScenarioManifest)
  var out = []
  for doc in docs
    for scen in doc.scenarios
      if scen.tags.contains?("@browser")
        out = out.append(
          BrowserScenarioManifest(
            feature_path: doc.path,
            feature_title: doc.title,
            scenario_name: scen.name,
            tags: scen.tags,
            background: doc.background,
            steps: scen.steps
          )
        )
      end
    end
  end
  out
end

## Serializes the `@browser` scenario manifest into JSON.
fn browser_manifest_json(docs: List(FeatureDoc)) : Json
  browser_manifest(docs).to_json
end

## Formats a concise summary of a `RunReport`.
fn format_report(report: RunReport) : Text
  header = "Feature Run: #{report.passed}/#{report.total} passed (#{report.failed} failed)"
  bad = report.results.filter_map(fn(r)
    case r.error
      Some(err): Some("  FAIL [#{r.feature_path}] #{r.scenario_name}: #{err}")
      None: None
    end
  end)
  if bad.empty?: header else: "#{header}\n#{bad.join("\n")}"
end

sample_feature_md = """
# Manage bills

Household members track and add paycheck bills.

## Sub-features

- `bill-list`: shows seeded bills.
- `bill-table`: adds multiple bills via data table.

## How to get to it (user POV)

- Open `/bills` in the browser.

## Scenarios

```gherkin
Feature: Manage bills
  Background:
    Given CSRF token "feat_tok"

  @smoke @browser @db-check
  Scenario: Add bills from table and read them back
    When I add bills:
      | name | amount_cents |
      | Water | 4500 |
      | Gas | 9200 |
    Then bill list includes "Water"
    And bill list includes "Gas"
    But bill list excludes "Missing"

  @smoke
  Scenario: Count bills after background only
    Then bill count is 0
```

## Gotchas

- Always verify persisted DB rows, not only HTTP status.
"""

test "Feature parses 4-H2 .feature.md, executes in-memory scenarios with tables, exports @browser manifest, and rejects malformed specs"
  assert parse("specs/features/bills.feature.md", sample_feature_md) is Ok(doc)
  assert doc.title == "Manage bills"
  assert doc.feature_name == "Manage bills"
  assert doc.sub_features.size == 2
  assert doc.entry_points == ["Open `/bills` in the browser."]
  assert doc.gotchas.size == 1
  assert doc.background.size == 1
  assert doc.scenarios.size == 2
  scen0 = doc.scenarios.get(0) or stop "scen0"
  assert scen0.line == 22
  step0 = scen0.steps.get(0) or stop "step0"
  assert step0.line == 23

  manifest = browser_manifest([doc])
  assert manifest.size == 1
  m_first = manifest.first or stop "manifest item"
  assert m_first.scenario_name == "Add bills from table and read them back"
  assert m_first.tags == ["@smoke", "@browser", "@db-check"]
  m_json = browser_manifest_json([doc])
  assert m_json.to_text.contains?("Add bills from table and read them back")

  bindings = [
    StepBinding(
      kind: Some(Given),
      pattern: "CSRF token \"{tok}\"",
      handler: fn(w, _sess, params, _tbl, _db, _clk, _rng, _env, _app)
        tok = params.get("tok") or ""
        res_hdr = Api.no_content().add_header("Set-Cookie", "XSRF-TOKEN=#{tok}; Path=/")
        next_s = WebTest.Session(
          client: WebTest.absorb(WebTest.new(), res_hdr),
          last_response: None,
          history: []
        )
        Ok((w, next_s))
      end
    ),
    StepBinding(
      kind: Some(When),
      pattern: "I add bills:",
      handler: fn(w, sess, _params, tbl, _db, _clk, _rng, _env, app)
        var cur_s = sess
        for row in tbl.drop(1)
          bname = row.first or ""
          cents = (row.get(1) or "0").to_int or 0
          (ns, res) = WebTest.post_json[FeatureApp.FeatureBillIn](
            cur_s,
            app,
            "/bills",
            FeatureApp.FeatureBillIn(name: bname, amount_cents: cents)
          )
          if res.status != 200
            return Error("expected 200, got #{res.status}")
          end
          cur_s = ns
        end
        Ok((w, cur_s))
      end
    ),
    StepBinding(
      kind: Some(Then),
      pattern: "bill list includes \"{name}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, app)
        target = params.get("name") or ""
        (ns, res) = WebTest.get(sess, app, "/bills")
        if res.status == 200 and res.text.contains?(target)
          Ok((w, ns))
        else
          Error("missing '#{target}' in #{res.text}")
        end
      end
    ),
    StepBinding(
      kind: Some(Then),
      pattern: "bill list excludes \"{name}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, app)
        target = params.get("name") or ""
        (ns, res) = WebTest.get(sess, app, "/bills")
        if res.status == 200 and not res.text.contains?(target)
          Ok((w, ns))
        else
          Error("unexpectedly found '#{target}'")
        end
      end
    ),
    StepBinding(
      kind: None,
      pattern: "bill count is {count}",
      handler: fn(w, sess, params, _tbl, db, _clk, _rng, _env, _app)
        want = (params.get("count") or "-1").to_int or -1
        _s = try FeatureApp.init_schema(db)
        rows = try db.query("SELECT id FROM f_bills", []).map_error(fn(e) "#{e}" end)
        if rows.rows.size == want
          Ok((w, sess))
        else
          Error("expected #{want} rows, got #{rows.rows.size}")
        end
      end
    )
  ]

  t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"
  init_w = fn()
    sql = Sqlite.in_memory()
    clk = Clock.fixed(t0)
    rng = SecureRandom.seeded(5)
    env = Env.of({})
    app = ApiTest.start(FeatureApp, sql, clk, rng, env)
    db = case sql.open("feature.sqlite")
      Ok(d): d
      Error(_): stop "open feature.sqlite"
    end
    (0, WebTest.start(), db, clk, rng, env, app)
  end

  rep = run_feature(doc, Some("@smoke"), bindings, init_w)
  assert rep.total == 2 and rep.passed == 2 and rep.failed == 0
  assert (rep.results.get(0) or stop "r0").steps_run == 5
  assert (rep.results.get(1) or stop "r1").steps_run == 2
  assert format_report(rep).contains?("2/2 passed (0 failed)")

  # Feature omitting `Feature:` header falls back to H1 doc.title
  no_feat_line = sample_feature_md.replace("Feature: Manage bills", "")
  assert parse("specs/nof.feature.md", no_feat_line) is Ok(doc_nof)
  assert doc_nof.feature_name == "Manage bills"

  # Tag filter narrows scenarios
  browser_rep = run_feature(doc, Some("@browser"), bindings, init_w)
  assert browser_rep.total == 1 and browser_rep.passed == 1

  # Negative tests: unmatched step and failing step assertion fail loudly
  no_match_rep = run_feature(doc, None, [], init_w)
  assert no_match_rep.failed == 2
  assert (no_match_rep.results.get(0) or stop "nm0").steps_run == 0
  assert format_report(no_match_rep).contains?("unmatched step")

  bad_count_doc = FeatureDoc(
    path: doc.path,
    title: doc.title,
    feature_name: doc.feature_name,
    sub_features: doc.sub_features,
    entry_points: doc.entry_points,
    gotchas: doc.gotchas,
    background: [],
    scenarios: [
      Scenario(
        name: "Wrong count",
        tags: [],
        steps: [Step(kind: Then, raw_keyword: "Then", text: "bill count is 99", table: [], line: 1)],
        line: 1
      )
    ]
  )
  fail_rep = run_feature(bad_count_doc, None, bindings, init_w)
  assert fail_rep.failed == 1
  assert (fail_rep.results.get(0) or stop "fr0").steps_run == 1
  assert format_report(fail_rep).contains?("expected 99 rows, got 0")

  # Negative parse tests: missing required H2s, missing H1, extra H2, duplicate H2, unclosed fence, bad gherkin
  for missing_heading in [
    "## Sub-features",
    "## How to get to it (user POV)",
    "## Scenarios",
    "## Gotchas"
  ]
    broken = sample_feature_md.replace(missing_heading, "## SomethingElse")
    assert parse("bad.feature.md", broken) is Error(pe)
    assert pe.message.contains?("unexpected H2")
  end

  no_gotchas = """
    # T
    ## Sub-features
    - a
    ## How to get to it (user POV)
    - b
    ## Scenarios
    ```gherkin
    Feature: T
      Scenario: S
        Given x
    ```
    """
  assert parse("nog.feature.md", no_gotchas) is Error(pe_nog)
  assert pe_nog.line == 1
  assert pe_nog.message.contains?("missing required H2 heading '## Gotchas'")

  no_fence = """
    # T
    ## Sub-features
    ## How to get to it (user POV)
    ## Scenarios
    ## Gotchas
    """
  assert parse("nofence.feature.md", no_fence) is Error(pe_nf)
  assert pe_nf.line == 1
  assert pe_nf.message.contains?("missing ```gherkin```")

  dup_h2 = "#{sample_feature_md}\n## Gotchas\n- extra\n"
  assert parse("dup.feature.md", dup_h2) is Error(pe_dup)
  assert pe_dup.message.contains?("duplicate H2 heading")

  no_h1 = sample_feature_md.replace("# Manage bills", "No H1")
  assert parse("noh1.feature.md", no_h1) is Error(pe_h1)
  assert pe_h1.line == 1
  assert pe_h1.message.contains?("missing '# <Feature Title>'")

  unclosed = """
    # T
    ## Sub-features
    ## How to get to it (user POV)
    ## Scenarios
    ```gherkin
    Feature: T
    ## Gotchas
    """
  assert parse("unc.feature.md", unclosed) is Error(pe_unc)
  assert pe_unc.line == 5
  assert pe_unc.message.contains?("unclosed code fence")

  no_scen = """
    # T
    ## Sub-features
    ## How to get to it (user POV)
    ## Scenarios
    ```gherkin
    Feature: T
      Given x
    ```
    ## Gotchas
    """
  assert parse("nos.feature.md", no_scen) is Error(pe_nos)
  assert pe_nos.line == 7

  dangling_tag = """
    # T
    ## Sub-features
    ## How to get to it (user POV)
    ## Scenarios
    ```gherkin
    Feature: T
      Scenario: S
        Given x
      @orphan
    ```
    ## Gotchas
    """
  assert parse("tag.feature.md", dangling_tag) is Error(pe_tag)
  assert pe_tag.line == 10

  stray_table = """
    # T
    ## Sub-features
    ## How to get to it (user POV)
    ## Scenarios
    ```gherkin
    Feature: T
      Scenario: S
        | a | b |
    ```
    ## Gotchas
    """
  assert parse("tbl.feature.md", stray_table) is Error(pe_tbl)
  assert pe_tbl.line == 8
  assert pe_tbl.message.contains?("data table row has no preceding step")

  bg_after_scen = """
    # T
    ## Sub-features
    ## How to get to it (user POV)
    ## Scenarios
    ```gherkin
    Feature: T
      Scenario: A
        Given x
      Background:
        Given bg
      Scenario: B
        Then y
    ```
    ## Gotchas
    """
  assert parse("bg_late.feature.md", bg_after_scen) is Error(pe_bg)
  assert pe_bg.message.contains?("before any Scenario:")

  empty_scen = """
    # T
    ## Sub-features
    ## How to get to it (user POV)
    ## Scenarios
    ```gherkin
    Feature: T
      Scenario: Empty
    ```
    ## Gotchas
    """
  assert parse("empty_scen.feature.md", empty_scen) is Error(pe_emp)
  assert pe_emp.message.contains?("contains no steps")
end
