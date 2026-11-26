## Self-contained HTML Verification Dossier and `<150`-word PR Markdown generator.
module DossierHtml
expose DossierOutput(..),
RouteEntry(..),
bytes_to_base64,
html_escape,
compute_verdict,
parse_verify_jsonl,
extract_routes_from_api_source,
count_words,
render_index_html,
render_pr_summary,
generate_dossier
use Command
use Config
use Control
use Dossier
use Json

## Summary returned by `generate_dossier` and printed by `arvo dossier`.
struct DossierOutput
  verdict: Text
  html_path: Text
  pr_summary_path: Text
  pr_word_count: Int
  screenshots_embedded: Int
end

## Route extracted from an app's declarative `api ... end` block.
struct RouteEntry
  method: Text
  path: Text
  handler: Text
end

struct VisualShot
  label: Text
  rel_path: Text
  data_uri: Option(Text)
end

struct E2eView
  present?: Bool
  run_id: Text
  build_sha: Text
  viewports: List(Text)
  scenarios_passed: List(Text)
  axe_count: Int
  console_errors: Int
  page_errors: Int
  http_5xx: Int
  broken_assets: Int
  db_checks_passed: Int
  visual_diff_pixels: Int
  shots: List(VisualShot)
end

struct ChartView
  title: Text
  states: Int
  transitions: Int
  truncated?: Bool
  violations: Int
  in_sync?: Bool
  sync_detail: Text
  broken_caught?: Bool
  mermaid: Text
end

struct StatechartView
  present?: Bool
  ok?: Bool
  replay_detail: Text
  charts: List(ChartView)
end

## Encodes bytes as standard padded RFC 4648 Base64 (for `data:image/png;base64,...`).
fn bytes_to_base64(b: Bytes) : Text
  raw = b.to_base64url.replace("-", "+").replace("_", "/")
  rem = raw.chars.size % 4
  if rem == 2
    "#{raw}=="
  else if rem == 3
    "#{raw}="
  else
    raw
  end
end

## Escapes HTML special characters (`&`, `<`, `>`, `"`, `'`).
fn html_escape(s: Text) : Text
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace(
    "'",
    "&#39;"
  )
end

## Computes Spec Part 6.3 dossier headline verdict from `verify.jsonl` events.
fn compute_verdict(events: List(Dossier.VerifyEvent)) : Text
  if events.empty? or events.any?(fn(e) e.status == "skipped" end)
    "INCONCLUSIVE"
  else if events.any?(fn(e) e.status == "fail" end)
    "FAIL"
  else if events.any?(fn(e) e.status == "warn" end)
    "PASS WITH CONTRACT CHANGES"
  else
    "PASS"
  end
end

fn json_int_array_len(doc: Json, key: Text) : Int
  case doc.path(key)
    Some(Json.Array(items)): items.size
    Some(_) | None: 0
  end
end

fn json_text_array(doc: Json, key: Text) : List(Text)
  var out = []
  if doc.path(key) is Some(Json.Array(items))
    for item in items
      if item is Json.String(s)
        out = out.append(s)
      end
    end
  end
  out
end

fn json_bool_at(doc: Json, key: Text) : Bool
  case doc.path(key)
    Some(Json.Boolean(b)): b
    Some(_) | None: false
  end
end

## Parses newline-delimited JSON events written to `.arvo/dossier/verify.jsonl`.
fn parse_verify_jsonl(raw: Text) : List(Dossier.VerifyEvent)
  var out = []
  for line in raw.lines
    trimmed = line.trim
    continue if not trimmed.starts_with?("{")
    if Json.parse(trimmed) is Ok(doc)
      ts = doc.text_at("ts") or ""
      tier = doc.text_at("tier") or ""
      phase = doc.text_at("phase") or ""
      status = doc.text_at("status") or ""
      ms = doc.int_at("ms") or 0
      var ev = Dossier.new_event(ts, tier, phase, status, ms)
      ev.detail = doc.text_at("detail")
      ev.pages_checked = doc.int_at("pages_checked")
      ev.passed = doc.int_at("passed")
      ev.failed = doc.int_at("failed")
      ev.total = doc.int_at("total")
      ev.killed = doc.int_at("killed")
      ev.survived = doc.int_at("survived")
      if doc.path("kill_rate") is Some(Json.Number(jn))
        ev.kill_rate = jn.to_float
      end
      if doc.path("modified_contracts") is Some(Json.Array(_))
        ev.modified_contracts = Some(json_text_array(doc, "modified_contracts"))
      end
      out = out.append(ev)
    end
  end
  out
end

fn first_quoted(s: Text) : Option((Text, Text))
  parts = s.split("\"")
  return None if parts.size < 3
  q = parts.get(1) or ""
  rest = parts.drop(2).join("\"")
  Some((q, rest))
end

fn normalize_route_path(scopes: List(Text), raw_path: Text) : Text
  joined = "#{scopes.join("")}#{raw_path}"
  if joined.empty?
    "/"
  else
    joined
  end
end

## Extracts HTTP routes declared in an app's `api ... end` block.
fn extract_routes_from_api_source(src: Text) : List(RouteEntry)
  var in_api? = false
  var scopes = []
  var out = []
  verbs = ["get", "post", "put", "patch", "delete"]

  for raw in src.lines
    line = raw.trim
    if not in_api?
      if line == "api"
        in_api? = true
      end
      continue
    end

    if line == "end"
      if scopes.empty?
        break
      else
        scopes = scopes.take(scopes.size - 1)
      end
      continue
    end

    if line.starts_with?("scope ")
      if first_quoted(line) is Some((prefix, _))
        scopes = scopes.append(prefix)
      end
      continue
    end

    for verb in verbs
      if line.starts_with?("#{verb} ")
        if first_quoted(line) is Some((rpath, rem))
          out = out.append(
            RouteEntry(
              method: verb.ascii_uppercase,
              path: normalize_route_path(scopes, rpath),
              handler: rem.trim
            )
          )
        end
        break
      end
    end
  end
  out
end

## Counts whitespace-separated tokens across lines (used to enforce `< 150` words in `pr-summary.md`).
fn count_words(text: Text) : Int
  text.words.size
end

fn short_sha_of(sha: Text) : Text
  Text.from_chars(sha.chars.take(12))
end

fn shot_label_from_path(p: Text) : Text
  base = p.split("/").last or p
  base.drop_suffix(".png") or base
end

