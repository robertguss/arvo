## Tamper-guarded golden JSON and text snapshot assertions with deterministic key sorting
## and volatile-field redaction (`ARVO_UPDATE_SNAPSHOTS=1` required to update baselines).
module Arvo.Snapshot
expose SnapshotOptions(..),
default_options,
canonicalize,
update_enabled?,
snapshot_path,
format_diff,
check_json,
check_text,
assert_json,
assert_text
use Json

## Canonicalization options for JSON snapshot comparisons.
struct SnapshotOptions
  redact_keys: List(Text)
  sort_object_keys?: Bool
end

## Default snapshot options redacting `id`, timestamps, and `csrf_token`, with sorted object keys.
fn default_options() : SnapshotOptions
  SnapshotOptions(
    redact_keys: ["id", "created_at", "updated_at", "csrf_token"],
    sort_object_keys?: true
  )
end

## Recursively canonicalizes `value` by redacting matching keys and optionally sorting object keys.
fn canonicalize(value: Json, opts: SnapshotOptions) : Json
  examples
    canonicalize(
      Json.Object({"b": Json.int(1), "id": Json.String("abc"), "a": Json.int(2)}),
      default_options()
    ).to_text ==
      "{\"a\":2,\"b\":1,\"id\":\"<REDACTED>\"}"
    canonicalize(Json.Array([Json.Object({"csrf_token": Json.String("sec")})]), default_options())
      .to_text ==
      "[{\"csrf_token\":\"<REDACTED>\"}]"
    canonicalize(
      Json.Object({"b": Json.int(1), "a": Json.int(2)}),
      SnapshotOptions(redact_keys: [], sort_object_keys?: false)
    ).to_text ==
      "{\"b\":1,\"a\":2}"
  end

  case value
    Json.Object(entries):
      raw_pairs = entries.entries
      ordered = if opts.sort_object_keys?
        raw_pairs.sort_by(fn(pair) pair.0 end)
      else
        raw_pairs
      end
      var out = {}
      for (k, v) in ordered
        if opts.redact_keys.contains?(k)
          out = out.set(k, Json.String("<REDACTED>"))
        else
          out = out.set(k, canonicalize(v, opts))
        end
      end
      Json.Object(out)
    Json.Array(items): Json.Array(items.map(fn(item) canonicalize(item, opts) end))
    Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_): value
  end
end

## Whether snapshot updates are explicitly authorized via `ARVO_UPDATE_SNAPSHOTS=1`
## and `CI` is not active.
fn ci_active?(env: Env) : Bool
  case env.get("CI")
    None: false
    Some(raw):
      v = raw.trim.ascii_lowercase
      not v.empty? and v != "0" and v != "false" and v != "no"
  end
end

fn update_enabled?(env: Env) : Bool
  not ci_active?(env) and env.get("ARVO_UPDATE_SNAPSHOTS") == Some("1")
end

fn safe_snapshot_name?(name: Text) : Bool
  examples
    safe_snapshot_name?("bills/home")
    not safe_snapshot_name?("")
    not safe_snapshot_name?(" bills/home ")
    not safe_snapshot_name?("/abs/path")
    not safe_snapshot_name?("a\\b")
    not safe_snapshot_name?("a//b")
    not safe_snapshot_name?("a/./b")
    not safe_snapshot_name?("../escape")
  end

  trimmed = name.trim
  return false if trimmed.empty? or trimmed != name
  return false if trimmed.starts_with?("/") or trimmed.contains?("\\")
  for seg in trimmed.split("/")
    return false if seg.empty? or seg == "." or seg == ".."
  end
  true
end

## Resolves the relative golden snapshot path under `snapshots/`.
fn snapshot_path(name: Text, ext: Text) : Text
  examples
    snapshot_path("home_props", "json") == "snapshots/home_props.snap.json"
    snapshot_path("bills/table", "txt") == "snapshots/bills/table.snap.txt"
  end

  "snapshots/#{name}.snap.#{ext}"
end

