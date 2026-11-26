## Offline sanitized failure capture and standalone regression test generator (Spec Part 2.9).
## Strips Cookie, Set-Cookie, Authorization, CSRF tokens, and secret environment variables at capture time.
module Arvo.Testing.Replay
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
use Arvo.Sqlite.Audit
use Arvo.Sqlite.Jobs
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

fn sensitive_name?(name: Text) : Bool
  lower = name.trim.ascii_lowercase
  [
    "pass",
    "secret",
    "token",
    "csrf",
    "xsrf",
    "auth",
    "key",
    "session",
    "cookie",
    "dsn",
    "private",
    "credential",
    "database_url",
    "signature"
  ].any?(fn(tok) lower.contains?(tok) end)
end

## Returns `true` when HTTP header `name` carries credentials, cookies, or CSRF tokens.
fn sensitive_header?(name: Text) : Bool
  examples
    sensitive_header?("Cookie")
    sensitive_header?("authorization")
    sensitive_header?("X-XSRF-TOKEN")
    sensitive_header?("X-CSRF-TOKEN")
    sensitive_header?("X-Auth-Token")
    sensitive_header?("Set-Cookie")
    sensitive_header?("X-API-Key")
    not sensitive_header?("Content-Type")
    not sensitive_header?("Accept")
  end

  sensitive_name?(name)
end

## Returns `true` when environment variable `key` should be redacted.
fn sensitive_env_key?(key: Text) : Bool
  examples
    sensitive_env_key?("ARVO_SECRET_KEY")
    sensitive_env_key?("ARVO_SEED_PASSWORD")
    sensitive_env_key?("API_TOKEN")
    sensitive_env_key?("SMTP_PASS")
    sensitive_env_key?("SENTRY_DSN")
    sensitive_env_key?("COOKIE_SIGNING_SALT")
    sensitive_env_key?("AUTH_PRIVATE_KEY")
    sensitive_env_key?("DATABASE_URL")
    not sensitive_env_key?("ARVO_ALLOWLIST")
    not sensitive_env_key?("PORT")
  end

  sensitive_name?(key)
end

fn kv_delim?(ch: Char) : Bool
  ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '&' or ch == ';' or ch == ','
end

fn kv_quote?(ch: Char) : Bool
  ch == '"' or ch == '\'' or ch == '(' or ch == ')' or ch == '{' or ch == '}' or ch == '[' or ch == ']'
end

fn redact_text(raw: Text) : Text
  var key = ""
  var cur = []
  for ch in raw.chars
    if ch == '=' or ch == ':'
      token = if cur.empty?: key else: Text.from_chars(cur)
      return "[REDACTED]" if sensitive_name?(token)
      key = ""
      cur = []
    else if kv_delim?(ch) or kv_quote?(ch)
      if not cur.empty?
        key = Text.from_chars(cur)
        scheme = key.ascii_lowercase
        return "[REDACTED]" if scheme == "bearer" or scheme == "basic"
        cur = []
      end
    else
      cur = cur.append(ch)
    end
  end
  raw
end

fn encode_query_part(part: Text) : Text
  var encoded = []
  bytes = part.bytes
  var i = 0
  while i < bytes.size
    byte = bytes.get(i) or 0
    b = byte.to_int
    ch = b.to_char or ' '
    if ch.ascii_letter? or ch.ascii_digit? or ch == '-' or ch == '.' or ch == '_' or ch == '~'
      encoded = encoded.append(ch.to_text)
    else
      encoded = encoded.append("%#{hex_lower_digit(b.floor_div(16))}#{hex_lower_digit(b.floor_mod(16))}")
    end
    i += 1
  end
  encoded.join("")
end

fn redact_query(path: Text, query: List((Text, Text))) : Text
  return path if query.empty?
  pairs = query.map(fn(p)
    value = if sensitive_name?(p.0): "[REDACTED]" else: redact_text(p.1)
    "#{encode_query_part(p.0)}=#{encode_query_part(value)}"
  end)
  "#{path}?#{pairs.join("&")}"
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
      (pair.0, redact_text(pair.1))
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
      clean = clean.set(k, redact_text(v))
    end
  end
  clean
end

fn sanitize_json_field(k: Text, v: Json) : Json
  if not k.trim.empty? and sensitive_name?(k)
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
      Json.String(s): Json.String(redact_text(s))
      Json.Null | Json.Boolean(_) | Json.Number(_): v
    end
  end
