## Offline sanitized failure capture and standalone regression test generator (Spec Part 2.9).
## Strips Cookie, Set-Cookie, Authorization, CSRF tokens, and secret environment variables at capture time.
module Arvo.Replay
expose RedactedRequest(..),
FailureBundle(..),
sensitive_header?,
sensitive_env_key?,
redact_headers,
redact_env,
redact_request,
capture_bundle,
encode_bundle,
decode_bundle,
generate_regression_test
use Api
use Arvo.Audit
use Arvo.Jobs
use Json

## HTTP request snapshot with authentication cookies, CSRF headers, and credentials redacted.
struct RedactedRequest
  method: Text
  path: Text
  headers: List((Text, Text))
  body_text: Text
end

## Sanitized offline failure artifact captured from a failing HTTP route, job, or invariant check.
struct FailureBundle
  id: Text
  captured_at: Text
  app_commit: Text
  kind: Text
  request: Option(RedactedRequest)
  job_record: Option(Jobs.JobRecord)
  recent_events: List(Audit.AuditEntry)
  env_sanitized: Map(Text, Text)
  sqlite_snapshot_path: Option(Text)
  error_message: Text
end

## Returns `true` when HTTP header `name` carries credentials, cookies, or CSRF tokens.
fn sensitive_header?(name: Text) : Bool
  examples
    sensitive_header?("Cookie")
    sensitive_header?("authorization")
    sensitive_header?("X-XSRF-TOKEN")
    sensitive_header?("X-CSRF-TOKEN")
    sensitive_header?("Set-Cookie")
    sensitive_header?("X-API-Key")
    not sensitive_header?("Content-Type")
    not sensitive_header?("Accept")
  end

  lower = name.trim.ascii_lowercase
  lower == "cookie" or
    lower == "set-cookie" or
    lower == "authorization" or
    lower == "proxy-authorization" or
    lower == "x-xsrf-token" or
    lower == "x-csrf-token" or
    lower == "x-api-key"
end

## Returns `true` when environment variable `key` should be redacted.
fn sensitive_env_key?(key: Text) : Bool
  examples
    sensitive_env_key?("ARVO_SECRET_KEY")
    sensitive_env_key?("ARVO_SEED_PASSWORD")
    sensitive_env_key?("API_TOKEN")
    sensitive_env_key?("COOKIE_SIGNING_SALT")
    sensitive_env_key?("AUTH_PRIVATE_KEY")
    sensitive_env_key?("DATABASE_URL")
    not sensitive_env_key?("ARVO_ALLOWLIST")
    not sensitive_env_key?("PORT")
  end

  u = key.trim.ascii_uppercase
  u.contains?("SECRET") or
    u.contains?("PASSWORD") or
    u.contains?("TOKEN") or
    u.contains?("KEY") or
    u.contains?("COOKIE") or
    u.contains?("DATABASE_URL") or
    u.contains?("PRIVATE")
end

## Redacts sensitive HTTP header values while preserving safe header names and values.
fn redact_headers(headers: List((Text, Text))) : List((Text, Text))
  examples
    redact_headers([("Cookie", "arvo_session=secret"), ("Content-Type", "application/json")]) == [
      ("Cookie", "[REDACTED]"),
      ("Content-Type", "application/json")
    ]
  end

  promise "sensitive header keys always receive [REDACTED]"
    result.all?(fn(pair) not sensitive_header?(pair.0) or pair.1 == "[REDACTED]" end)
  end

  headers.map(fn(pair)
    if sensitive_header?(pair.0)
      (pair.0, "[REDACTED]")
    else
      pair
    end
  end)
end

## Redacts secret values from an environment map before bundle serialization.
fn redact_env(raw_env: Map(Text, Text)) : Map(Text, Text)
  examples
    redact_env({"ARVO_SECRET_KEY": "deadbeef", "PORT": "8080"}) == {
      "ARVO_SECRET_KEY": "[REDACTED]",
      "PORT": "8080"
    }
  end

  promise "no sensitive env key retains its raw value after redaction"
    result.entries.all?(fn(pair) not sensitive_env_key?(pair.0) or pair.1 == "[REDACTED]" end)
  end

  var clean = {}
  for (k, v) in raw_env
    if sensitive_env_key?(k)
      clean = clean.set(k, "[REDACTED]")
    else
      clean = clean.set(k, v)
    end
  end
  clean
end

