## Tamper-evident detection for `.feature.md` specs, snapshots, `strength/` suites,
## `arvo.toml`, and Mo `promise ... end` invariant blocks.
module Tamper
expose glob_match?,
extract_promise_blocks,
promise_blocks_changed?,
parse_git_status_paths,
detect_tampered_paths

fn match_text_glob(pat: List(Char), text: List(Char)) : Bool
  p_empty = pat.empty?
  t_empty = text.empty?
  return t_empty if p_empty
  p0 = pat.first or ' '
  if p0 == '*'
    return true if match_text_glob(pat.drop(1), text)
    return false if t_empty
    return match_text_glob(pat, text.drop(1))
  end
  return false if t_empty
  t0 = text.first or ' '
  if p0 == '?' or p0 == t0
    match_text_glob(pat.drop(1), text.drop(1))
  else
    false
  end
end

fn match_segments(pat_segs: List(Text), path_segs: List(Text)) : Bool
  return path_segs.empty? if pat_segs.empty?
  p0 = pat_segs.first or ""
  if p0 == "**"
    return true if match_segments(pat_segs.drop(1), path_segs)
    return false if path_segs.empty?
    return match_segments(pat_segs, path_segs.drop(1))
  end
  return false if path_segs.empty?
  t0 = path_segs.first or ""
  if match_text_glob(p0.chars, t0.chars)
    match_segments(pat_segs.drop(1), path_segs.drop(1))
  else
    false
  end
end

## Matches `path` against `pattern` supporting `**` (directory glob), `*`, and `?`.
fn glob_match?(pattern: Text, path: Text) : Bool
  examples
    glob_match?("specs/features/**/*.feature.md", "specs/features/bills.feature.md")
    glob_match?("specs/features/**/*.feature.md", "specs/features/nested/bills.feature.md")
    not glob_match?("specs/features/**/*.feature.md", "specs/features/README.md")
    glob_match?("snapshots/**/*", "snapshots/home.snap.json")
    glob_match?("arvo.toml", "arvo.toml")
    glob_match?("frontend/stryker.config.*", "frontend/stryker.config.mjs")
    glob_match?("a?.txt", "ab.txt")
    not glob_match?("a?.txt", "abc.txt")
    glob_match?("a*b", "ab")
    glob_match?("a*b", "axxb")
    not glob_match?("*b", "a")
  end

  pat_norm = (pattern.drop_prefix("./") or pattern).split("/").filter(fn(s) not s.empty? end)
  path_norm = (path.drop_prefix("./") or path).split("/").filter(fn(s) not s.empty? end)
  match_segments(pat_norm, path_norm)
end

fn opens_block?(trimmed: Text) : Bool
  return true if trimmed == "case" or trimmed.starts_with?("case ")
  return true if trimmed.starts_with?("for ") or trimmed.starts_with?("while ")
  if trimmed.starts_with?("if ")
    # One-line `if cond: a else: b` does not take an `end` keyword
    return not trimmed.contains?(":")
  end
  false
end

## Extracts normalized `promise ... end` block bodies from a Mo source file.
fn extract_promise_blocks(source: Text) : List(Text)
  var blocks = []
  var depth = 0
  var cur_lines = []

  for raw_line in source.lines
    trimmed = raw_line.trim
    if depth == 0
      if trimmed == "promise" or
        trimmed.starts_with?("promise ") or
        trimmed.starts_with?("promise\"")
        depth = 1
        cur_lines = [trimmed]
      end
    else
      cur_lines = cur_lines.append(trimmed)
      if opens_block?(trimmed)
        depth += 1
      else if trimmed == "end"
        depth -= 1
        if depth == 0
          blocks = blocks.append(cur_lines.join("\n"))
          cur_lines = []
        end
      end
    end
  end
  blocks
end

## True when `promise ... end` invariant blocks differ between `old_source` and `new_source`.
fn promise_blocks_changed?(old_source: Text, new_source: Text) : Bool
  extract_promise_blocks(old_source) != extract_promise_blocks(new_source)