end

fn redact_json_text(raw: Text) : Text
  return "" if raw.trim.empty?
  case Json.parse(raw)
    Ok(j): sanitize_json_field("", j).to_text
    Error(_): redact_text(raw)
  end
end

fn redact_job_record(j: Jobs.JobRecord) : Jobs.JobRecord
  Jobs.JobRecord(
    id: j.id,
    queue: j.queue,
    job_name: j.job_name,
    payload_json: redact_json_text(j.payload_json),
    state: j.state,
    attempts: j.attempts,
    max_attempts: j.max_attempts,
    run_at: j.run_at,
    locked_at: j.locked_at,
    last_error: j.last_error.map(redact_text),
    created_at: j.created_at,
    updated_at: j.updated_at
  )
end

fn redact_audit_entry(ev: Audit.AuditEntry) : Audit.AuditEntry
  Audit.AuditEntry(
    id: ev.id,
    actor_name: ev.actor_name,
    action: ev.action,
    entity_table: ev.entity_table,
    entity_id: ev.entity_id,
    before_json: ev.before_json.map(fn(j) sanitize_json_field("", j) end),
    after_json: ev.after_json.map(fn(j) sanitize_json_field("", j) end),
    reason: ev.reason.map(redact_text),
    undo_json: ev.undo_json.map(fn(j) sanitize_json_field("", j) end),
    created_at: ev.created_at
  )
end

## Redacts credentials, cookies, query tokens, and password fields from an `Api.Request`.
fn redact_request(req: Api.Request) : RedactedRequest
  clean_body = case req.body.decode_utf8
    None: "[NON_JSON_BODY #{req.body.size} bytes]"
    Some(raw_body): sanitize_body(raw_body)
  end
  RedactedRequest(
    method: req.method.ascii_uppercase,
    path: redact_query(req.path, req.query),
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
    job_record: job_record.map(redact_job_record),
    recent_events: recent_events.map(redact_audit_entry),
    env_sanitized: redact_env(raw_env),
    sqlite_snapshot_path: sqlite_snapshot_path,
    error_message: redact_text(error_message)
  )
end

## Encodes a `FailureBundle` as pretty-printed JSON.
fn encode_bundle(bundle: FailureBundle) : Text
  bundle.to_json.pretty
end

fn sanitize_body(raw_body: Text) : Text
  return "" if raw_body.trim.empty?
  case Json.parse(raw_body)
    Ok(j): sanitize_json_field("", j).to_text
    Error(_): "[NON_JSON_BODY #{raw_body.byte_count} bytes]"
  end
end

fn sanitize_redacted_body(raw_body: Text) : Text
  if raw_body.starts_with?("[NON_JSON_BODY ") and raw_body.ends_with?(" bytes]")
    count = (raw_body.split(" ").get(1) or "").to_int
    if count is Some(n)
      return raw_body if n >= 0 and raw_body == "[NON_JSON_BODY #{n} bytes]"
    end
  end
  sanitize_body(raw_body)
end

## Decodes and re-enforces secret redaction on a serialized `FailureBundle` JSON document.
fn decode_bundle(raw: Text) : Result(FailureBundle, Text)
  b = try Json.decode_strict[FailureBundle](raw).map_error(fn(e) e.to_text end)
  req_clean = b.request.map(fn(r)
    req = Api.request(r.method, r.path)
    RedactedRequest(
      method: req.method,
      path: redact_query(req.path, req.query),
      headers: redact_headers(r.headers),
      body_text: sanitize_redacted_body(r.body_text)
    )
  end)
  Ok(
    FailureBundle(
      id: b.id,
      captured_at: b.captured_at,
      app_commit: b.app_commit,
      kind: b.kind,
      request: req_clean,
      job_record: b.job_record.map(redact_job_record),
      recent_events: b.recent_events.map(redact_audit_entry),
      env_sanitized: redact_env(b.env_sanitized),
      sqlite_snapshot_path: b.sqlite_snapshot_path,
      error_message: redact_text(b.error_message)
    )
  )
end