fn sanitize_json_field(k: Text, v: Json) : Json
  lk = k.trim.ascii_lowercase
  if lk == "password" or lk == "secret" or lk == "token" or lk == "csrf_token"
    Json.String("[REDACTED]")
  else
    case v
      Json.Object(m):
        var out = {}
        for (ck, cv) in m
          out = out.set(ck, sanitize_json_field(ck, cv))
        end
        Json.Object(out)
      Json.Array(items): Json.Array(items.map(fn(it) sanitize_json_field("", it) end))
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_): v
    end
  end
end

## Redacts credentials, cookies, and password fields from an `Api.Request`.
fn redact_request(req: Api.Request) : RedactedRequest
  q_str = if req.query.empty?
    ""
  else
    "?#{req.query.map(fn(p) "#{p.0}=#{p.1}" end).join("&")}"
  end
  raw_body = req.body.decode_utf8 or ""
  clean_body = if raw_body.trim.empty?
    ""
  else
    case Json.parse(raw_body)
      Ok(j): sanitize_json_field("", j).to_text
      Error(_): "[NON_JSON_BODY #{raw_body.byte_count} bytes]"
    end
  end
  RedactedRequest(
    method: req.method.ascii_uppercase,
    path: "#{req.path}#{q_str}",
    headers: redact_headers(req.headers),
    body_text: clean_body
  )
end

## Constructs a sanitized `FailureBundle` ready to write as JSON and turn into a regression test.
fn capture_bundle(
  id: Text,
  captured_at: Text,
  app_commit: Text,
  kind: Text,
  request: Option(Api.Request),
  job_record: Option(Jobs.JobRecord),
  recent_events: List(Audit.AuditEntry),
  raw_env: Map(Text, Text),
  sqlite_snapshot_path: Option(Text),
  error_message: Text
) : FailureBundle
  FailureBundle(
    id: id,
    captured_at: captured_at,
    app_commit: app_commit,
    kind: kind,
    request: request.map(redact_request),
    job_record: job_record,
    recent_events: recent_events,
    env_sanitized: redact_env(raw_env),
    sqlite_snapshot_path: sqlite_snapshot_path,
    error_message: error_message
  )
end

## Encodes a `FailureBundle` as pretty-printed JSON.
fn encode_bundle(bundle: FailureBundle) : Text
  bundle.to_json.pretty
end

## Decodes and re-enforces secret redaction on a serialized `FailureBundle` JSON document.
fn decode_bundle(raw: Text) : Result(FailureBundle, Text)
  b = try Json.decode_strict[FailureBundle](raw).map_error(fn(e) e.to_text end)
  req_clean = b.request.map(fn(r)
    RedactedRequest(
      method: r.method,
      path: r.path,
      headers: redact_headers(r.headers),
      body_text: r.body_text
    )
  end)
  Ok(
    FailureBundle(
      id: b.id,
      captured_at: b.captured_at,
      app_commit: b.app_commit,
      kind: b.kind,
      request: req_clean,
      job_record: b.job_record,
      recent_events: b.recent_events,
      env_sanitized: redact_env(b.env_sanitized),
      sqlite_snapshot_path: b.sqlite_snapshot_path,
      error_message: b.error_message
    )
  )
end

fn escape_mo_str(raw: Text) : Text
  raw.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r")
end

## Generates a standalone, compilable Mo `test "..."` regression snippet pinned to `bundle`.
fn generate_regression_test(bundle: FailureBundle) : Text
  safe_id = escape_mo_str(bundle.id)
  safe_kind = escape_mo_str(bundle.kind)
  safe_err = escape_mo_str(bundle.error_message)
  safe_sha = escape_mo_str(bundle.app_commit)
  var lines = [
    "## Auto-generated deterministic regression test for FailureBundle #{safe_id} (#{safe_kind} at #{safe_sha})",
    "module ReplayRegression",
    "use Api",
    "",
    "test \"replay #{safe_id}: #{safe_kind}\"",
    "  expected_error = \"#{safe_err}\""
  ]

  case bundle.request
    Some(r):
      safe_m = escape_mo_str(r.method)
      safe_p = escape_mo_str(r.path)
      safe_b = escape_mo_str(r.body_text)
      lines = lines.append("  var req = Api.request(\"#{safe_m}\", \"#{safe_p}\")")
      for (hk, hv) in r.headers
        lines = lines.append("  req = req.with_header(\"#{escape_mo_str(hk)}\", \"#{escape_mo_str(hv)}\")")
      end
      if not r.body_text.empty?
        lines = lines.append("  req = req.with_bytes(\"#{safe_b}\".bytes, \"application/json\")")
      end
      lines = lines.append("  assert req.method == \"#{safe_m}\"")
    None: Unit
  end

  if bundle.job_record is Some(j)
    lines = lines.append("  job_name = \"#{escape_mo_str(j.job_name)}\"")
    lines = lines.append("  assert not job_name.empty? and #{j.attempts} <= #{j.max_attempts}")
  end

  lines = lines.append("  assert not expected_error.empty?").append("end")
  "#{lines.join("\n")}\n"