fn parent_folder(path: Text) : Text
  parts = path.split("/")
  if parts.size <= 1
    "."
  else
    parts.take(parts.size - 1).join("/")
  end
end

## Formats a concise line-oriented diff message for a snapshot mismatch.
fn format_diff(path: Text, expected: Text, actual: Text) : Text
  exp_lines = expected.lines
  act_lines = actual.lines
  max_len = exp_lines.size.max(act_lines.size)
  var diff_line = 0
  var exp_snip = ""
  var act_snip = ""
  for idx in 0..max_len
    e_line = exp_lines.get(idx) or "<EOF>"
    a_line = act_lines.get(idx) or "<EOF>"
    if e_line != a_line
      diff_line = idx + 1
      exp_snip = e_line
      act_snip = a_line
      break
    end
  end
  if diff_line == 0
    return "snapshot mismatch at #{path} (whitespace/trailing newline differs); set ARVO_UPDATE_SNAPSHOTS=1 to update"
  end
  "snapshot mismatch at #{path} (line #{diff_line}):\n  expected: #{exp_snip}\n  actual:   #{act_snip}\nTo update snapshots intentionally, run with ARVO_UPDATE_SNAPSHOTS=1."
end

fn compare_or_update(files: Files, env: Env, path: Text, actual: Text) : Result(Unit, Text)
  if update_enabled?(env)
    try files.make_folder(parent_folder(path)).map_error(fn(e) "#{e}" end)
    return files.write_text(path, actual).map_error(fn(e) "#{e}" end)
  end

  case files.read_text(path)
    Ok(expected):
      if expected == actual
        Ok(Unit)
      else
        Error(format_diff(path, expected, actual))
      end
    Error(NotFound(path: _)): Error(
      "missing snapshot #{path}. Re-run with ARVO_UPDATE_SNAPSHOTS=1 to record baseline."
    )
    Error(other): Error("failed reading snapshot #{path}: #{other}")
  end
end

## Checks `value` (canonicalized with `opts`) against `snapshots/<name>.snap.json`, updating only when `ARVO_UPDATE_SNAPSHOTS=1`.
fn check_json(files: Files, env: Env, name: Text, value: T, opts: SnapshotOptions) : Result(
  Unit,
  Text
)
  where T: Json
  if not safe_snapshot_name?(name)
    return Error("invalid snapshot name '#{name}': path traversal or empty segments are forbidden")
  end
  actual = "#{canonicalize(value.to_json, opts).pretty}\n"
  compare_or_update(files, env, snapshot_path(name, "json"), actual)
end

## Checks `value` against `snapshots/<name>.snap.txt`, updating only when `ARVO_UPDATE_SNAPSHOTS=1`.
fn check_text(files: Files, env: Env, name: Text, value: Text) : Result(Unit, Text)
  if not safe_snapshot_name?(name)
    return Error("invalid snapshot name '#{name}': path traversal or empty segments are forbidden")
  end
  compare_or_update(files, env, snapshot_path(name, "txt"), value)
end

fn fail_snapshot(detail: Text) : Unit
  _ = detail
  stop "snapshot assertion failed"
end

## Asserts `value` matches `snapshots/<name>.snap.json` (or updates when `ARVO_UPDATE_SNAPSHOTS=1`).
fn assert_json(files: Files, env: Env, name: Text, value: T, opts: SnapshotOptions) : Unit
  where T: Json
  case check_json(files, env, name, value, opts)
    Ok(_): Unit
    Error(msg): fail_snapshot(msg)
  end
end

## Asserts `value` matches `snapshots/<name>.snap.txt` (or updates when `ARVO_UPDATE_SNAPSHOTS=1`).
fn assert_text(files: Files, env: Env, name: Text, value: Text) : Unit
  case check_text(files, env, name, value)
    Ok(_): Unit
    Error(msg): fail_snapshot(msg)
  end
end

struct SampleSnap
  id: Text
  zeta: Int
  alpha: Text
  created_at: Text
  nested: List(Map(Text, Text))
end

