## Zero-Chromium E2E evidence, pixel visual-regression, and SEO `<head>` assertion helpers
## built on `Mobrowse.Arvo` for headless Mo verification and `arvo verify` / `arvo dossier`.
module Arvo.Mobrowse.E2e
expose SeoHeadReport(..),
ViewportSpec(..),
VisualCheckEntry(..),
EvidenceRun(..),
EvidenceSummary(..),
default_viewports,
meta_content,
canonical_href,
json_ld_scripts,
inspect_seo_head,
assert_seo_head,
new_run,
record_scenario,
record_db_check,
capture_page,
finalize_report
use Json
use Mobrowse.Arvo
use Mobrowse.Dom
use Mobrowse.Html
use Mobrowse.Png
use Mobrowse.Raster
use Mobrowse.Session

## Parsed SEO, social-unfurl, canonical link, structured JSON-LD, and asset health report for `<head>`.
struct SeoHeadReport
  title: Text
  description: Option(Text)
  canonical: Option(Text)
  og_title: Option(Text)
  og_description: Option(Text)
  og_image: Option(Text)
  robots: Option(Text)
  json_ld: List(Text)
  broken_assets: List(Text)
end

## Named viewport geometry (`desktop`, `mobile`, etc.) used by `capture_page`.
struct ViewportSpec
  name: Text
  width: Float
  height: Float
end

## One visual-diff or baseline-update check recorded in `e2e-report.json`.
struct VisualCheckEntry
  label: Text
  viewport: Text
  diff_pixels: Int
  diff_ratio: Float
  updated?: Bool
  baseline_path: Text
  actual_path: Text
end

## Mutable-style accumulator holding Playwright-compatible `arvo verify` E2E evidence.
struct EvidenceRun
  run_id: Text
  build_sha: Text
  console_errors: List(Text)
  page_errors: List(Text)
  http_5xx: List(Text)
  broken_assets: List(Text)
  overflow_errors: List(Text)
  visual_checks: List(VisualCheckEntry)
  visual_diff_pixels: Int
  db_checks_passed: Int
  viewports_seen: List(Text)
  screenshots: List(Text)
  aria_files: List(Text)
  scenarios_passed: List(Text)
end

## Summary returned after writing `.arvo/evidence/<run_id>/e2e-report.json`.
struct EvidenceSummary
  report_path: Text
  passed?: Bool
  scenarios_count: Int
  screenshots_count: Int
  aria_count: Int
  visual_diff_pixels: Int
  db_checks_passed: Int
end

## Default desktop (`1280x800`) and mobile (`390x844`) viewports matching `ArvoConfig`.
fn default_viewports() : List(ViewportSpec)
  [
    ViewportSpec(name: "desktop", width: 1280.0, height: 800.0),
    ViewportSpec(name: "mobile", width: 390.0, height: 844.0)
  ]
end

## Extracts the `content` attribute of a `<meta name="...">` or `<meta property="...">` element.
fn meta_content(b: Arvo.ArvoBrowser, name_or_prop: Text) : Option(Text)
  target = name_or_prop.trim.ascii_lowercase
  return None if target.empty?
  for mid in Dom.find_by_tag(b.view.doc, "meta")
    mname = (Dom.attr(b.view.doc, mid, "name") or "").trim.ascii_lowercase
    mprop = (Dom.attr(b.view.doc, mid, "property") or "").trim.ascii_lowercase
    if mname == target or mprop == target
      if Dom.attr(b.view.doc, mid, "content") is Some(raw)
        return Some(raw.trim)
      end
    end
  end
  None
end

## Extracts the non-empty `href` of `<link rel="canonical" href="...">`, if present.
fn canonical_href(b: Arvo.ArvoBrowser) : Option(Text)
  for lid in Dom.find_by_tag(b.view.doc, "link")
    rel = (Dom.attr(b.view.doc, lid, "rel") or "").ascii_lowercase
    if rel.words.contains?("canonical")
      if Dom.attr(b.view.doc, lid, "href") is Some(href)
        trimmed = href.trim
        return Some(trimmed) if not trimmed.empty?
      end
    end
  end
  None
end

fn tag_declares_json_ld?(tag_hdr: Text) : Bool
  norm = tag_hdr.ascii_lowercase.replace("'", "\"").replace(" ", "").replace("\t", "").replace("\n", "")
  norm.contains?("type=\"application/ld+json\"") or
    norm.contains?("type=\"application/ld+json;") or
    norm.contains?("type=application/ld+json")
