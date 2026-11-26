## Pure-Mo `arvo.toml` configuration parser for the `arvo` CLI.
module Config
expose Viewport(..), ArvoConfig(..), default_config, parse, load

## Responsive viewport target configured in `arvo.toml`.
struct Viewport
  name: Text
  width: Int
  height: Int
end

## Full configuration loaded from `arvo.toml` (falling back to Spec 4.2 defaults).
struct ArvoConfig
  entry: Text
  contracts_module: Text
  contracts_fn: Text
  frontend_dir: Text
  pages_dir: Text
  contracts_out: Text
  features_dir: Text
  strength_dir: Text
  public_routes: List(Text)
  csrf_exempt_routes: List(Text)
  max_queries_per_get: Int
  sim_tier1_seeds: Int
  sim_tier2_seeds: Int
  mo_mutant_min_kill_rate: Float
  ts_stryker_min_kill_rate: Float
  strength_min_kill_rate: Float
  viewports: List(Viewport)
  visual_parity_max_diff_pixels: Int
  base_ref: Option(Text)
  tamper_globs: List(Text)
end

## Spec 4.2 defaults when keys or `arvo.toml` are omitted.
fn default_config() : ArvoConfig
  ArvoConfig(
    entry: "main.mo",
    contracts_module: "Routes",
    contracts_fn: "contracts",
    frontend_dir: "frontend",
    pages_dir: "frontend/src/pages",
    contracts_out: "frontend/src/arvo.gen.ts",
    features_dir: "specs/features",
    strength_dir: "strength",
    public_routes: ["GET /login", "POST /login"],
    csrf_exempt_routes: [],
    max_queries_per_get: 10,
    sim_tier1_seeds: 200,
    sim_tier2_seeds: 5000,
    mo_mutant_min_kill_rate: 1.0,
    ts_stryker_min_kill_rate: 0.85,
    strength_min_kill_rate: 1.0,
    viewports: [
      Viewport(name: "mobile", width: 390, height: 844),
      Viewport(name: "desktop", width: 1280, height: 800)
    ],
    visual_parity_max_diff_pixels: 0,
    base_ref: None,
    tamper_globs: [
      "specs/features/**/*.feature.md",
      "snapshots/**/*",
      "strength/**/*",
      "arvo.toml",
      "frontend/stryker.config.*"
    ]
  )
end

fn strip_toml_comment(line: Text) : Text
  var chars = []
  var in_quotes? = false
  var escaped? = false
  for ch in line.chars
    if escaped?
      chars = chars.append(ch)
      escaped? = false
    else if ch == '\\' and in_quotes?
      chars = chars.append(ch)
      escaped? = true
    else if ch == '"'
      in_quotes? = not in_quotes?
      chars = chars.append(ch)
    else if ch == '#' and not in_quotes?
      break
    else
      chars = chars.append(ch)
    end
  end
  Text.from_chars(chars).trim
end

fn bracket_delta(s: Text) : Int
  var delta = 0
  var in_quotes? = false
  var escaped? = false
  for ch in s.chars
    if escaped?
      escaped? = false
    else if ch == '\\' and in_quotes?
      escaped? = true
    else if ch == '"'
      in_quotes? = not in_quotes?
    else if not in_quotes?
      if ch == '['
        delta += 1
      else if ch == ']'
        delta -= 1
      end
    end
  end
  delta
end

fn unquote_string(raw: Text) : Result(Text, Text)
  t = raw.trim
  if not t.starts_with?("\"") or not t.ends_with?("\"") or t.byte_count < 2
    return Error("expected quoted string, got '#{t}'")
  end
  inner = t.bytes.slice(1, t.byte_count - 1).decode_utf8 or ""
  Ok(inner.replace("\\\"", "\"").replace("\\\\", "\\"))
end

fn split_top_level_commas(inner: Text) : List(Text)
  var items = []
  var cur = []
  var in_quotes? = false
  var escaped? = false
  var brace_depth = 0
  for ch in inner.chars
    if escaped?
      cur = cur.append(ch)
      escaped? = false
    else if ch == '\\' and in_quotes?
      cur = cur.append(ch)
      escaped? = true
    else if ch == '"'
      in_quotes? = not in_quotes?
      cur = cur.append(ch)
    else if not in_quotes? and ch == '{'
      brace_depth += 1
      cur = cur.append(ch)
    else if not in_quotes? and ch == '}'
      brace_depth -= 1
      cur = cur.append(ch)
    else if not in_quotes? and brace_depth == 0 and ch == ','
      piece = Text.from_chars(cur).trim
      if not piece.empty?
        items = items.append(piece)
      end
      cur = []
    else
      cur = cur.append(ch)
    end
  end
  tail = Text.from_chars(cur).trim
  if not tail.empty?
    items = items.append(tail)
  end
  items