end

test "Arvo.Replay redacts secrets across headers, JSON bodies, env maps, and emits valid regression tests"
  raw_req = Api.post("/bills/1/pay?src=ui").with_header("Cookie", "arvo_session=secret_cookie")
    .with_header("X-XSRF-TOKEN", "secret_xsrf").with_header("Authorization", "Bearer s3cr3t")
    .with_header("Accept", "application/json").with_bytes(
      "{\"expected_version\":1,\"password\":\"hunter2\",\"secret\":\"sec_val_1\",\"csrf_token\":\"cs_tok_1\",\"nested\":{\"token\":\"tok123\",\"keep\":\"yes\"}}"
        .bytes,
      "application/json"
    )
  t0 = Time.parse("2026-11-25T23:00:00Z") or stop "t0"
  aud = Audit.AuditEntry(
    id: "01ARVO",
    actor_name: "ada@household.local",
    action: "bill.mark_in_flight",
    entity_table: "bills",
    entity_id: "1",
    before_json: None,
    after_json: None,
    reason: Some("repro"),
    undo_json: None,
    created_at: t0
  )
  job = Jobs.JobRecord(
    id: "job_1",
    queue: "default",
    job_name: "send_digest",
    payload_json: "{\"id\":1}",
    state: "failed",
    attempts: 2,
    max_attempts: 5,
    run_at: t0.to_text,
    locked_at: None,
    last_error: Some("502 upstream"),
    created_at: t0.to_text,
    updated_at: t0.to_text
  )

  bundle = capture_bundle(
    "fail-001",
    t0.to_text,
    "abc1234",
    "http_500",
    Some(raw_req),
    Some(job),
    [aud],
    {"ARVO_SECRET_KEY": "001122", "ARVO_ALLOWLIST": "ada@household.local"},
    None,
    "unhandled error"
  )
  encoded = encode_bundle(bundle)
  assert not encoded.contains?("secret_cookie")
  assert not encoded.contains?("secret_xsrf")
  assert not encoded.contains?("s3cr3t")
  assert not encoded.contains?("hunter2")
  assert not encoded.contains?("sec_val_1")
  assert not encoded.contains?("cs_tok_1")
  assert not encoded.contains?("tok123")
  assert encoded.contains?("\"expected_version\\\":1")
  assert encoded.contains?("\"keep\\\":\\\"yes\\\"")
  assert not encoded.contains?("001122")
  assert encoded.contains?("\"[REDACTED]\"")
  assert encoded.contains?("ada@household.local")
  assert decode_bundle(encoded) == Ok(bundle)
  assert decode_bundle("not-json") is Error(_)

  # Non-JSON request bodies are replaced with byte length metadata
  form_req = Api.post("/login").with_bytes("password=secret".bytes, "application/x-www-form-urlencoded")
  r_form = redact_request(form_req)
  assert r_form.body_text == "[NON_JSON_BODY 15 bytes]" and not r_form.body_text.contains?("secret")

  # Empty request body and job-less bundle paths
  empty_req = Api.get("/health")
  assert redact_request(empty_req).body_text == ""
  empty_req_bundle = capture_bundle("empty-req", t0.to_text, "sha", "http_500", Some(empty_req), None, [], {}, None, "err")
  assert not generate_regression_test(empty_req_bundle).contains?("with_bytes")
  min_bundle = capture_bundle("min-1", t0.to_text, "sha", "invariant_breach", None, None, [], {}, None, "broke")
  min_code = generate_regression_test(min_bundle)
  assert min_code.contains?("test \"replay min-1: invariant_breach\"")
  assert not min_code.contains?("Api.request")

  code = generate_regression_test(bundle)
  assert code.contains?("module ReplayRegression")
  assert code.contains?("Api.request(\"POST\", \"/bills/1/pay?src=ui\")")
  assert code.contains?("req = req.with_header(\"Cookie\", \"[REDACTED]\")")
  assert code.contains?("job_name = \"send_digest\"")
  assert not code.contains?("hunter2")
end