fn find_e2e_report_path(files: ReadFiles, cur_sha: Text) : Option(Text)
  return None if not files.exists?(".arvo/evidence")
  ents = case files.walk(".arvo/evidence")
    Ok(e): e
    Error(_): return None
  end
  var paths = []
  for ent in ents
    continue if not (ent.kind is File)
    if ent.name.ends_with?("/e2e-report.json") or ent.name == "e2e-report.json"
      paths = paths.append(".arvo/evidence/#{ent.name}")
    end
  end
  ordered = paths.sort_by(fn(p) p end).reverse
  for p in ordered
    if files.read_text(p) is Ok(raw)
      if Json.parse(raw) is Ok(doc)
        if doc.text_at("build_sha") == Some(cur_sha)
          return Some(p)
        end
      end
    end
  end
  ordered.first
end

fn empty_e2e_view() : E2eView
  E2eView(
    present?: false,
    run_id: "",
    build_sha: "",
    viewports: [],
    scenarios_passed: [],
    axe_count: 0,
    console_errors: 0,
    page_errors: 0,
    http_5xx: 0,
    broken_assets: 0,
    db_checks_passed: 0,
    visual_diff_pixels: 0,
    shots: []
  )
end

fn valid_evidence_png_path?(p: Text) : Bool
  t = p.trim
  not t.empty? and
    t.starts_with?(".arvo/evidence/") and
    not t.contains?("..") and
    not t.contains?("\\")
end

fn png_magic?(b: Bytes) : Bool
  b.size >= 8 and
    (b.get(0) or 0).to_int == 137 and
    (b.get(1) or 0).to_int == 80 and
    (b.get(2) or 0).to_int == 78 and
    (b.get(3) or 0).to_int == 71 and
    (b.get(4) or 0).to_int == 13 and
    (b.get(5) or 0).to_int == 10 and
    (b.get(6) or 0).to_int == 26 and
    (b.get(7) or 0).to_int == 10
end

fn load_e2e_view(files: ReadFiles, cur_sha: Text) : E2eView
  case find_e2e_report_path(files, cur_sha)
    None: empty_e2e_view()
    Some(rpath):
      case files.read_text(rpath)
        Error(_): empty_e2e_view()
        Ok(raw):
          case Json.parse(raw)
            Error(_): empty_e2e_view()
            Ok(doc):
              var shots = []
              for sp in json_text_array(doc, "screenshots")
                uri = if valid_evidence_png_path?(sp)
                  case files.read_bytes(sp)
                    Ok(b): if png_magic?(b): Some("data:image/png;base64,#{bytes_to_base64(b)}") else: None
                    Error(_): None
                  end
                else
                  None
                end
                shots = shots.append(
                  VisualShot(label: shot_label_from_path(sp), rel_path: sp, data_uri: uri)
                )
              end
              E2eView(
                present?: true,
                run_id: doc.text_at("run_id") or "",
                build_sha: doc.text_at("build_sha") or "",
                viewports: json_text_array(doc, "viewports"),
                scenarios_passed: json_text_array(doc, "scenarios_passed"),
                axe_count: json_int_array_len(doc, "axe_violations"),
                console_errors: json_int_array_len(doc, "console_errors"),
                page_errors: json_int_array_len(doc, "page_errors"),
                http_5xx: json_int_array_len(doc, "http_5xx"),
                broken_assets: json_int_array_len(doc, "broken_assets"),
                db_checks_passed: doc.int_at("db_checks_passed") or 0,
                visual_diff_pixels: doc.int_at("visual_diff_pixels") or 0,
                shots: shots
              )
          end
      end
  end
end

fn empty_statechart_view() : StatechartView
  StatechartView(present?: false, ok?: false, replay_detail: "", charts: [])
end

fn load_statechart_view(files: ReadFiles) : StatechartView
  rpath = ".arvo/dossier/statecharts/report.json"
  return empty_statechart_view() if not files.exists?(rpath)
  raw = case files.read_text(rpath)
    Ok(s): s
    Error(_): return empty_statechart_view()
  end
  doc = case Json.parse(raw)
    Ok(d): d
    Error(_): return empty_statechart_view()
  end
  var charts = []
  if doc.path("charts") is Some(Json.Array(items))
    for item in items
      charts = charts.append(
        ChartView(
          title: item.text_at("title") or "Statechart",
          states: item.int_at("states") or 0,
          transitions: item.int_at("transitions") or 0,
          truncated?: json_bool_at(item, "truncated"),
          violations: item.int_at("violations") or 0,
          in_sync?: json_bool_at(item, "in_sync"),
          sync_detail: item.text_at("sync_detail") or "",
          broken_caught?: json_bool_at(item, "broken_caught"),
          mermaid: item.text_at("mermaid") or ""
        )
      )
    end
  end
  StatechartView(
    present?: true,
    ok?: json_bool_at(doc, "ok"),
    replay_detail: doc.text_at("replay_detail") or "",
    charts: charts
  )
end

fn collect_modified_contracts(events: List(Dossier.VerifyEvent)) : List(Text)
  var mods = []
  for ev in events
    if ev.modified_contracts is Some(paths)
      for p in paths
        if not mods.contains?(p)
          mods = mods.append(p)
        end
      end
    end
  end
  mods
end

fn verdict_css_class(verdict: Text) : Text
  if verdict == "PASS"
    "badge-pass"
  else if verdict == "PASS WITH CONTRACT CHANGES"
    "badge-warn"
  else
    "badge-fail"
  end
end

fn render_tamper_banner(events: List(Dossier.VerifyEvent)) : Text
  mods = collect_modified_contracts(events)
  tamper_warn? = events.any?(fn(e) e.phase == "tamper_check" and e.status == "warn" end)
  if mods.empty? and not tamper_warn?
    "<section id=\"tamper\" class=\"card\">\n  <h2>1. Tamper Alert Banner</h2>\n  <p class=\"pill badge-pass\">0 contract edits — all tamper-protected files match baseline</p>\n</section>"
  else
    items = if mods.empty?
      "<li>Contract baseline warning detected (no explicit paths listed).</li>"
    else
      mods.map(fn(p) "<li><code>#{html_escape(p)}</code></li>" end).join("")
    end
    "<section id=\"tamper\" class=\"card alert-warn\">\n  <h2>1. Tamper Alert Banner — Contract Changed (Human Review Required)</h2>\n  <ul>#{items}</ul>\n</section>"
  end
end