fn hex_lower_digit(n: Int) : Text
  if n == 0
    "0"
  else if n == 1
    "1"
  else if n == 2
    "2"
  else if n == 3
    "3"
  else if n == 4
    "4"
  else if n == 5
    "5"
  else if n == 6
    "6"
  else if n == 7
    "7"
  else if n == 8
    "8"
  else if n == 9
    "9"
  else if n == 10
    "a"
  else if n == 11
    "b"
  else if n == 12
    "c"
  else if n == 13
    "d"
  else if n == 14
    "e"
  else
    "f"
  end
end

fn escape_mo_str(raw: Text) : Text
  var parts = []
  for ch in raw.chars
    s = ch.to_text
    bs = s.bytes
    if bs.size == 1
      b = (bs.get(0) or 0).to_int
      if b == 92
        parts = parts.append("\\\\")
      else if b == 34
        parts = parts.append("\\\"")
      else if b == 35
        parts = parts.append("\\#")
      else if b == 10
        parts = parts.append("\\n")
      else if b == 13
        parts = parts.append("\\r")
      else if b == 9
        parts = parts.append("\\t")
      else if b < 32 or b == 127
        hi = hex_lower_digit(b.floor_div(16))
        lo = hex_lower_digit(b.floor_mod(16))
        parts = parts.append("\\u{00#{hi}#{lo}}")
      else
        parts = parts.append(s)
      end
    else
      parts = parts.append(s)
    end
  end
  parts.join("")
end