end

fn parse_string_list(raw: Text) : Result(List(Text), Text)
  t = raw.trim
  if not t.starts_with?("[") or not t.ends_with?("]")
    return Error("expected array [...], got '#{t}'")
  end
  inner = t.bytes.slice(1, t.byte_count - 1).decode_utf8 or ""
  var out = []
  for item in split_top_level_commas(inner)
    s = try unquote_string(item)
    out = out.append(s)
  end
  Ok(out)
end

fn parse_inline_viewport(raw: Text) : Result(Viewport, Text)
  t = raw.trim
  if not t.starts_with?("{") or not t.ends_with?("}")
    return Error("expected inline viewport table {...}, got '#{t}'")
  end
  inner = t.bytes.slice(1, t.byte_count - 1).decode_utf8 or ""
  var vname = ""
  var vw = 0
  var vh = 0
  for pair in split_top_level_commas(inner)
    pieces = pair.split("=")
    if pieces.size < 2
      return Error("malformed viewport entry '#{pair}'")
    end
    k = (pieces.first or "").trim
    v = pieces.drop(1).join("=").trim
    if k == "name"
      vname = try unquote_string(v)
    else if k == "width"
      vw = try v.to_int.or_fail("invalid viewport width '#{v}'")
    else if k == "height"
      vh = try v.to_int.or_fail("invalid viewport height '#{v}'")
    end
  end
  if vname.empty? or vw <= 0 or vh <= 0
    return Error("viewport requires non-empty name and positive width/height")
  end
  Ok(Viewport(name: vname, width: vw, height: vh))
end

fn parse_viewport_list(raw: Text) : Result(List(Viewport), Text)
  t = raw.trim
  if not t.starts_with?("[") or not t.ends_with?("]")
    return Error("expected viewport array, got '#{t}'")
  end
  inner = t.bytes.slice(1, t.byte_count - 1).decode_utf8 or ""
  var out = []
  for item in split_top_level_commas(inner)
    vp = try parse_inline_viewport(item)
    out = out.append(vp)
  end
  Ok(out)
end

fn join_logical_lines(toml_text: Text) : Result(List((Text, Text)), Text)
  var out = []
  var section = ""
  var buf = ""
  var depth = 0

  for raw_line in toml_text.lines
    clean = strip_toml_comment(raw_line)
    continue if clean.empty?

    if depth > 0
      buf = if buf.empty?: clean else: "#{buf} #{clean}"
      depth += bracket_delta(clean)
      if depth < 0
        return Error("unmatched ']' in arvo.toml")
      end
      if depth == 0
        out = out.append((section, buf))
        buf = ""
      end
      continue
    end

    if clean.starts_with?("[") and clean.ends_with?("]") and not clean.contains?("=")
      section = (clean.bytes.slice(1, clean.byte_count - 1).decode_utf8 or "").trim
      continue
    end

    d = bracket_delta(clean)
    if d > 0
      buf = clean
      depth = d
    else if d < 0
      return Error("unmatched ']' in arvo.toml: '#{clean}'")
    else
      out = out.append((section, clean))
    end
  end

  if depth > 0
    return Error("unclosed '[' array in arvo.toml")
  end
  Ok(out)
end