fn render_visual_strip(e2e: E2eView, build_sha: Text) : Text
  if not e2e.present?
    return "<section id=\"visual-proof\" class=\"card\">\n  <h2>2. Visual-First Proof Strip</h2>\n  <p class=\"muted\">No Playwright E2E evidence recorded under <code>.arvo/evidence/</code>.</p>\n</section>"
  end
  stale_badge = if not e2e.build_sha.empty? and e2e.build_sha != build_sha
    " <span class=\"pill badge-warn\">STALE EVIDENCE (e2e=#{html_escape(short_sha_of(e2e.build_sha))})</span>"
  else
    ""
  end
  meta = "<p class=\"meta\">Run <code>#{html_escape(e2e.run_id)}</code>#{stale_badge} · Viewports: <strong>#{html_escape(
    e2e.viewports.join(", ")
  )}</strong> · Scenarios: <strong>#{e2e.scenarios_passed.size}</strong> · Axe violations: <strong>#{e2e
    .axe_count}</strong> · Console/Page/5xx/Assets: <strong>#{e2e.console_errors}/#{e2e.page_errors}/#{e2e
    .http_5xx}/#{e2e.broken_assets}</strong> · DB checks: <strong>#{e2e.db_checks_passed}</strong> · Visual diff px: <strong>#{e2e
    .visual_diff_pixels}</strong></p>"
  var shot_cards = []
  for s in e2e.shots
    img_html = case s.data_uri
      Some(u): "<img src=\"#{u}\" alt=\"#{html_escape(s.label)}\" loading=\"lazy\">"
      None: "<div class=\"missing-img\">Image unreadable: #{html_escape(s.rel_path)}</div>"
    end
    shot_cards = shot_cards.append(
      "<figure class=\"shot-card\">#{img_html}<figcaption>#{html_escape(s.label)} (<code>#{html_escape(
        s.rel_path
      )}</code>)</figcaption></figure>"
    )
  end
  "<section id=\"visual-proof\" class=\"card\">\n  <h2>2. Visual-First Proof Strip (Mobile 390×844 &amp; Desktop 1280×800)</h2>\n  #{meta}\n  <div class=\"shots-grid\">#{shot_cards
    .join("")}</div>\n</section>"
end

fn render_statecharts_section(sc: StatechartView) : Text
  if not sc.present? or sc.charts.empty?
    return "<section id=\"statecharts\" class=\"card\">\n  <h2>3. Formal Statecharts</h2>\n  <p class=\"muted\">No statechart report found at <code>.arvo/dossier/statecharts/report.json</code>.</p>\n</section>"
  end
  var blocks = []
  for ch in sc.charts
    sync_cls = if ch.in_sync?
      "badge-pass"
    else
      "badge-fail"
    end
    sync_lbl = if ch.in_sync?
      "in sync"
    else
      "stale"
    end
    blocks = blocks.append(
      "<div class=\"chart-block\">\n  <h3>#{html_escape(ch.title)} <span class=\"pill #{sync_cls}\">#{sync_lbl} (#{html_escape(
        ch.sync_detail
      )})</span></h3>\n  <p class=\"meta\">States: <strong>#{ch.states}</strong> · Transitions: <strong>#{ch
        .transitions}</strong> · Violations: <strong>#{ch.violations}</strong> · Broken variant caught: <strong>#{ch
        .broken_caught?}</strong></p>\n  <pre class=\"mermaid\">#{html_escape(ch.mermaid)}</pre>\n</div>"
    )
  end
  "<section id=\"statecharts\" class=\"card\">\n  <h2>3. Formal Statecharts</h2>\n  <p class=\"meta\">Real-code replay: <strong>#{html_escape(
    sc.replay_detail
  )}</strong></p>\n  #{blocks.join("\n")}\n</section>"
end

fn format_event_metrics(ev: Dossier.VerifyEvent) : Text
  var parts = []
  if ev.killed is Some(k) and ev.total is Some(t)
    parts = parts.append("#{k}/#{t} killed")
  else if ev.passed is Some(p)
    parts = parts.append("#{p} passed")
  end
  if ev.kill_rate is Some(r)
    parts = parts.append("rate=#{r}")
  end
  if ev.pages_checked is Some(pc)
    parts = parts.append("pages=#{pc}")
  end
  if parts.empty?
    "—"
  else
    parts.join(", ")
  end
end

fn render_scorecard_section(events: List(Dossier.VerifyEvent)) : Text
  var rows = []
  for ev in events
    cls = if ev.status == "pass"
      "badge-pass"
    else if ev.status == "warn"
      "badge-warn"
    else
      "badge-fail"
    end
    rows = rows.append(
      "<tr><td><code>#{html_escape(ev.phase)}</code></td><td><span class=\"pill #{cls}\">#{html_escape(
        ev.status.ascii_uppercase
      )}</span></td><td>#{html_escape(format_event_metrics(ev))}</td><td>#{ev.ms} ms</td><td>#{html_escape(
        ev.detail or ""
      )}</td></tr>"
    )
  end
  "<section id=\"scorecard\" class=\"card\">\n  <h2>4. Adversarial &amp; Mutation Scorecard</h2>\n  <table><thead><tr><th>Phase</th><th>Status</th><th>Metrics</th><th>Duration</th><th>Detail</th></tr></thead><tbody>#{rows
    .join("")}</tbody></table>\n</section>"
end

fn chart_verified?(c: ChartView) : Bool
  c.violations == 0 and c.in_sync? and c.broken_caught? and not c.truncated?
end

fn render_route_matrix(
  routes: List(RouteEntry),
  cfg: Config.ArvoConfig,
  events: List(Dossier.VerifyEvent)
) : Text
  if routes.empty?
    return "<section id=\"route-matrix\" class=\"card\">\n  <h2>5. Route Security &amp; Query-Budget Matrix</h2>\n  <p class=\"muted\">No <code>api</code> route entries parsed from <code>#{html_escape(
      cfg.entry
    )}</code>.</p>\n</section>"
  end
  mo_test_status = case find_event(events, "mo_test")
    Some(ev):
      if ev.status == "pass"
        "not measured per-route (mo_test pass)"
      else
        "not measured per-route (mo_test #{ev.status})"
      end
    None: "not measured per-route"
  end
  var rows = []
  for rt in routes
    key = "#{rt.method} #{rt.path}"
    auth_lbl = if cfg.public_routes.contains?(key)
      "Public (config)"
    else
      "Auth Required (config)"
    end
    csrf_lbl = if rt.method == "GET"
      "N/A (GET)"
    else if cfg.csrf_exempt_routes.contains?(key)
      "Exempt (config)"
    else
      "CSRF Enforced (config)"
    end
    rows = rows.append(
      "<tr><td><code>#{html_escape(key)}</code></td><td><code>#{html_escape(rt.handler)}</code></td><td>#{auth_lbl}</td><td>#{csrf_lbl}</td><td>#{html_escape(
        mo_test_status
      )}</td><td>#{html_escape(mo_test_status)}</td><td>not measured per-route (budget &le; #{cfg
        .max_queries_per_get})</td></tr>"
    )
  end
  "<section id=\"route-matrix\" class=\"card\">\n  <h2>5. Route Security &amp; Query-Budget Matrix</h2>\n  <table><thead><tr><th>Route</th><th>Handler</th><th>Auth Policy</th><th>CSRF Policy</th><th>XSS</th><th>409 / 422</th><th>Queries / Budget</th></tr></thead><tbody>#{rows
    .join("")}</tbody></table>\n</section>"