## Generates a standalone, compilable Mo `test "..."` regression snippet pinned to `bundle`.
fn generate_regression_test(bundle: FailureBundle) : Text
  safe_id = escape_mo_str(bundle.id)
  safe_kind = escape_mo_str(bundle.kind)
  safe_err = escape_mo_str(bundle.error_message)
  safe_sha = escape_mo_str(bundle.app_commit)
  case bundle.request
    Some(r):
      safe_m = escape_mo_str(r.method)
      safe_p = escape_mo_str(r.path)
      base_p = r.path.split("?").first or r.path
      safe_base_p = escape_mo_str(base_p)
      safe_b = escape_mo_str(r.body_text)
      var lines = [
        "## Auto-generated deterministic regression test for FailureBundle #{safe_id} (#{safe_kind} at #{safe_sha})",
        "module ReplayRegression",
        "expose replay_request, replay_against",
        "use Api",
        "",
        "fn replay_request() : Api.Request",
        "  var req = Api.request(\"#{safe_m}\", \"#{safe_p}\")"
      ]
      for (hk, hv) in r.headers
        lines = lines.append(
          "  req = req.with_header(\"#{escape_mo_str(hk)}\", \"#{escape_mo_str(hv)}\")"
        )
      end
      if not r.body_text.empty?
        lines = lines.append("  req = req.with_bytes(\"#{safe_b}\".bytes, \"application/json\")")
      end
      lines = lines.append("  req").append("end").append("")
      lines = lines.append(
        "## Replays the captured request against `app` via `ApiTest.App.send` and fails on HTTP 5xx."
      )
      lines = lines.append("fn replay_against(app: ApiTest.App) : Result(Api.Response, Text)")
      lines = lines.append("  res = app.send(replay_request())")
      lines = lines.append("  if res.status >= 500")
      lines = lines.append(
        "    Error(\"unexpected 5xx status \#{res.status} (expected error: #{safe_err})\")"
      )
      lines = lines.append("  else")
      lines = lines.append("    Ok(res)")
      lines = lines.append("  end")
      lines = lines.append("end").append("")
      lines = lines.append("test \"replay #{safe_id}: #{safe_kind}\"")
      lines = lines.append("  req = replay_request()")
      lines = lines.append("  assert req.method == \"#{safe_m}\"")
      lines = lines.append("  assert req.path == \"#{safe_base_p}\"")
      for (hk, hv) in r.headers
        if hv == "[REDACTED]"
          lines = lines.append("  assert req.header(\"#{escape_mo_str(hk)}\") == Some(\"[REDACTED]\")")
        end
      end
      if bundle.job_record is Some(j)
        lines = lines.append("  job_name = \"#{escape_mo_str(j.job_name)}\"")
        lines = lines.append(
          "  assert job_name == \"#{escape_mo_str(j.job_name)}\" and #{j.attempts} <= #{j.max_attempts}"
        )
      end
      lines = lines.append("end")
      "#{lines.join("\n")}\n"
    None:
      safe_bundle_json = escape_mo_str(encode_bundle(bundle))
      var lines = [
        "## Auto-generated deterministic regression test for FailureBundle #{safe_id} (#{safe_kind} at #{safe_sha})",
        "module ReplayRegression",
        "expose captured_bundle_json",
        "use Json",
        "",
        "fn captured_bundle_json() : Text",
        "  \"#{safe_bundle_json}\"",
        "end",
        "",
        "test \"replay #{safe_id}: #{safe_kind}\"",
        "  assert Json.parse(captured_bundle_json()) is Ok(decoded)",
        "  assert decoded.text_at(\"id\") == Some(\"#{safe_id}\")",
        "  assert decoded.text_at(\"kind\") == Some(\"#{safe_kind}\")",
        "  assert decoded.get(\"request\") == Some(Json.Null)"
      ]
      if bundle.job_record is Some(j)
        lines = lines.append("  case decoded.get(\"job_record\")")
        lines = lines.append("    Some(job_rec): assert job_rec.text_at(\"job_name\") == Some(\"#{escape_mo_str(j.job_name)}\")")
        lines = lines.append("    None: assert false")
        lines = lines.append("  end")
      end
      lines = lines.append("end")
      "#{lines.join("\n")}\n"
  end
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

  # S2 extended redaction: query tokens, X-Auth-Token, access_token/new_password/_csrf, SMTP_PASS, SENTRY_DSN,
  # payload_json, last_error, before/after_json, inline error_message, AND decode_bundle re-redaction
  leaky_req = Api.post("/reset?token=q_sec&_csrf=c_sec&keep=ok")
    .with_header("X-Auth-Token", "hdr_auth_tok")
    .with_bytes(
      "{\"access_token\":\"acc_1\",\"new_password\":\"pw_2\",\"_csrf\":\"cs_3\",\"note\":\"ok\"}".bytes,
      "application/json"
    )
  leaky_aud = Audit.AuditEntry(
    id: "01LEAKY",
    actor_name: "ada@household.local",
    action: "auth.reset",
    entity_table: "members",
    entity_id: "1",
    before_json: Some(Json.Object({"password_hash": Json.String("hash_sec"), "email": Json.String("a@b")})),
    after_json: Some(Json.Object({"api_key": Json.String("k_sec")})),
    reason: Some("token=rsn_sec"),
    undo_json: Some(Json.Object({"session_id": Json.String("s_sec")})),
    created_at: t0
  )
  leaky_job = Jobs.JobRecord(
    id: "j_leak",
    queue: "default",
    job_name: "mailer",
    payload_json: "{\"smtp_password\":\"mail_sec\",\"to\":\"ada@household.local\"}",
    state: "failed",
    attempts: 1,
    max_attempts: 3,
    run_at: t0.to_text,
    locked_at: None,
    last_error: Some("failed auth Bearer mail_bearer_tok key=inline_k"),
    created_at: t0.to_text,
    updated_at: t0.to_text
  )
  leaky_bundle = capture_bundle(
    "leak-1",
    t0.to_text,
    "sha1",
    "http_500",
    Some(leaky_req),
    Some(leaky_job),
    [leaky_aud],
    {"SMTP_PASS": "smtp_sec", "SENTRY_DSN": "https://sec@sentry.invalid/1", "PORT": "8080"},
    None,
    "crash with Bearer err_bearer_tok and password=err_pw"
  )
  leaky_json = encode_bundle(leaky_bundle)
  for secret_s in [
    "q_sec",
    "c_sec",
    "hdr_auth_tok",
    "acc_1",
    "pw_2",
    "cs_3",
    "hash_sec",
    "k_sec",
    "rsn_sec",
    "s_sec",
    "mail_sec",
    "mail_bearer_tok",
    "inline_k",
    "smtp_sec",
    "sentry.invalid",
    "err_bearer_tok",
    "err_pw"
  ]
    assert not leaky_json.contains?(secret_s)
  end
  assert leaky_json.contains?("keep=ok")
  assert leaky_json.contains?("ada@household.local")
  assert redact_text("password: \"fake multiword value\"") == "[REDACTED]"
  assert redact_text("Bearer\tfake_value") == "[REDACTED]"
  assert redact_text("request failed at https://example.invalid") == "request failed at https://example.invalid"
  query_req = Api.get("/cb?name=Fran%C3%A7ois%26Co%2B&%74oken=fake_value")
  cleaned_query = redact_request(query_req).path
  assert Api.get(cleaned_query).query == [("name", "François&Co+"), ("token", "[REDACTED]")]
  assert not cleaned_query.contains?("fake_value")

  # Tampered JSON bundle passed to decode_bundle must also have path/body/job/audit/error stripped
  raw_unredacted = """
    {
      "id": "tamper-1",
      "captured_at": "2026-11-25T23:00:00Z",
      "app_commit": "abc",
      "kind": "http_500",
      "request": {
        "method": "GET",
        "path": "/cb?token=tamper_q&page=2",
        "headers": [["X-Auth-Token", "tamper_hdr"]],
        "body_text": "{\\"access_token\\":\\"tamper_body\\"}"
      },
      "job_record": null,
      "recent_events": [],
      "env_sanitized": {"SMTP_PASS": "tamper_env"},
      "sqlite_snapshot_path": null,
      "error_message": "failed Bearer tamper_err"
    }
    """
  assert decode_bundle(raw_unredacted) is Ok(recleaned)
  recleaned_txt = encode_bundle(recleaned)
  for tsec in ["tamper_q", "tamper_hdr", "tamper_body", "tamper_env", "tamper_err"]
    assert not recleaned_txt.contains?(tsec)
  end
  assert decode_bundle(raw_unredacted.replace("token=tamper_q", "%74oken=tamper_q")) == Ok(recleaned)
  assert sanitize_redacted_body("[NON_JSON_BODY fake_value bytes]") == "[NON_JSON_BODY 32 bytes]"

  # S1 injection hardening: `#{}`, `\t`, and ASCII control chars escaped safely
  esc_inj = escape_mo_str("boom \#{40 + 2}\t\u{0007}line")
  assert esc_inj.contains?("\\#")
  assert esc_inj.contains?("\\t")
  assert esc_inj.contains?("\\u{0007}")
  inj_bundle = capture_bundle(
    "inj-1",
    t0.to_text,
    "sha1",
    "http_500",
    Some(Api.get("/p")),
    Some(job),
    [],
    {},
    None,
    "boom \#{40 + 2}\t\u{0007}line"
  )
  inj_code = generate_regression_test(inj_bundle)
  assert inj_code.contains?("\\\#{")
  assert inj_code.contains?("\\t")
  assert inj_code.contains?("\\u{0007}")

  # Non-JSON request bodies are replaced with byte length metadata
  form_req = Api.post("/login").with_bytes("password=secret".bytes, "application/x-www-form-urlencoded")
  r_form = redact_request(form_req)
  assert r_form.body_text == "[NON_JSON_BODY 15 bytes]" and not r_form.body_text.contains?("secret")

  # F1: Empty request body, request-less bundles avoid unused `use Api`, and request bundles expose replay_against
  empty_req = Api.get("/health")
  assert redact_request(empty_req).body_text == ""
  empty_req_bundle = capture_bundle("empty-req", t0.to_text, "sha", "http_500", Some(empty_req), None, [], {}, None, "err")
  assert not generate_regression_test(empty_req_bundle).contains?("with_bytes")
  min_bundle = capture_bundle("min-1", t0.to_text, "sha", "invariant_breach", None, None, [], {}, None, "broke")
  min_code = generate_regression_test(min_bundle)
  assert min_code.contains?("test \"replay min-1: invariant_breach\"")
  assert min_code.contains?("Json.parse(captured_bundle_json())")
  assert not min_code.contains?("use Api")
  assert not min_code.contains?("use Arvo.Replay")
  assert not min_code.contains?("Api.request")

  code = generate_regression_test(bundle)
  assert code.contains?("module ReplayRegression")
  assert code.contains?("use Api")
  assert not code.contains?("use Arvo.WebTest")
  assert code.contains?("app.send(replay_request())")
  assert code.contains?("replay_against(app: ApiTest.App)")
  assert code.contains?("Api.request(\"POST\", \"/bills/1/pay?src=ui\")")
  assert code.contains?("req = req.with_header(\"Cookie\", \"[REDACTED]\")")
  assert code.contains?("job_name = \"send_digest\"")
  assert not code.contains?("hunter2")
end