test "Snapshot fails on missing or mismatched baselines, updates only with ARVO_UPDATE_SNAPSHOTS=1, and redacts volatile fields"
  files = Files.in_memory({})
  read_env = Env.of({})
  write_env = Env.of({"ARVO_UPDATE_SNAPSHOTS": "1"})
  assert not update_enabled?(read_env)
  assert update_enabled?(write_env)
  assert not update_enabled?(Env.of({"CI": "true", "ARVO_UPDATE_SNAPSHOTS": "1"}))
  assert not update_enabled?(Env.of({"CI": "1", "ARVO_UPDATE_SNAPSHOTS": "1"}))
  assert update_enabled?(Env.of({"CI": "false", "ARVO_UPDATE_SNAPSHOTS": "1"}))
  assert parent_folder("plain.txt") == "."
  assert parent_folder("snapshots/a") == "snapshots"
  assert parent_folder("snapshots/sub/a.snap.json") == "snapshots/sub"

  sample1 = SampleSnap(
    id: "id_111",
    zeta: 9,
    alpha: "ok",
    created_at: "2026-01-01T00:00:00Z",
    nested: [{"csrf_token": "tok_a", "title": "Rent"}]
  )
  sample2 = SampleSnap(
    id: "id_999",
    zeta: 9,
    alpha: "ok",
    created_at: "2026-12-31T23:59:59Z",
    nested: [{"csrf_token": "tok_b", "title": "Rent"}]
  )

  assert check_json(files, write_env, "../escape", sample1, default_options()) is Error(_)
  assert check_text(files, write_env, "/abs/path", "hi") is Error(_)
  assert check_text(files, Env.of({"CI": "true", "ARVO_UPDATE_SNAPSHOTS": "1"}), "bills/ci_guard", "hi") is
    Error(_)

  # Missing baseline fails when ARVO_UPDATE_SNAPSHOTS is unset
  assert check_json(files, read_env, "bills/home", sample1, default_options()) is Error(miss_msg)
  assert miss_msg.contains?("snapshots/bills/home.snap.json")
  assert miss_msg.contains?("ARVO_UPDATE_SNAPSHOTS=1")

  # Updating writes canonical sorted JSON with redacted volatile keys
  assert check_json(files, write_env, "bills/home", sample1, default_options()) == Ok(Unit)
  assert_json(files, read_env, "bills/home", sample2, default_options())

  # Different non-redacted value fails with diff
  changed = SampleSnap(
    id: "id_999",
    zeta: 10,
    alpha: "ok",
    created_at: "2026-12-31T23:59:59Z",
    nested: [{"csrf_token": "tok_b", "title": "Rent"}]
  )
  assert check_json(files, read_env, "bills/home", changed, default_options()) is Error(diff_msg)
  assert diff_msg.contains?("line ")
  assert diff_msg.contains?("\"zeta\": 9")
  assert diff_msg.contains?("\"zeta\": 10")

  assert format_diff("a.txt", "line1\nline2\n", "line1\n").contains?("(line 2)")
  assert format_diff("a.txt", "line1\nline2\n", "line1\n").contains?("<EOF>")
  assert format_diff("a.txt", "same", "same\n").contains?("whitespace/trailing newline differs")

  # Unreadable directory-as-file triggers non-NotFound read error branch
  bad_files = Files.in_memory({"snapshots/broken.snap.txt/nested": "x"})
  assert check_text(bad_files, read_env, "broken", "hi") is Error(bad_err)
  assert bad_err.contains?("failed reading snapshot")

  # Text snapshots follow the same tamper guard
  assert check_text(files, read_env, "summary", "due: $145.00\n") is Error(_)
  assert check_text(files, write_env, "summary", "due: $145.00\n") == Ok(Unit)
  assert_text(files, read_env, "summary", "due: $145.00\n")
  assert check_text(files, read_env, "summary", "due: $200.00\n") is Error(txt_diff)
  assert txt_diff.contains?("(line 1)")
  assert txt_diff.contains?("due: $145.00")
end