end

## Returns non-empty trimmed bodies of `<script type="application/ld+json">` tags from `b.view.state.html`.
fn json_ld_scripts(b: Arvo.ArvoBrowser) : List(Text)
  var out = []
  # Mobrowse Html.parse drops text children for non-JS <script> blocks, so scan state.html directly.
  pieces = b.view.state.html.split("<")
  var in_script? = false
  var keep_cur? = false
  var body_parts = []
  var i = 1
  while i < pieces.size
    p = pieces.get(i) or ""
    low = p.ascii_lowercase
    if in_script?
      next_ch = low.chars.get(7)
      is_close? = low.starts_with?("/script") and
        (next_ch == Some('>') or
          next_ch == Some(' ') or
          next_ch == Some('\t') or
          next_ch == Some('\n') or
          next_ch == Some('\r'))
      if is_close?
        if keep_cur?
          body = body_parts.join("").trim
          if not body.empty?
            out = out.append(body)
          end
        end
        in_script? = false
        keep_cur? = false
        body_parts = []
      else
        body_parts = body_parts.append("<#{p}")
      end
    else if low.starts_with?("script") and p.contains?(">")
      next_ch = low.chars.get(6)
      is_open? = next_ch == Some('>') or
        next_ch == Some(' ') or
        next_ch == Some('\t') or
        next_ch == Some('\n') or
        next_ch == Some('\r') or
        next_ch == Some('/')
      if is_open?
        gt_parts = p.split(">")
        tag_hdr = gt_parts.first or ""
        if not tag_hdr.trim_end.ends_with?("/")
          in_script? = true
          keep_cur? = tag_declares_json_ld?(tag_hdr)
          body_parts = [gt_parts.drop(1).join(">")]
        end
      end
    end
    i += 1
  end
  out
end

## Collects `<title>`, meta description, canonical link, OpenGraph tags, robots, JSON-LD, and asset errors.
fn inspect_seo_head(b: Arvo.ArvoBrowser) : SeoHeadReport
  SeoHeadReport(
    title: Arvo.title(b),
    description: meta_content(b, "description"),
    canonical: canonical_href(b),
    og_title: meta_content(b, "og:title"),
    og_description: meta_content(b, "og:description"),
    og_image: meta_content(b, "og:image"),
    robots: meta_content(b, "robots"),
    json_ld: json_ld_scripts(b),
    broken_assets: Arvo.broken_assets(b)
  )
end

## Verifies SEO `<head>` metadata (`title_contains`, optional `desc_contains`, optional `canonical`) and clean assets.
fn assert_seo_head(
  b: Arvo.ArvoBrowser,
  title_contains: Text,
  desc_contains: Option(Text),
  canonical: Option(Text)
) : Result(SeoHeadReport, Text)
  rep = inspect_seo_head(b)
  if not rep.broken_assets.empty?
    return Error("broken assets on '#{Arvo.path(b)}': #{rep.broken_assets.join(", ")}")
  end
  t_need = title_contains.trim
  if not t_need.empty? and not rep.title.contains?(t_need)
    return Error("page title '#{rep.title}' does not contain '#{t_need}'")
  end
  if desc_contains is Some(d_need)
    case rep.description
      None: return Error("missing <meta name=\"description\"> on '#{Arvo.path(b)}'")
      Some(d_got):
        if not d_got.contains?(d_need)
          return Error("meta description '#{d_got}' does not contain '#{d_need}'")
        end
    end
  end
  if canonical is Some(c_need)
    case rep.canonical
      None: return Error("missing <link rel=\"canonical\"> on '#{Arvo.path(b)}'")
      Some(c_got):
        if c_got != c_need
          return Error("canonical href '#{c_got}' != expected '#{c_need}'")
        end
    end
  end
  Ok(rep)
end

## Starts an empty `EvidenceRun` tied to `run_id` and `build_sha` for `arvo verify`.
fn new_run(run_id: Text, build_sha: Text) : EvidenceRun
  EvidenceRun(
    run_id: run_id,
    build_sha: build_sha,
    console_errors: [],
    page_errors: [],
    http_5xx: [],
    broken_assets: [],
    overflow_errors: [],
    visual_checks: [],
    visual_diff_pixels: 0,
    db_checks_passed: 0,
    viewports_seen: [],
    screenshots: [],
    aria_files: [],
    scenarios_passed: []
  )
end