end

fn render_decisions_and_attention(
  verdict: Text,
  events: List(Dossier.VerifyEvent),
  decisions: List(Dossier.DecisionRow)
) : Text
  dec_html = if decisions.empty?
    "<p class=\"muted\">No decision rows logged yet. Record decisions with <code>arvo log</code>.</p>"
  else
    drows = decisions.map(fn(d)
      "<tr><td><code>#{html_escape(d.ts)}</code></td><td><code>#{html_escape(d.phase)}</code></td><td>#{html_escape(
        d.decision
      )}</td><td>#{html_escape(d.why)}</td><td><code>#{html_escape(d.evidence)}</code></td><td>#{html_escape(
        d.result
      )}</td></tr>"
    end).join("")
    "<table><thead><tr><th>Timestamp</th><th>Phase</th><th>Decision</th><th>Why</th><th>Evidence</th><th>Result</th></tr></thead><tbody>#{drows}</tbody></table>"
  end

  var flags = []
  for ev in events
    if ev.status != "pass"
      flags = flags.append(
        "<li><strong>#{html_escape(ev.phase)}</strong> (#{html_escape(ev.status)}): #{html_escape(
          ev.detail or ""
        )}</li>"
      )
    end
  end
  att_body = if flags.empty? and verdict == "PASS"
    "<p class=\"pill badge-pass\">Attention: No open automated failures or contract changes; ready for independent verifier sign-off.</p>"
  else
    "<ul>#{flags.join("")}</ul>"
  end

  "<section id=\"decisions\" class=\"card\">\n  <h2>6. Decision Trail (<code>decisions.tsv</code>) &amp; Independent Verifier Attention</h2>\n  #{dec_html}\n  <div id=\"attention\" class=\"attention-box\"><h3>Attention</h3><p class=\"meta\">Independent verifier status: <strong>Pending independent reviewer agent check</strong> (Verdict: #{html_escape(
    verdict
  )})</p>#{att_body}</div>\n</section>"
end

## Renders the complete self-contained static `.arvo/dossier/index.html` containing all 6 Spec Part 6.3 sections.
fn render_index_html(
  app_dir: Text,
  tier: Text,
  build_sha: Text,
  total_ms: Int,
  cfg: Config.ArvoConfig,
  events: List(Dossier.VerifyEvent),
  e2e: E2eView,
  sc: StatechartView,
  routes: List(RouteEntry),
  decisions: List(Dossier.DecisionRow)
) : Text
  verdict = compute_verdict(events)
  short_sha = short_sha_of(build_sha)
  v_cls = verdict_css_class(verdict)
  css = """
  body{font-family:system-ui,-apple-system,sans-serif;background:#0b1120;color:#e2e8f0;margin:0;padding:24px;line-height:1.5}
  main{max-width:1120px;margin:0 auto}
  .header{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:12px;margin-bottom:20px}
  .card{background:#111827;border:1px solid #1f2937;border-radius:10px;padding:18px;margin-bottom:16px}
  .alert-warn{border-color:#d97706;background:#1c1917}
  .pill{display:inline-block;padding:4px 10px;border-radius:999px;font-weight:600;font-size:0.85rem}
  .badge-pass{background:#064e3b;color:#a7f3d0}
  .badge-warn{background:#78350f;color:#fde68a}
  .badge-fail{background:#7f1d1d;color:#fecaca}
  .meta{color:#94a3b8;font-size:0.9rem}
  .muted{color:#94a3b8}
  table{width:100%;border-collapse:collapse;font-size:0.9rem}
  th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #1f2937;vertical-align:top}
  th{color:#cbd5e1;font-weight:600}
  .shots-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;margin-top:12px}
  .shot-card{margin:0;background:#0f172a;border:1px solid #1e293b;border-radius:8px;padding:8px}
  .shot-card img{width:100%;height:auto;border-radius:4px;display:block}
  .shot-card figcaption{font-size:0.8rem;color:#94a3b8;margin-top:6px}
  .mermaid{background:#0f172a;padding:12px;border-radius:8px;overflow:auto;font-size:0.82rem;color:#bae6fd}
  .attention-box{margin-top:14px;padding:12px;background:#0f172a;border-left:4px solid #38bdf8;border-radius:6px}
  code{font-family:ui-monospace,monospace;font-size:0.85em}
  """
  """
  <!doctype html>
  <html lang="en">
  <head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Arvo Verification Dossier — #{html_escape(verdict)}</title>
  <style>#{css}</style>
  </head>
  <body>
  <main>
  <header class="header card">
    <div>
      <h1>Arvo Verification Dossier</h1>
      <p class="meta">App: <code>#{html_escape(app_dir)}</code> · Tier: <strong>#{html_escape(tier)}</strong> · Build SHA: <code>#{html_escape(
    short_sha
  )}</code> · Duration: <strong>#{total_ms} ms</strong></p>
    </div>
    <span class="pill #{v_cls}">#{html_escape(verdict)}</span>
  </header>
  #{render_tamper_banner(events)}
  #{render_visual_strip(e2e, build_sha)}
  #{render_statecharts_section(sc)}
  #{render_scorecard_section(events)}
  #{render_route_matrix(routes, cfg, events)}
  #{render_decisions_and_attention(verdict, events, decisions)}
  </main>
  </body>
  </html>
  """
end

fn find_event(events: List(Dossier.VerifyEvent), phase: Text) : Option(Dossier.VerifyEvent)
  events.find(fn(e) e.phase == phase end)
end

fn pr_summary_shot_path(rel_path: Text) : Text
  case rel_path.drop_prefix(".arvo/")
    Some(rest): "../#{rest}"
    None: rel_path
  end
end

fn trim_pr_summary_under_limit(sections: List(Text), max_words: Int) : Text
  joined = "#{sections.join("\n\n")}\n"
  return joined if count_words(joined) <= max_words
  # Trim excess lines/tokens cleanly so pr-summary.md is always strictly < 150 words.
  wlist = joined.words
  kept = wlist.take(max_words - 1).join(" ")
  "#{kept} ...\n"