## Parses `arvo.toml` text into `ArvoConfig`.
fn parse(toml_text: Text) : Result(ArvoConfig, Text)
  entries = try join_logical_lines(toml_text)
  var cfg = default_config()

  for (section, stmt) in entries
    if not stmt.contains?("=")
      return Error("expected key = value in [#{section}], got '#{stmt}'")
    end
    parts = stmt.split("=")
    key = (parts.first or "").trim
    val = parts.drop(1).join("=").trim

    if section == "app"
      if key == "entry"
        cfg.entry = try unquote_string(val)
      else if key == "contracts_module"
        cfg.contracts_module = try unquote_string(val)
      else if key == "contracts_fn"
        cfg.contracts_fn = try unquote_string(val)
      else if key == "frontend_dir"
        cfg.frontend_dir = try unquote_string(val)
      else if key == "pages_dir"
        cfg.pages_dir = try unquote_string(val)
      else if key == "contracts_out"
        cfg.contracts_out = try unquote_string(val)
      else if key == "features_dir"
        cfg.features_dir = try unquote_string(val)
      else if key == "strength_dir"
        cfg.strength_dir = try unquote_string(val)
      end
    else if section == "testing"
      if key == "public_routes"
        cfg.public_routes = try parse_string_list(val)
      else if key == "csrf_exempt_routes"
        cfg.csrf_exempt_routes = try parse_string_list(val)
      else if key == "max_queries_per_get"
        cfg.max_queries_per_get = try val.to_int.or_fail("invalid max_queries_per_get '#{val}'")
      else if key == "sim_tier1_seeds"
        cfg.sim_tier1_seeds = try val.to_int.or_fail("invalid sim_tier1_seeds '#{val}'")
      else if key == "sim_tier2_seeds"
        cfg.sim_tier2_seeds = try val.to_int.or_fail("invalid sim_tier2_seeds '#{val}'")
      else if key == "mo_mutant_min_kill_rate"
        cfg.mo_mutant_min_kill_rate = try val.to_float.or_fail(
          "invalid mo_mutant_min_kill_rate '#{val}'"
        )
      else if key == "ts_stryker_min_kill_rate"
        cfg.ts_stryker_min_kill_rate = try val.to_float.or_fail(
          "invalid ts_stryker_min_kill_rate '#{val}'"
        )
      else if key == "strength_min_kill_rate"
        cfg.strength_min_kill_rate = try val.to_float.or_fail(
          "invalid strength_min_kill_rate '#{val}'"
        )
      else if key == "viewports"
        cfg.viewports = try parse_viewport_list(val)
      else if key == "visual_parity_max_diff_pixels"
        cfg.visual_parity_max_diff_pixels = try val.to_int.or_fail(
          "invalid visual_parity_max_diff_pixels '#{val}'"
        )
      else if key == "base_ref"
        parsed_ref = (try unquote_string(val)).trim
        cfg.base_ref = if parsed_ref.empty?: None else: Some(parsed_ref)
      end
    else if section == "testing.tamper_protected"
      if key == "globs"
        custom_globs = try parse_string_list(val)
        var merged = cfg.tamper_globs
        for g in custom_globs
          if not merged.contains?(g)
            merged = merged.append(g)
          end
        end
        cfg.tamper_globs = merged
      end
    end
  end

  Ok(cfg)
end

## Loads `arvo.toml` from `files`, returning `default_config()` if `arvo.toml` is absent.
fn load(files: ReadFiles) : Result(ArvoConfig, Text)
  case files.read_text("arvo.toml")
    Ok(text): parse(text)
    Error(NotFound(path: _)): Ok(default_config())
    Error(err): Error("failed reading arvo.toml: #{err}")
  end
end