## Records one completed scenario name into `run`.
fn record_scenario(run: EvidenceRun, name: Text) : EvidenceRun
  var out = run
  t = name.trim
  if not t.empty? and not out.scenarios_passed.contains?(t)
    out.scenarios_passed = out.scenarios_passed.append(t)
  end
  out
end

## Increments the verified persistence check counter (`db_checks_passed`).
fn record_db_check(run: EvidenceRun) : EvidenceRun
  var out = run
  out.db_checks_passed += 1
  out
end

fn sanitize_label(raw: Text) : Text
  kept = raw.trim.chars.map(fn(c)
    if c.ascii_letter? or c.ascii_digit? or c == '-' or c == '_': c else: '_'
  end)
  txt = Text.from_chars(kept)
  if txt.empty?: "page" else: txt
end

fn ensure_folder_tree(files: Files, dir_path: Text) : Result(Unit, Text)
  trimmed = dir_path.trim.drop_suffix("/") or dir_path.trim
  return Ok(Unit) if trimmed.empty? or trimmed == "."
  var cur = ""
  for seg in trimmed.split("/")
    continue if seg.empty?
    cur = if cur.empty?: seg else: "#{cur}/#{seg}"
    dir_now = cur
    if not files.exists?(dir_now)
      _mk = try files.make_folder(dir_now).map_error(
        fn(e) "failed creating folder '#{dir_now}': #{e}" end
      )
    end
  end
  Ok(Unit)
end

fn decode_png_to_raster(raw_png: Bytes) : Result(Raster.RasterImage, Text)
  dec = try Png.decode_png(raw_png, 8000000, 2048)
  rgba = try Png.base64_to_bytes(dec.rgba_b64).or_fail("invalid decoded baseline RGBA")
  Ok(Raster.RasterImage(width: dec.width, height: dec.height, rgba: rgba))
end

fn evidence_root(run_id: Text) : Text
  ".arvo/evidence/#{run_id}"
end

## Renders, snapshots (ARIA + PNG), checks responsive overflow & asset/JS health, and diffs optional PNG baselines.
fn capture_page(
  run: EvidenceRun,
  files: Files,
  label: Text,
  b: Arvo.ArvoBrowser,
  viewports: List(ViewportSpec),
  baseline_dir: Option(Text),
  max_channel_delta: Int,
  update_baselines?: Bool
) : Result(EvidenceRun, Text)
  var out = run
  root = evidence_root(out.run_id)
  shots_dir = "#{root}/shots"
  aria_dir = "#{root}/aria"
  try ensure_folder_tree(files, shots_dir)
  try ensure_folder_tree(files, aria_dir)
  if baseline_dir is Some(bdir)
    try ensure_folder_tree(files, bdir)
  end

  slug = sanitize_label(label)
  for vp in viewports
    if not out.viewports_seen.contains?(vp.name)
      out.viewports_seen = out.viewports_seen.append(vp.name)
    end
    resized = Arvo.with_viewport(b, vp.width, vp.height)

    if Arvo.status(resized) >= 500
      out.http_5xx = out.http_5xx.append(
        "#{label} (#{vp.name}): HTTP #{Arvo.status(resized)} on #{Arvo.path(resized)}"
      )
    end
    for ba in Arvo.broken_assets(resized)
      entry = "#{label} (#{vp.name}): #{ba}"
      if not out.broken_assets.contains?(entry)
        out.broken_assets = out.broken_assets.append(entry)
      end
    end
    for se in Arvo.script_errors(resized)
      entry = "#{label} (#{vp.name}): #{se}"
      if not out.page_errors.contains?(entry)
        out.page_errors = out.page_errors.append(entry)
      end
    end
    if Arvo.has_horizontal_overflow?(resized)
      ovs = Arvo.overflowing_nodes(resized)
      out.overflow_errors = out.overflow_errors.append(
        "#{label} (#{vp.name}): horizontal overflow in #{ovs.size} node(s)"
      )
    end

    snap_rel = "#{aria_dir}/#{slug}-#{vp.name}.txt"
    try files.write_text(snap_rel, Arvo.snapshot_text(resized)).map_error(
      fn(e) "failed writing '#{snap_rel}': #{e}" end
    )
    out.aria_files = out.aria_files.append(snap_rel)

    shot_rel = "#{shots_dir}/#{slug}-#{vp.name}.png"
    png_bytes = Arvo.screenshot_png(resized)
    try files.write_bytes(shot_rel, png_bytes).map_error(
      fn(e) "failed writing '#{shot_rel}': #{e}" end
    )
    out.screenshots = out.screenshots.append(shot_rel)

    if baseline_dir is Some(bdir)
      clean_bdir = (bdir.trim.drop_suffix("/") or bdir.trim)
      base_rel = "#{clean_bdir}/#{slug}-#{vp.name}.png"
      need_write? = update_baselines? or not files.exists?(base_rel)
      if need_write?
        try files.write_bytes(base_rel, png_bytes).map_error(
          fn(e) "failed writing baseline '#{base_rel}': #{e}" end
        )
        out.visual_checks = out.visual_checks.append(
          VisualCheckEntry(
            label: "#{slug}-#{vp.name}",
            viewport: vp.name,
            diff_pixels: 0,
            diff_ratio: 0.0,
            updated?: true,
            baseline_path: base_rel,
            actual_path: shot_rel
          )
        )
      else
        base_bytes = try files.read_only.read_bytes(base_rel).map_error(
          fn(e) "failed reading baseline '#{base_rel}': #{e}" end
        )
        base_img = try decode_png_to_raster(base_bytes)
        actual_img = Arvo.screenshot_image(resized)
        if base_img.width != actual_img.width or base_img.height != actual_img.height
          px_diff = actual_img.width * actual_img.height
          out.visual_diff_pixels += px_diff
          out.visual_checks = out.visual_checks.append(
            VisualCheckEntry(
              label: "#{slug}-#{vp.name}",
              viewport: vp.name,
              diff_pixels: px_diff,
              diff_ratio: 1.0,
              updated?: false,
              baseline_path: base_rel,
              actual_path: shot_rel
            )
          )
        else
          diff = Arvo.diff_screenshots(base_img, actual_img, max_channel_delta)
          out.visual_diff_pixels += diff.diff_pixels
          out.visual_checks = out.visual_checks.append(
            VisualCheckEntry(
              label: "#{slug}-#{vp.name}",
              viewport: vp.name,
              diff_pixels: diff.diff_pixels,
              diff_ratio: diff.diff_ratio,
              updated?: false,
              baseline_path: base_rel,
              actual_path: shot_rel
            )
          )
        end
      end
    end
  end
  Ok(out)