end

## Renders a concise plain-words PR Markdown summary strictly under 150 words.
fn render_pr_summary(
  tier: Text,
  build_sha: Text,
  total_ms: Int,
  events: List(Dossier.VerifyEvent),
  e2e: E2eView,
  sc: StatechartView
) : Text
  verdict = compute_verdict(events)
  short_sha = short_sha_of(build_sha)
  pass_cnt = events.filter(fn(e) e.status == "pass" end).size
  var bullets = []

  if find_event(events, "mo_mutants") is Some(ev)
    bullets = bullets.append("- Mo mutants: #{ev.killed or 0}/#{ev.total or 0} killed")
  end
  if find_event(events, "mo_strength") is Some(ev)
    bullets = bullets.append("- Strength suites: #{ev.killed or 0}/#{ev.total or 0} killed")
  end
  if find_event(events, "semantic_mutants") is Some(ev)
    bullets = bullets.append("- Semantic probes: #{ev.killed or 0}/#{ev.total or 0} caught")
  end
  if find_event(events, "stryker") is Some(ev)
    bullets = bullets.append("- Stryker TS: #{ev.killed or 0}/#{ev.total or 0} killed")
  end
  if e2e.present?
    bullets = bullets.append(
      "- Playwright: #{e2e.scenarios_passed.size} scenarios, #{e2e.axe_count} axe errors, #{e2e
        .db_checks_passed} DB checks, #{e2e.visual_diff_pixels} diff px"
    )
  end
  var failed_charts = []
  if sc.present?
    verified_cnt = sc.charts.filter(chart_verified?).size
    sc_note = if sc.ok? and verified_cnt == sc.charts.size and not sc.charts.empty?
      "replay ok"
    else
      "attention required"
    end
    bullets = bullets.append("- Statecharts: #{verified_cnt}/#{sc.charts.size} verified (#{sc_note})")
    for c in sc.charts
      if not chart_verified?(c)
        failed_charts = failed_charts.append(c.title)
      end
    end
  end

  var shot_lines = []
  var shown = 0
  for s in e2e.shots
    break if shown >= 2
    if s.data_uri is Some(_)
      shot_lines = shot_lines.append("![#{s.label}](#{pr_summary_shot_path(s.rel_path)})")
      shown += 1
    end
  end

  mods = collect_modified_contracts(events)
  failed_phases = events.filter(fn(e) e.status == "fail" end).map(fn(e) e.phase end)
  var calls = []
  if not failed_phases.empty?
    calls = calls.append("- Fix failed phases: #{failed_phases.join(", ")}")
  end
  if not failed_charts.empty?
    calls = calls.append("- Review statechart issues: #{failed_charts.join(", ")}")
  else if sc.present? and not sc.ok?
    calls = calls.append("- Review statechart replay failure")
  end
  if not mods.empty?
    calls = calls.append("- Review modified contracts: #{mods.take(5).join(", ")}")
  end
  calls_md = if calls.empty?
    "None — automated checks passed cleanly."
  else
    calls.join("\n")
  end

  var sections = [
    "# Verification Summary: #{verdict}",
    "Tier `#{tier}` (`#{short_sha}`) ran #{events.size} checks (#{pass_cnt} passed) in #{total_ms} ms."
  ]
  if not bullets.empty?
    sections = sections.append(bullets.join("\n"))
  end
  if not shot_lines.empty?
    sections = sections.append(shot_lines.join("\n"))
  end
  sections = sections.append("## Calls Waiting on Human\n#{calls_md}")
  trim_pr_summary_under_limit(sections, 149)
end

## Generates `.arvo/dossier/index.html` and `.arvo/dossier/pr-summary.md` from verify events and evidence.
fn generate_dossier(
  app_dir: Text,
  tier: Text,
  cfg: Config.ArvoConfig,
  app_files: Files,
  events_opt: Option(List(Dossier.VerifyEvent)),
  total_ms_opt: Option(Int),
  cmd: Command,
  env: Env
) : Result(DossierOutput, Text)
  events = case events_opt
    Some(evs): evs
    None:
      vraw = try app_files.read_text(".arvo/dossier/verify.jsonl").map_error(
        fn(_) "missing .arvo/dossier/verify.jsonl; run `arvo verify` first" end
      )
      parsed = parse_verify_jsonl(vraw)
      return Error("no valid events in .arvo/dossier/verify.jsonl") if parsed.empty?
      parsed
  end
  eff_tier = case events.last
    Some(last_ev):
      if tier.empty?
        last_ev.tier
      else
        tier
      end
    None: tier
  end
  var computed_ms = 0
  for ev in events
    computed_ms += ev.ms
  end
  total_ms = total_ms_opt or computed_ms

  rf = app_files.read_only
  build_sha = Control.compute_build_sha(rf, cfg, cmd, env)
  e2e = load_e2e_view(rf, build_sha)
  sc = load_statechart_view(rf)
  entry_src = case rf.read_text(cfg.entry)
    Ok(s): s
    Error(_): ""
  end
  routes = extract_routes_from_api_source(entry_src)
  decisions = case rf.read_text(".arvo/dossier/decisions.tsv")
    Ok(raw): Dossier.parse_decisions_tsv(raw)
    Error(_): []
  end

  html = render_index_html(
    app_dir,
    eff_tier,
    build_sha,
    total_ms,
    cfg,
    events,
    e2e,
    sc,
    routes,
    decisions
  )
  pr_md = render_pr_summary(eff_tier, build_sha, total_ms, events, e2e, sc)
  embedded = e2e.shots.filter(fn(s) s.data_uri is Some(_) end).size
  verdict = compute_verdict(events)

  _mk = try app_files.make_folder(".arvo/dossier").map_error(fn(e) "#{e}" end)
  html_path = ".arvo/dossier/index.html"
  pr_path = ".arvo/dossier/pr-summary.md"
  _wh = try app_files.write_text(html_path, html).map_error(fn(e) "#{e}" end)
  _wp = try app_files.write_text(pr_path, pr_md).map_error(fn(e) "#{e}" end)

  Ok(
    DossierOutput(
      verdict: verdict,
      html_path: html_path,
      pr_summary_path: pr_path,
      pr_word_count: count_words(pr_md),
      screenshots_embedded: embedded
    )
  )
end