test "Config parses Spec 4.2 arvo.toml with multiline arrays, viewports, comments, and defaults"
  sample = """
    # Starter arvo.toml
    [app]
    entry = "app.mo" # trailing comment
    contracts_module = "AppRoutes"
    contracts_fn = "page_contracts"
    frontend_dir = "web"
    pages_dir = "web/src/pages"
    contracts_out = "web/src/arvo.gen.ts"
    features_dir = "specs/features"
    strength_dir = "custom_strength"

    [testing]
    public_routes = ["GET /login\\"x", "POST /login\\\\"]
    csrf_exempt_routes = ["POST /webhooks/stripe"]
    max_queries_per_get = 8
    sim_tier1_seeds = 150
    sim_tier2_seeds = 2500
    mo_mutant_min_kill_rate = 0.95
    ts_stryker_min_kill_rate = 0.80
    strength_min_kill_rate = 1.0
    viewports = [
      { name = "mobile\\"#1", width = 390, height = 844 },
      { name = "desktop\\\\", width = 1280, height = 800 },
    ]
    visual_parity_max_diff_pixels = 2

    [testing.tamper_protected]
    globs = [
      "specs/features/**/*.feature.md",
      "snapshots/**/*",
    ]
    """
  assert parse(sample) is Ok(cfg)
  assert cfg.entry == "app.mo"
  assert cfg.contracts_module == "AppRoutes"
  assert cfg.contracts_fn == "page_contracts"
  assert cfg.frontend_dir == "web"
  assert cfg.pages_dir == "web/src/pages"
  assert cfg.contracts_out == "web/src/arvo.gen.ts"
  assert cfg.features_dir == "specs/features"
  assert cfg.strength_dir == "custom_strength"
  assert cfg.public_routes == ["GET /login\"x", "POST /login\\"]
  assert cfg.csrf_exempt_routes == ["POST /webhooks/stripe"]
  assert cfg.max_queries_per_get == 8
  assert cfg.sim_tier1_seeds == 150
  assert cfg.sim_tier2_seeds == 2500
  assert cfg.mo_mutant_min_kill_rate == 0.95
  assert cfg.ts_stryker_min_kill_rate == 0.80
  assert cfg.strength_min_kill_rate == 1.0
  assert cfg.viewports == [
    Viewport(name: "mobile\"#1", width: 390, height: 844),
    Viewport(name: "desktop\\", width: 1280, height: 800)
  ]
  assert cfg.visual_parity_max_diff_pixels == 2
  assert cfg.tamper_globs == default_config().tamper_globs
  assert parse("[testing.tamper_protected]\nglobs = []\n") is Ok(cfg_empty_globs)
  assert cfg_empty_globs.tamper_globs == default_config().tamper_globs
  assert parse(
    "[testing]\nbase_ref = \"origin/release\"\n[testing.tamper_protected]\nglobs = [\"custom/**/*\"]\n"
  ) is
    Ok(cfg_custom_tamper)
  assert cfg_custom_tamper.base_ref == Some("origin/release")
  assert cfg_custom_tamper.tamper_globs.contains?("arvo.toml")
  assert cfg_custom_tamper.tamper_globs.contains?("custom/**/*")

  def = default_config()
  assert def.max_queries_per_get == 10
  assert def.visual_parity_max_diff_pixels == 0
  assert def.sim_tier1_seeds == 200
  assert def.sim_tier2_seeds == 5000
  assert def.viewports == [
    Viewport(name: "mobile", width: 390, height: 844),
    Viewport(name: "desktop", width: 1280, height: 800)
  ]

  files_missing = Files.in_memory({}).read_only
  assert load(files_missing) == Ok(def)

  files_present = Files.in_memory({"arvo.toml": "[app]\nentry = \"\"\n"}).read_only
  assert load(files_present) is Ok(loaded)
  assert loaded.entry == ""

  assert parse("[app]\nentry = unquoted") is Error(_)
  assert parse("[app]\nentry = \"unclosed") is Error(_)
  assert parse("[app]\nentry = \"[a,b]\" # tail [") is Ok(_)
  assert parse("[testing]\nglobs = [\"unclosed\"") is Error(_)
  assert parse("[testing]\npublic_routes = ]") is Error(_)
  assert parse("[testing]\nbadline") is Error(_)
  assert parse("[testing]\npublic_routes = \"not_array\"") is Error(_)
  assert parse("[testing]\npublic_routes = \"only_end]") is Error(_)
  assert parse("[testing]\npublic_routes = [\"only_start\"") is Error(_)
  assert parse("[testing]\nviewports = \"not_array\"") is Error(_)
  assert parse("[testing]\nviewports = [\"only_start") is Error(_)
  assert parse("[testing]\nviewports = [bad_vp]") is Error(_)
  assert parse("[testing]\nviewports = [{ name = \"\", width = 10, height = 10 }]") is Error(_)
  assert parse("[testing]\nviewports = [{ name = \"m\", width = 0, height = 10 }]") is Error(_)
  assert parse("[testing]\nviewports = [{ name = \"m\", width = 10, height = 0 }]") is Error(_)
  assert parse("[testing]\nviewports = [{ width = 10 }]") is Error(_)
  assert parse("bad_no_eq]") is Error(_)
  assert parse("[testing]\nmax_queries_per_get = nope") is Error(_)
  assert parse("[testing]\nvisual_parity_max_diff_pixels = nope") is Error(_)
  assert unquote_string("\"a\"") == Ok("a")
  assert unquote_string("\"") is Error(_)
  assert unquote_string("abc\"") is Error(_)
  assert unquote_string("\"abc") is Error(_)
  assert bracket_delta("[\"a[b]\"]") == 0
  assert bracket_delta("[\"a[b\\\\\"") == 1
  assert strip_toml_comment("x = \"#kept\\\\\" # dropped") == "x = \"#kept\\\\\""
  assert parse_string_list("[unclosed") is Error(_)
  assert parse_string_list("unopened]") is Error(_)
  assert parse_string_list("x\"a\"]") is Error(_)
  assert parse_string_list("[\"a\"x") is Error(_)
  assert parse_string_list("[\"a,b\", \"c\"]") == Ok(["a,b", "c"])
  assert parse_inline_viewport("{bad") is Error(_)
  assert parse_inline_viewport("bad}") is Error(_)
  assert parse_inline_viewport("xname=\"m\",width=1,height=1}") is Error(_)
  assert parse_inline_viewport("{name=\"m\",width=1,height=1x") is Error(_)
  assert parse_inline_viewport("{name=\"tiny\",width=1,height=1}") ==
    Ok(Viewport(name: "tiny", width: 1, height: 1))
  assert parse_inline_viewport("{name=\"x\",width=10}") is Error(_)
  assert parse_inline_viewport("{name=\"x\",height=10}") is Error(_)
  assert parse_viewport_list("[{name=\"m\",width=1,height=1}") is Error(_)
  assert parse_viewport_list("bad]") is Error(_)
  assert parse_viewport_list("x{name=\"m\",width=1,height=1}]") is Error(_)
  assert parse_viewport_list("[{name=\"m\",width=1,height=1}x") is Error(_)
  assert parse_viewport_list("[{name=\"m\",width=1,height=1}]") ==
    Ok([Viewport(name: "m", width: 1, height: 1)])
end