end

## Writes `.arvo/evidence/<run_id>/e2e-report.json` matching `arvo verify`'s `browser_e2e` schema.
fn finalize_report(run: EvidenceRun, files: Files) : Result(EvidenceSummary, Text)
  root = evidence_root(run.run_id)
  try ensure_folder_tree(files, root)
  report_path = "#{root}/e2e-report.json"

  all_page_errs = run.page_errors.concat(run.overflow_errors)
  passed? = run.console_errors.empty? and
    all_page_errs.empty? and
    run.http_5xx.empty? and
    run.broken_assets.empty? and
    not run.screenshots.empty? and
    not run.aria_files.empty?

  vc_json = Json.Array(
    run.visual_checks.map(fn(vc)
      Json.Object({
        "label": Json.String(vc.label),
        "viewport": Json.String(vc.viewport),
        "diff_pixels": Json.int(vc.diff_pixels),
        "diff_ratio": vc.diff_ratio.to_json,
        "updated": Json.Boolean(vc.updated?),
        "baseline_path": Json.String(vc.baseline_path),
        "actual_path": Json.String(vc.actual_path)
      })
    end)
  )

  doc = Json.Object({
    "build_sha": Json.String(run.build_sha),
    "engine": Json.String("mobrowse"),
    "passed": Json.Boolean(passed?),
    "console_errors": run.console_errors.to_json,
    "page_errors": all_page_errs.to_json,
    "http_5xx": run.http_5xx.to_json,
    "broken_assets": run.broken_assets.to_json,
    "axe_violations": Json.Array([]),
    "db_checks_passed": Json.int(run.db_checks_passed),
    "visual_diff_pixels": Json.int(run.visual_diff_pixels),
    "visual_checks": vc_json,
    "viewports": run.viewports_seen.to_json,
    "screenshots": run.screenshots.to_json,
    "aria_files": run.aria_files.to_json,
    "scenarios_passed": run.scenarios_passed.to_json
  })
  try files.write_text(report_path, doc.to_text).map_error(
    fn(e) "failed writing '#{report_path}': #{e}" end
  )
  Ok(
    EvidenceSummary(
      report_path: report_path,
      passed?: passed?,
      scenarios_count: run.scenarios_passed.size,
      screenshots_count: run.screenshots.size,
      aria_count: run.aria_files.size,
      visual_diff_pixels: run.visual_diff_pixels,
      db_checks_passed: run.db_checks_passed
    )
  )