test "DossierHtml renders 6-section static HTML, embeds base64 PNGs, and keeps PR Markdown under 150 words"
  # 1. bytes_to_base64 padding & URL-char replacement
  assert bytes_to_base64(Bytes.empty) == ""
  assert bytes_to_base64("f".bytes) == "Zg=="
  assert bytes_to_base64("fo".bytes) == "Zm8="
  assert bytes_to_base64("foo".bytes) == "Zm9v"
  b_special = Bytes.from_hex("fbff") or Bytes.empty
  b64_sp = bytes_to_base64(b_special)
  assert b64_sp.contains?("+") and b64_sp.contains?("/") and b64_sp.ends_with?("=")

  # 2. html_escape, compute_verdict, and count_words
  assert html_escape("<a & \"b\" 'c'>") == "&lt;a &amp; &quot;b&quot; &#39;c&#39;&gt;"
  var ev_p = Dossier.new_event("t", "full", "mo_test", "pass", 10)
  var ev_w = Dossier.new_event("t", "full", "tamper_check", "warn", 5)
  ev_w.modified_contracts = Some(["specs/a.feature.md"])
  var ev_f = Dossier.new_event("t", "full", "mo_mutants", "fail", 20)
  var ev_s = Dossier.new_event("t", "full", "stryker", "skipped", 0)
  assert compute_verdict([]) == "INCONCLUSIVE"
  assert compute_verdict([ev_p, ev_s]) == "INCONCLUSIVE"
  assert compute_verdict([ev_p, ev_w, ev_f]) == "FAIL"
  assert compute_verdict([ev_p, ev_w]) == "PASS WITH CONTRACT CHANGES"
  assert compute_verdict([ev_p]) == "PASS"
  assert count_words("  hello  world\n\none\ttwo\n") == 4
  assert bytes_to_base64("foob".bytes) == "Zm9vYg=="
  assert bytes_to_base64("fooba".bytes) == "Zm9vYmE="

  # 3. parse_verify_jsonl & extract_routes_from_api_source
  raw_jl = """
    not-json
    {"ts":"2026-11-25T10:00:00Z","tier":"full","phase":"contracts","status":"pass","pages_checked":2,"detail":"ok","ms":15}
    {"ts":"2026-11-25T10:00:01Z","tier":"full","phase":"mo_mutants","status":"pass","total":10,"killed":10,"survived":0,"kill_rate":1.0,"ms":50}
    {"ts":"2026-11-25T10:00:02Z","tier":"full","phase":"tamper_check","status":"warn","modified_contracts":["specs/bills.feature.md"],"ms":3}
    {"ts":"t0"}
    """
  parsed_evs = parse_verify_jsonl(raw_jl)
  assert parsed_evs.size == 4
  assert parsed_evs.get(0).map(fn(e) e.pages_checked end) == Some(Some(2))
  assert parsed_evs.get(1).map(fn(e) e.kill_rate end) == Some(Some(1.0))
  assert parsed_evs.get(2).map(fn(e) e.modified_contracts end) ==
    Some(Some(["specs/bills.feature.md"]))
  assert parsed_evs.get(3).map(fn(e) e.ms end) == Some(0)

  api_src = """
    module Main
    get "/before" Routes.ignored
    # api comment ignored
    api
      port 8080
      # get "/commented" Routes.commented
      get "/login" Routes.show_login
      post "/login" Routes.post_login
      scope "/bills"
        post "" Routes.create_bill
        post "/:id/pay" Routes.pay_bill
        delete "/:id" Routes.delete_bill
      end
      patch "/settings" Routes.patch_settings
      put "/profile" Routes.put_profile
    end
    fn after_api() : Int
      1
    end
    """
  routes = extract_routes_from_api_source(api_src)
  assert routes == [
    RouteEntry(method: "GET", path: "/login", handler: "Routes.show_login"),
    RouteEntry(method: "POST", path: "/login", handler: "Routes.post_login"),
    RouteEntry(method: "POST", path: "/bills", handler: "Routes.create_bill"),
    RouteEntry(method: "POST", path: "/bills/:id/pay", handler: "Routes.pay_bill"),
    RouteEntry(method: "DELETE", path: "/bills/:id", handler: "Routes.delete_bill"),
    RouteEntry(method: "PATCH", path: "/settings", handler: "Routes.patch_settings"),
    RouteEntry(method: "PUT", path: "/profile", handler: "Routes.put_profile")
  ]
  assert extract_routes_from_api_source("api\n  scope \"\"\n    get \"\" H.root\n  end\nend\n") == [
    RouteEntry(method: "GET", path: "/", handler: "H.root")
  ]

  # 4. Full generate_dossier end-to-end with evidence, screenshots (1 present + 1 missing), statecharts, decisions, tamper
  var cfg = Config.default_config()
  cfg.public_routes = ["GET /login", "POST /login"]
  cfg.csrf_exempt_routes = ["PUT /profile"]
  cfg.max_queries_per_get = 8

  git_cmd = Command.fake(
    Command.replies([
      (Command.spec("git", ["rev-parse", "HEAD"]), Command.ok_output("sha_dossier_123456\n"))
    ])
  )
  sc_json = """
    {
      "ok": true,
      "replay_detail": "replay passed (50 check(s))",
      "charts": [
        {
          "title": "Arvo.Jobs Lifecycle",
          "states": 10,
          "transitions": 15,
          "violations": 0,
          "in_sync": true,
          "sync_detail": "in_sync (623f4041)",
          "broken_caught": true,
          "mermaid": "stateDiagram-v2\\n  S0 --> S1 : claim"
        },
        {
          "title": "Arvo.Session Lifecycle",
          "states": 5,
          "transitions": 5,
          "violations": 1,
          "in_sync": false,
          "sync_detail": "stale",
          "broken_caught": true,
          "mermaid": "stateDiagram-v2\\n  [*] --> S0"
        }
      ]
    }
    """
  e2e_json = """
    {
      "build_sha": "sha_dossier_123456",
      "run_id": "r_e2e",
      "viewports": ["mobile", "desktop"],
      "scenarios_passed": ["login-mobile", "login-desktop"],
      "console_errors": [],
      "page_errors": [],
      "http_5xx": [],
      "broken_assets": [],
      "axe_violations": [],
      "db_checks_passed": 4,
      "visual_diff_pixels": 0,
      "screenshots": [
        ".arvo/evidence/r_e2e/login-mobile.png",
        ".arvo/evidence/r_e2e/home-desktop.png",
        ".arvo/evidence/r_e2e/missing.png"
      ]
    }
    """
  var ev_str = Dossier.new_event("2026-11-25T10:00:03Z", "full", "mo_strength", "pass", 12)
  ev_str.total = Some(23)
  ev_str.killed = Some(23)
  ev_str.kill_rate = Some(1.0)
  var ev_sm = Dossier.new_event("2026-11-25T10:00:04Z", "full", "semantic_mutants", "pass", 9)
  ev_sm.total = Some(5)
  ev_sm.killed = Some(5)
  var ev_stry = Dossier.new_event("2026-11-25T10:00:05Z", "full", "stryker", "pass", 10)
  ev_stry.total = Some(100)
  ev_stry.killed = Some(92)
  all_jsonl = [
    Dossier.event_to_json(ev_p),
    Dossier.event_to_json(ev_w),
    Dossier.event_to_json(ev_str),
    Dossier.event_to_json(ev_sm),
    Dossier.event_to_json(ev_stry)
  ].join("\n")

  png_sample_bytes = Bytes.join([
    Bytes.from_hex("89504e470d0a1a0a") or Bytes.empty,
    "IHDR".bytes
  ])
  png_sample_text = Bytes.from_hex("89504e470d0a1a0a").map(fn(_) "ok" end) or "ok"
  _ = png_sample_text
  f_full = Files.in_memory({
    "main.mo": api_src,
    ".arvo/dossier/verify.jsonl": "#{all_jsonl}\n",
    ".arvo/dossier/statecharts/report.json": sc_json,
    ".arvo/dossier/decisions.tsv": "ts\tphase\tdecision\twhy\tevidence\tresult\n2026-11-25T10:00:00Z\tverify\tRun full\tAll gates\tverify.jsonl\tpass\n",
    ".arvo/evidence/a_stale/e2e-report.json": "{\"build_sha\":\"old\",\"run_id\":\"stale\"}",
    ".arvo/evidence/r_e2e/e2e-report.json": e2e_json,
    ".arvo/evidence/r_e2e/login-mobile.png": "placeholder",
    ".arvo/evidence/r_e2e/home-desktop.png": "not-a-png",
    "secret.txt": "TOP_SECRET"
  })
  assert f_full.write_bytes(".arvo/evidence/r_e2e/login-mobile.png", png_sample_bytes) == Ok(Unit)

  out_res = generate_dossier("examples/starter", "", cfg, f_full, None, None, git_cmd, Env.of({}))
  assert out_res is Ok(out)
  assert out.verdict == "PASS WITH CONTRACT CHANGES"
  assert out.screenshots_embedded == 1
  assert out.pr_word_count < 150
  assert f_full.read_text(".arvo/dossier/index.html") is Ok(html_txt)
  assert html_txt.contains?("Build SHA: <code>sha_dossier_</code>")
  assert html_txt.contains?("<span class=\"pill badge-warn\">PASS WITH CONTRACT CHANGES</span>")
  assert html_txt.contains?("<span class=\"pill badge-pass\">PASS</span>")
  assert html_txt.contains?("<span class=\"pill badge-warn\">WARN</span>")
  assert html_txt.contains?("Run <code>r_e2e</code>")
  assert html_txt.contains?("1. Tamper Alert Banner — Contract Changed")
  assert html_txt.contains?("specs/a.feature.md")
  assert html_txt.contains?("2. Visual-First Proof Strip")
  assert html_txt.contains?("data:image/png;base64,#{bytes_to_base64(png_sample_bytes)}")
  assert html_txt.contains?("Image unreadable: .arvo/evidence/r_e2e/home-desktop.png")
  assert html_txt.contains?("Image unreadable: .arvo/evidence/r_e2e/missing.png")
  assert html_txt.contains?("3. Formal Statecharts")
  assert html_txt.contains?("<pre class=\"mermaid\">stateDiagram-v2")
  assert html_txt.contains?("in sync") and html_txt.contains?("stale")
  assert html_txt.contains?("4. Adversarial &amp; Mutation Scorecard")
  assert html_txt.contains?("5. Route Security &amp; Query-Budget Matrix")
  assert html_txt.contains?("Auth Required (config)") and html_txt.contains?("Public (config)")
  assert html_txt.contains?("CSRF Enforced (config)") and html_txt.contains?("Exempt (config)")
  assert html_txt.contains?("not measured per-route")
  assert not html_txt.contains?("Inertia.escape_html")
  assert html_txt.contains?("&le; 8")
  assert html_txt.contains?("6. Decision Trail")
  assert html_txt.contains?("Attention")
  assert f_full.read_text(".arvo/dossier/pr-summary.md") is Ok(pr_txt)
  assert count_words(pr_txt) < 150
  assert pr_txt.contains?("Tier `full` (`sha_dossier_`) ran 5 checks (4 passed) in 46 ms.")
  assert pr_txt.contains?("- Strength suites: 23/23 killed")
  assert pr_txt.contains?("- Semantic probes: 5/5 caught")
  assert pr_txt.contains?("- Stryker TS: 92/100 killed")
  assert pr_txt.contains?("- Statecharts: 1/2 verified (attention required)")
  assert pr_txt.contains?("- Review statechart issues: Arvo.Session Lifecycle")
  assert pr_txt.contains?("![login-mobile](../evidence/r_e2e/login-mobile.png)")
  assert not pr_txt.contains?("home-desktop.png")
  assert not pr_txt.contains?("missing.png")
  assert pr_txt.contains?("Review modified contracts: specs/a.feature.md")

  # Word cap and traversal rejection checks (D1/D2/security)
  assert not valid_evidence_png_path?("../../secret.txt")
  assert not valid_evidence_png_path?(".arvo/evidence/../secret.png")
  assert not png_magic?("notpng123".bytes)
  huge_sc = StatechartView(present?: true, ok?: true, replay_detail: "ok", charts: [])
  var huge_evs = []
  var hi = 0
  while hi < 40
    var he = Dossier.new_event("t", "full", "phase_#{hi}_long_name_for_word_cap_testing", "fail", 1)
    he.detail = Some("long failure detail")
    huge_evs = huge_evs.append(he)
    hi += 1
  end
  big_pr = render_pr_summary("full", "sha_big", 100, huge_evs, empty_e2e_view(), huge_sc)
  assert count_words(big_pr) < 150

  # 5. Clean PASS path (with tamper_check pass, sparse e2e/statechart defaults, empty chart list, corrupt fallbacks)
  ev_clean = [
    Dossier.new_event("2026-11-25T10:00:00Z", "fast", "mo_test", "pass", 42),
    Dossier.new_event("2026-11-25T10:00:00Z", "fast", "tamper_check", "pass", 0)
  ]
  f_clean = Files.in_memory({})
  assert generate_dossier(
    ".",
    "fast",
    Config.default_config(),
    f_clean,
    Some(ev_clean),
    Some(42),
    git_cmd,
    Env.of({})
  ) is
    Ok(clean_out)
  assert clean_out.verdict == "PASS" and
    clean_out.screenshots_embedded == 0 and
    clean_out.pr_word_count < 150
  assert f_clean.read_text(".arvo/dossier/index.html") is Ok(clean_html)
  assert clean_html.contains?("<span class=\"pill badge-pass\">PASS</span>")
  assert clean_html.contains?("0 contract edits — all tamper-protected files match baseline")
  assert clean_html.contains?("No open automated failures or contract changes")
  assert f_clean.read_text(".arvo/dossier/pr-summary.md") is Ok(clean_pr)
  assert clean_pr.contains?("None — automated checks passed cleanly.")
  assert not clean_pr.contains?("\n\n\n")

  # 5b. Top-level e2e-report.json with sparse fields + sidecar json + sparse statechart chart & empty charts
  f_sparse = Files.in_memory({
    ".arvo/evidence/ignored.json": "{}",
    ".arvo/evidence/e2e-report.json": "{\"run_id\":\"top_run\"}",
    ".arvo/dossier/statecharts/report.json": "{\"ok\":true,\"charts\":[{\"title\":\"Sparse\"}]}"
  })
  assert generate_dossier(
    ".",
    "fast",
    Config.default_config(),
    f_sparse,
    Some(ev_clean),
    None,
    git_cmd,
    Env.of({})
  ) is
    Ok(_)
  assert f_sparse.read_text(".arvo/dossier/index.html") is Ok(sp_html)
  assert sp_html.contains?("Run <code>top_run</code>")
  assert sp_html.contains?(
    "Axe violations: <strong>0</strong> · Console/Page/5xx/Assets: <strong>0/0/0/0</strong> · DB checks: <strong>0</strong> · Visual diff px: <strong>0</strong>"
  )
  assert sp_html.contains?(
    "States: <strong>0</strong> · Transitions: <strong>0</strong> · Violations: <strong>0</strong> · Broken variant caught: <strong>false</strong>"
  )
  assert sp_html.contains?("<span class=\"pill badge-fail\">stale")

  f_corrupt = Files.in_memory({
    ".arvo/evidence/e2e-report.json": "{bad",
    ".arvo/dossier/statecharts/report.json": "{\"ok\":true,\"charts\":[]}"
  })
  assert generate_dossier(
    ".",
    "fast",
    Config.default_config(),
    f_corrupt,
    Some([]),
    Some(0),
    git_cmd,
    Env.of({})
  ) is
    Ok(inc_out)
  assert inc_out.verdict == "INCONCLUSIVE"
  assert f_corrupt.read_text(".arvo/dossier/index.html") is Ok(cor_html)
  assert cor_html.contains?("No Playwright E2E evidence recorded")
  assert cor_html.contains?("No statechart report found")
  assert not cor_html.contains?("No open automated failures")

  # 5c. render_pr_summary defaults, empty views & 5-contract truncation
  ee = empty_e2e_view()
  assert not ee.present? and
    ee.axe_count == 0 and
    ee.console_errors == 0 and
    ee.page_errors == 0 and
    ee.http_5xx == 0 and
    ee.broken_assets == 0 and
    ee.db_checks_passed == 0 and
    ee.visual_diff_pixels == 0
  es = empty_statechart_view()
  assert not es.present?
  ev_zero_m = Dossier.new_event("t", "full", "mo_mutants", "pass", 1)
  ev_zero_s = Dossier.new_event("t", "full", "mo_strength", "pass", 1)
  ev_zero_p = Dossier.new_event("t", "full", "semantic_mutants", "pass", 1)
  ev_zero_st = Dossier.new_event("t", "full", "stryker", "pass", 1)
  var ev_many_mods = Dossier.new_event("t", "full", "tamper_check", "warn", 1)
  ev_many_mods.modified_contracts = Some(["c1", "c2", "c3", "c4", "c5", "c6"])
  pr_many = render_pr_summary(
    "full",
    "sha_1234567890",
    99,
    [ev_zero_m, ev_zero_s, ev_zero_p, ev_zero_st, ev_many_mods],
    empty_e2e_view(),
    empty_statechart_view()
  )
  assert pr_many.contains?("- Mo mutants: 0/0 killed")
  assert pr_many.contains?("- Strength suites: 0/0 killed")
  assert pr_many.contains?("- Semantic probes: 0/0 caught")
  assert pr_many.contains?("- Stryker TS: 0/0 killed")
  assert pr_many.contains?("c1, c2, c3, c4, c5")
  assert not pr_many.contains?("c6")

  # 6. Warn-without-paths & Fail verdicts + missing/corrupt verify.jsonl error cases
  ev_warn_empty = [Dossier.new_event("t", "full", "tamper_check", "warn", 1)]
  f_w = Files.in_memory({})
  assert generate_dossier(
    ".",
    "full",
    Config.default_config(),
    f_w,
    Some(ev_warn_empty),
    Some(1),
    git_cmd,
    Env.of({})
  ) is
    Ok(w_out)
  assert w_out.verdict == "PASS WITH CONTRACT CHANGES"
  assert f_w.read_text(".arvo/dossier/index.html") is Ok(wh) and
    wh.contains?("Contract baseline warning detected")

  ev_fail = [Dossier.new_event("t", "full", "mo_mutants", "fail", 1)]
  f_f = Files.in_memory({})
  assert generate_dossier(
    ".",
    "full",
    Config.default_config(),
    f_f,
    Some(ev_fail),
    Some(1),
    git_cmd,
    Env.of({})
  ) is
    Ok(f_out)
  assert f_out.verdict == "FAIL"
  assert f_f.read_text(".arvo/dossier/index.html") is Ok(fh) and
    fh.contains?("<span class=\"pill badge-fail\">FAIL</span>")
  assert f_f.read_text(".arvo/dossier/pr-summary.md") is Ok(fpr) and
    fpr.contains?("Fix failed phases: mo_mutants")

  assert generate_dossier(".", "fast", cfg, Files.in_memory({}), None, None, git_cmd, Env.of({})) is
    Error(_)
  assert generate_dossier(
    ".",
    "fast",
    cfg,
    Files.in_memory({".arvo/dossier/verify.jsonl": "bad\n"}),
    None,
    None,
    git_cmd,
    Env.of({})
  ) is
    Error(_)
  assert generate_dossier(
    ".",
    "fast",
    cfg,
    Files.in_memory({".arvo": "blocker"}),
    Some(ev_clean),
    Some(1),
    git_cmd,
    Env.of({})
  ) is
    Error(_)
end