end

## Parses changed file paths from `git status --porcelain` output.
fn parse_git_status_paths(porcelain: Text) : List(Text)
  examples
    parse_git_status_paths(
      " M routes.mo\n?? specs/features/bills.feature.md\nR  old.mo -> new.mo\n"
    ) == ["routes.mo", "specs/features/bills.feature.md", "new.mo"]
  end

  var out = []
  for raw in porcelain.lines
    continue if raw.trim.empty? or raw.chars.size < 4
    body = Text.from_chars(raw.chars.drop(3)).trim
    path = if body.contains?(" -> ")
      (body.split(" -> ").last or body).trim
    else
      body
    end
    cleaned = if path.starts_with?("\"") and path.ends_with?("\"") and path.byte_count >= 2
      path.bytes.slice(1, path.byte_count - 1).decode_utf8 or path
    else
      path
    end
    out = out.append(cleaned)
  end
  out
end

## Filters `changed_paths` against `globs`, returning sorted unique tampered paths.
fn detect_tampered_paths(changed_paths: List(Text), globs: List(Text)) : List(Text)
  changed_paths.filter(fn(p) globs.any?(fn(g) glob_match?(g, p) end) end).unique.sort
end

test "Tamper detects modified protected paths and promise block edits"
  old_mo = """
    fn add(a: Int, b: Int) : Int
      promise "positive"
        if a > 0: result > b else: true
      end
      a + b
    end
    """
  same_promise = """
    fn add(a: Int, b: Int) : Int
      promise "positive"
        if a > 0: result > b else: true
      end
      a + b + 0
    end
    """
  weakened_promise = """
    fn add(a: Int, b: Int) : Int
      promise "positive"
        true
      end
      a + b
    end
    """
  nested_if_promise = """
    fn f(x: Int) : Int
      promise "nested"
        if x > 0
          result >= 1
        else
          result <= 0
        end
        case x
          0: true
          _: false
        end
        for i in [1]
          result == i or true
        end
        while false
          false
        end
      end
      other_line_between = 1
      promise
        other_line_between == 1
      end
      x
    end
    """
  assert not promise_blocks_changed?(old_mo, same_promise)
  assert promise_blocks_changed?(old_mo, weakened_promise)
  blocks = extract_promise_blocks(nested_if_promise)
  assert blocks.size == 2
  b0 = blocks.first or ""
  assert b0.contains?("case x") and b0.contains?("for i in [1]") and b0.contains?("while false")
  assert (blocks.get(1) or "") == "promise\nother_line_between == 1\nend"

  case_only_promise = """
    fn g(x: Int) : Int
      promise
        case
          x == 0: true
          _: false
        end
        for item in [1]
          result == item
        end
        while x < 0
          false
        end
        x == 0
      end
      x
    end
    """
  cb = extract_promise_blocks(case_only_promise)
  assert cb.size == 1
  assert (cb.first or "").starts_with?("promise\n")
  assert (cb.first or "").contains?("x == 0")
  assert extract_promise_blocks("if x > 0\n  1\nend\n") == []

  assert parse_git_status_paths("     \nxyz\n") == []
  paths = parse_git_status_paths(
    "\n   \nabc\n M x\n M \"\"\n M \"\"\n M \"\n M a\"\n M \"quoted path.mo\"\n M specs/features/bills.feature.md\n M routes.mo\n?? snapshots/home.snap.json\n M specs/features/bills.feature.md\n"
  )
  assert paths.contains?("x")
  assert paths.contains?("")
  assert paths.contains?("\"")
  assert paths.contains?("a\"")
  assert paths.contains?("quoted path.mo")
  assert not paths.contains?("c")
  assert not paths.contains?("") == false
  globs = ["specs/features/**/*.feature.md", "snapshots/**/*"]
  assert detect_tampered_paths(paths, globs) == [
    "snapshots/home.snap.json",
    "specs/features/bills.feature.md"
  ]
end