end

fn synthetic_browser(raw_html: Text) : Arvo.ArvoBrowser
  doc = Html.parse(raw_html)
  b0 = Arvo.new()
  var st = b0.view.state
  st.html = raw_html
  st.url = "http://localhost/docs/guide"
  st.open_details = Dom.initial_open_details(doc)
  var out = b0
  out.view = Session.render_with_doc(st, doc)
  out
end

test "Arvo.Mobrowse.E2e inspects SEO head tags, asserts constraints, and writes verifiable evidence + baseline PNG diffs"
  html = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Arvo Docs — Web Framework for Mo</title>
      <meta name="description" content="Single-binary Inertia v2 and MoDB apps in pure Mo.">
      <meta property="og:title" content="Arvo Docs">
      <meta property="og:description" content="Pure-Mo full-stack guide.">
      <meta property="og:image" content="https://example.test/og.png">
      <meta name="robots" content="index,follow">
      <link rel="canonical" href="https://example.test/docs/guide">
      <script type="application/ld+json">{"@context":"https://schema.org","@type":"TechArticle","headline":"Arvo Docs"}</script>
    </head>
    <body>
      <main><h1>Arvo Documentation</h1><a href="/start">Get Started</a></main>
    </body>
    </html>
    """
  b = synthetic_browser(html)
  rep = inspect_seo_head(b)
  assert rep.title == "Arvo Docs — Web Framework for Mo"
  assert rep.description == Some("Single-binary Inertia v2 and MoDB apps in pure Mo.")
  assert rep.canonical == Some("https://example.test/docs/guide")
  assert rep.og_title == Some("Arvo Docs")
  assert rep.og_image == Some("https://example.test/og.png")
  assert rep.robots == Some("index,follow")
  assert rep.json_ld.size == 1
  assert (rep.json_ld.first or "").contains?("TechArticle")

  assert assert_seo_head(
    b,
    "Arvo Docs",
    Some("Inertia v2"),
    Some("https://example.test/docs/guide")
  ) is
    Ok(_)
  assert assert_seo_head(b, "Missing Title", None, None) is Error(_)
  assert assert_seo_head(b, "Arvo Docs", Some("Nonexistent"), None) is Error(_)
  assert assert_seo_head(b, "Arvo Docs", None, Some("https://wrong.test/")) is Error(_)

  assert default_viewports().size == 2
  fast_vps = [
    ViewportSpec(name: "desktop", width: 320.0, height: 200.0),
    ViewportSpec(name: "mobile", width: 240.0, height: 180.0)
  ]

  # Pass 1: create baseline PNGs in .arvo/baselines/mobrowse
  files = Files.in_memory({})
  r0 = record_db_check(record_scenario(new_run("r_base", "sha123"), "docs-seo"))
  assert capture_page(
    r0,
    files,
    "Docs Guide",
    b,
    fast_vps,
    Some(".arvo/baselines/mobrowse"),
    2,
    false
  ) is
    Ok(r1)
  assert r1.visual_checks.size == 2
  assert r1.visual_checks.all?(fn(vc) vc.updated? end)

  # Pass 2: verify identical render produces 0 diff_pixels and updated == false
  v0 = record_db_check(record_scenario(new_run("r_verify", "sha123"), "docs-seo"))
  assert capture_page(
    v0,
    files,
    "Docs Guide",
    b,
    fast_vps,
    Some(".arvo/baselines/mobrowse"),
    2,
    false
  ) is
    Ok(v1)
  assert finalize_report(v1, files) is Ok(sum)
  assert sum.passed?
  assert sum.screenshots_count == 2
  assert sum.aria_count == 2
  assert sum.visual_diff_pixels == 0
  assert files.exists?(".arvo/evidence/r_verify/e2e-report.json")
  assert files.exists?(".arvo/evidence/r_verify/shots/Docs_Guide-desktop.png")
  assert files.exists?(".arvo/evidence/r_verify/aria/Docs_Guide-mobile.txt")
  assert files.read_text(sum.report_path) is Ok(raw_json)
  assert Json.parse(raw_json) is Ok(jdoc)
  assert jdoc.text_at("engine") == Some("mobrowse")
  assert jdoc.int_at("visual_diff_pixels") == Some(0)
  assert jdoc.path("visual_checks") is Some(Json.Array(vcs)) and vcs.size == 2
end
