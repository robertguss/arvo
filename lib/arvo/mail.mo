## Storage-agnostic transactional email delivery across Resend, Postmark, AWS SES v2 (SigV4),
## signed webhooks, and an offline `DevMailbox` JSONL sink, plus safe HTML templates and outbox payloads.
module Arvo.Mail
expose MailMessage(..),
MailProvider(..),
MailError(..),
CapturedMail(..),
SendResult(..),
outbox_job_name,
to_text,
validate_message,
render_transactional,
encode_outbox_payload,
decode_outbox_payload,
build_http_request,
deliver_http,
deliver,
list_dev_mailbox,
clear_dev_mailbox,
extract_urls
use Arvo.Inertia
use Arvo.S3
use Crypto
use Http
use Json

outbox_job_name = "arvo.mail.deliver"

## Outbound email payload.
struct MailMessage
  from: Text
  to: List(Text)
  reply_to: Option(Text)
  subject: Text
  text_body: Text
  html_body: Option(Text)
  headers: List((Text, Text))
end

## Supported transactional email delivery backends and local JSONL capture.
enum MailProvider
  Resend(api_key: Text, endpoint: Option(Text))
  Postmark(server_token: Text, endpoint: Option(Text))
  AwsSes(
    region: Text,
    access_key_id: Text,
    secret_access_key: Text,
    session_token: Option(Text),
    endpoint: Option(Text)
  )
  Webhook(url: Text, bearer_token: Option(Text))
  DevMailbox(dir: Text)
end

## Errors raised by message validation, provider configuration, HTTP delivery, or mailbox capture.
enum MailError
  InvalidMessage(reason: Text)
  InvalidProvider(reason: Text)
  TransportFailed(reason: Text)
  ProviderRejected(status: Int, body: Text)
  StorageFailed(reason: Text)
  DecodeFailed(reason: Text)
end

## One locally captured message written by `DevMailbox`.
struct CapturedMail
  id: Text
  sent_at: Time
  message: MailMessage
end

## Provider confirmation metadata returned after successful send or local capture.
struct SendResult
  provider: Text
  message_id: Text
  status: Int
end

## Formats a `MailError` as a readable diagnostic.
fn to_text(err: MailError) : Text
  case err
    InvalidMessage(reason: r): "invalid mail message: #{r}"
    InvalidProvider(reason: r): "invalid mail provider config: #{r}"
    TransportFailed(reason: r): "mail transport failed: #{r}"
    ProviderRejected(status: st, body: b): "mail provider rejected with HTTP #{st}: #{b}"
    StorageFailed(reason: r): "dev mailbox storage error: #{r}"
    DecodeFailed(reason: r): "mail decode failed: #{r}"
  end
end

fn has_ctl?(s: Text) : Bool
  for b in s.bytes.to_list
    n = b.to_int
    return true if n < 32 or n == 127
  end
  false
end

fn has_ascii_ws?(s: Text) : Bool
  for ch in s.chars
    return true if ch.ascii_white_space?
  end
  false
end

## Validates `msg` against header-injection (`\r`, `\n`, `\0`, CTLs) and missing required fields.
fn validate_message(msg: MailMessage) : Result(Unit, MailError)
  if msg.from.trim.empty? or has_ctl?(msg.from)
    return Error(InvalidMessage(reason: "from address must be non-empty without control chars"))
  end
  if msg.to.empty?
    return Error(InvalidMessage(reason: "at least one recipient is required"))
  end
  for recip in msg.to
    if recip.trim.empty? or has_ctl?(recip)
      return Error(InvalidMessage(reason: "recipient must be non-empty without control chars"))
    end
  end
  if msg.reply_to is Some(rt)
    if rt.trim.empty? or has_ctl?(rt)
      return Error(InvalidMessage(reason: "reply_to must be non-empty without control chars"))
    end
  end
  if msg.subject.trim.empty? or has_ctl?(msg.subject)
    return Error(InvalidMessage(reason: "subject must be non-empty without control chars"))
  end
  for (hname, hval) in msg.headers
    clean_name = hname.trim
    if clean_name.empty? or
      has_ctl?(clean_name) or
      has_ascii_ws?(clean_name) or
      clean_name.contains?(":")
      return Error(InvalidMessage(reason: "invalid header name '#{hname}'"))
    end
    if has_ctl?(hval)
      return Error(InvalidMessage(reason: "header '#{clean_name}' contains control characters"))
    end
  end
  Ok(Unit)
end

fn safe_http_cta_url?(raw: Text) : Bool
  u = raw.trim
  (u.starts_with?("https://") or u.starts_with?("http://")) and
    not u.empty? and
    not has_ctl?(u) and
    not has_ascii_ws?(u)
end

## Renders an XSS-safe `(text_body, html_body)` transactional email pair.
## Clickable CTA links are restricted to `http(s)://` URLs; `javascript:` / `data:` URLs are stripped.
fn render_transactional(title: Text, intro: Text, cta_label: Text, cta_url: Text, footer: Text) : (
  Text,
  Text
)
  clean_url = cta_url.trim
  url_ok? = safe_http_cta_url?(clean_url)
  text_cta = if url_ok? and not cta_label.trim.empty?
    "#{cta_label.trim}: #{clean_url}\n\n"
  else
    ""
  end
  text_body = "#{title}\n\n#{intro}\n\n#{text_cta}#{footer}".trim

  esc_title = Inertia.escape_html(title)
  esc_intro = Inertia.escape_html(intro)
  esc_footer = Inertia.escape_html(footer)
  html_cta = if url_ok? and not cta_label.trim.empty?
    esc_url = Inertia.escape_html(clean_url)
    esc_lbl = Inertia.escape_html(cta_label.trim)
    "<p><a href=\"#{esc_url}\" style=\"display:inline-block;padding:10px 16px;background:#111827;color:#ffffff;text-decoration:none;border-radius:6px;\">#{esc_lbl}</a></p>"
  else
    ""
  end
  html_body = "<!doctype html><html><body style=\"font-family:sans-serif;line-height:1.5;color:#111827;\"><h1>#{esc_title}</h1><p>#{esc_intro}</p>#{html_cta}<p style=\"color:#6b7280;font-size:13px;\">#{esc_footer}</p></body></html>"
  (text_body, html_body)
end

## Serializes a `MailMessage` into an outbox job JSON payload for `outbox_job_name`.
fn encode_outbox_payload(msg: MailMessage) : Json
  msg.to_json
end

## Decodes an outbox job JSON payload back into a validated `MailMessage`.
fn decode_outbox_payload(payload: Json) : Result(MailMessage, MailError)
  msg = try Json.decode_strict[MailMessage](payload.to_text.bytes).map_error(
    fn(e) DecodeFailed(reason: e.to_text) end
  )
  _v = try validate_message(msg)
  Ok(msg)
end

fn validate_url(raw: Text, label: Text) : Result(Text, MailError)
  u = raw.trim
  if not (u.starts_with?("https://") or u.starts_with?("http://")) or
    has_ctl?(u) or
    has_ascii_ws?(u)
    return Error(InvalidProvider(reason: "#{label} must be an http(s) URL without whitespace"))
  end
  Ok(u)
end

fn build_resend_request(msg: MailMessage, api_key: Text, ep_opt: Option(Text)) : Result(
  Http.Request,
  MailError
)
  clean_key = api_key.trim
  if clean_key.empty? or has_ctl?(clean_key)
    return Error(InvalidProvider(reason: "Resend api_key cannot be empty or contain CTLs"))
  end
  url = case ep_opt
    Some(ep): try validate_url(ep, "Resend endpoint")
    None: "https://api.resend.com/emails"
  end
  var obj = {
    "from": Json.String(msg.from.trim),
    "to": Json.Array(msg.to.map(fn(r) Json.String(r.trim) end)),
    "subject": Json.String(msg.subject),
    "text": Json.String(msg.text_body)
  }
  if msg.html_body is Some(h)
    obj = obj.set("html", Json.String(h))
  end
  if msg.reply_to is Some(rt)
    obj = obj.set("reply_to", Json.String(rt.trim))
  end
  if not msg.headers.empty?
    var hdr_obj = {}
    for (k, v) in msg.headers
      hdr_obj = hdr_obj.set(k.trim, Json.String(v))
    end
    obj = obj.set("headers", Json.Object(hdr_obj))
  end
  req = Http.post(url).header("Authorization", "Bearer #{clean_key}").header(
    "Content-Type",
    "application/json"
  )
  var out = req
  out.body = Json.Object(obj).to_text.bytes
  Ok(out)
end

fn build_postmark_request(msg: MailMessage, server_token: Text, ep_opt: Option(Text)) : Result(
  Http.Request,
  MailError
)
  clean_tok = server_token.trim
  if clean_tok.empty? or has_ctl?(clean_tok)
    return Error(InvalidProvider(reason: "Postmark server_token cannot be empty or contain CTLs"))
  end
  url = case ep_opt
    Some(ep): try validate_url(ep, "Postmark endpoint")
    None: "https://api.postmarkapp.com/email"
  end
  to_joined = msg.to.map(fn(r) r.trim end).join(", ")
  var obj = {
    "From": Json.String(msg.from.trim),
    "To": Json.String(to_joined),
    "Subject": Json.String(msg.subject),
    "TextBody": Json.String(msg.text_body)
  }
  if msg.html_body is Some(h)
    obj = obj.set("HtmlBody", Json.String(h))
  end
  if msg.reply_to is Some(rt)
    obj = obj.set("ReplyTo", Json.String(rt.trim))
  end
  if not msg.headers.empty?
    pm_hdrs = msg.headers.map(
      fn(h) Json.Object({"Name": Json.String(h.0.trim), "Value": Json.String(h.1)}) end
    )
    obj = obj.set("Headers", Json.Array(pm_hdrs))
  end
  var out = Http.post(url).header("X-Postmark-Server-Token", clean_tok).header(
    "Content-Type",
    "application/json"
  )
  out.body = Json.Object(obj).to_text.bytes
  Ok(out)
end

struct ParsedSesTarget
  host_authority: Text
  canon_uri: Text
  full_url: Text
end

fn parse_ses_target(region: Text, ep_opt: Option(Text)) : Result(ParsedSesTarget, MailError)
  raw_base = case ep_opt
    Some(ep): try validate_url(ep, "AWS SES endpoint")
    None: "https://email.#{region}.amazonaws.com"
  end
  trimmed = raw_base.drop_suffix("/") or raw_base
  (scheme, rest) = case trimmed.drop_prefix("https://")
    Some(r): ("https", r)
    None:
      case trimmed.drop_prefix("http://")
        Some(r2): ("http", r2)
        None: return Error(InvalidProvider(reason: "SES endpoint must be http(s)"))
      end
  end
  parts = rest.split("/")
  host_raw = parts.first or ""
  if host_raw.empty?
    return Error(InvalidProvider(reason: "SES endpoint missing host"))
  end
  norm_host = if scheme == "https" and host_raw.ends_with?(":443")
    host_raw.drop_suffix(":443") or host_raw
  else if scheme == "http" and host_raw.ends_with?(":80")
    host_raw.drop_suffix(":80") or host_raw
  else
    host_raw
  end
  extra_segs = parts.drop(1).filter(fn(s) not s.empty? end)
  canon_uri = if extra_segs.empty?
    "/v2/email/outbound-emails"
  else if rest.ends_with?("/v2/email/outbound-emails")
    "/#{extra_segs.join("/")}"
  else
    "/#{extra_segs.join("/")}/v2/email/outbound-emails"
  end
  Ok(
    ParsedSesTarget(
      host_authority: norm_host,
      canon_uri: canon_uri,
      full_url: "#{scheme}://#{host_raw}#{canon_uri}"
    )
  )
end

fn build_ses_request(
  msg: MailMessage,
  region: Text,
  access_key_id: Text,
  secret_access_key: Text,
  session_token: Option(Text),
  ep_opt: Option(Text),
  now: Time
) : Result(Http.Request, MailError)
  clean_region = region.trim
  clean_ak = access_key_id.trim
  clean_sk = secret_access_key
  if clean_region.empty? or has_ctl?(clean_region) or has_ascii_ws?(clean_region)
    return Error(InvalidProvider(reason: "AWS SES region cannot be empty or contain whitespace"))
  end
  if clean_ak.empty? or has_ctl?(clean_ak)
    return Error(InvalidProvider(reason: "AWS SES access_key_id cannot be empty"))
  end
  if clean_sk.empty? or has_ctl?(clean_sk)
    return Error(InvalidProvider(reason: "AWS SES secret_access_key cannot be empty"))
  end
  if session_token is Some(st)
    if st.empty? or has_ctl?(st)
      return Error(InvalidProvider(reason: "AWS SES session_token cannot be empty or contain CTLs"))
    end
  end

  target = try parse_ses_target(clean_region, ep_opt)
  var body_map = {
    "Text": Json.Object({"Data": Json.String(msg.text_body), "Charset": Json.String("UTF-8")})
  }
  if msg.html_body is Some(h)
    body_map = body_map.set(
      "Html",
      Json.Object({"Data": Json.String(h), "Charset": Json.String("UTF-8")})
    )
  end
  simple_obj = Json.Object({
    "Subject": Json.Object({"Data": Json.String(msg.subject), "Charset": Json.String("UTF-8")}),
    "Body": Json.Object(body_map)
  })
  var root_obj = {
    "FromEmailAddress": Json.String(msg.from.trim),
    "Destination": Json.Object({
      "ToAddresses": Json.Array(msg.to.map(fn(t) Json.String(t.trim) end))
    }),
    "Content": Json.Object({"Simple": simple_obj})
  }
  if msg.reply_to is Some(rt)
    root_obj = root_obj.set("ReplyToAddresses", Json.Array([Json.String(rt.trim)]))
  end
  payload_bytes = Json.Object(root_obj).to_text.bytes
  payload_hash = Crypto.sha256(payload_bytes).to_hex
  (amz_date, date_stamp) = S3.format_amz_timestamps(now)

  var sign_pairs = [
    ("content-type", "application/json"),
    ("host", target.host_authority),
    ("x-amz-content-sha256", payload_hash),
    ("x-amz-date", amz_date)
  ]
  if session_token is Some(tok)
    sign_pairs = sign_pairs.append(("x-amz-security-token", tok))
  end
  sorted_pairs = sign_pairs.sort_by(fn(p) p.0 end)
  canon_headers = sorted_pairs.map(fn(p) "#{p.0}:#{p.1}\n" end).join("")
  signed_headers = sorted_pairs.map(fn(p) p.0 end).join(";")

  canon_req = "POST\n#{target.canon_uri}\n\n#{canon_headers}\n#{signed_headers}\n#{payload_hash}"
  canon_hash = Crypto.sha256(canon_req.bytes).to_hex
  scope = "#{date_stamp}/#{clean_region}/ses/aws4_request"
  string_to_sign = "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n#{canon_hash}"
  k_sign = S3.signing_key(clean_sk, date_stamp, clean_region, "ses")
  sig = Crypto.hmac_sha256(k_sign, string_to_sign.bytes).to_hex
  auth_val = "AWS4-HMAC-SHA256 Credential=#{clean_ak}/#{scope},SignedHeaders=#{signed_headers},Signature=#{sig}"

  var out = Http.post(target.full_url).header("Content-Type", "application/json").header(
    "x-amz-content-sha256",
    payload_hash
  ).header("x-amz-date", amz_date)
  if session_token is Some(tok)
    out = out.header("x-amz-security-token", tok)
  end
  out = out.header("Authorization", auth_val)
  out.body = payload_bytes
  Ok(out)
end

fn build_webhook_request(msg: MailMessage, raw_url: Text, bearer_opt: Option(Text)) : Result(
  Http.Request,
  MailError
)
  url = try validate_url(raw_url, "Webhook URL")
  var out = Http.post(url).header("Content-Type", "application/json")
  if bearer_opt is Some(tok)
    if tok.trim.empty? or has_ctl?(tok)
      return Error(InvalidProvider(reason: "Webhook bearer_token cannot be empty or contain CTLs"))
    end
    out = out.header("Authorization", "Bearer #{tok.trim}")
  end
  out.body = Json.encode(msg).bytes
  Ok(out)
end

## Builds the signed HTTP `Http.Request` for `Resend`, `Postmark`, `AwsSes` (SigV4), or `Webhook`.
fn build_http_request(provider: MailProvider, msg: MailMessage, now: Time) : Result(
  Http.Request,
  MailError
)
  _v = try validate_message(msg)
  case provider
    Resend(api_key: k, endpoint: ep): build_resend_request(msg, k, ep)
    Postmark(server_token: tok, endpoint: ep): build_postmark_request(msg, tok, ep)
    AwsSes(region: r, access_key_id: ak, secret_access_key: sk, session_token: st, endpoint: ep): build_ses_request(
      msg,
      r,
      ak,
      sk,
      st,
      ep,
      now
    )
    Webhook(url: u, bearer_token: bt): build_webhook_request(msg, u, bt)
    DevMailbox(dir: _): Error(InvalidProvider(reason: "DevMailbox writes locally without HTTP"))
  end
end

fn provider_label(provider: MailProvider) : Text
  case provider
    Resend(api_key: _, endpoint: _): "resend"
    Postmark(server_token: _, endpoint: _): "postmark"
    AwsSes(region: _, access_key_id: _, secret_access_key: _, session_token: _, endpoint: _): "aws_ses"
    Webhook(url: _, bearer_token: _): "webhook"
    DevMailbox(dir: _): "dev_mailbox"
  end
end

fn extract_message_id(body_text: Text) : Text
  case Json.parse(body_text)
    Ok(doc): doc.text_at("id") or (doc.text_at("MessageID") or (doc.text_at("MessageId") or "ok"))
    Error(_): "ok"
  end
end

## Sends `msg` over `net` using `Resend`, `Postmark`, `AwsSes`, or `Webhook` (`clock` only sets SigV4 timestamp).
fn deliver_http(provider: MailProvider, msg: MailMessage, net: Network, clock: Clock) : Result(
  SendResult,
  MailError
)
  req = try build_http_request(provider, msg, clock.now)
  res = try req.send(net).map_error(fn(e) TransportFailed(reason: "#{e}") end)
  body_text = res.body.decode_utf8 or ""
  if res.status >= 200 and res.status < 300
    Ok(
      SendResult(
        provider: provider_label(provider),
        message_id: extract_message_id(body_text),
        status: res.status
      )
    )
  else
    Error(ProviderRejected(status: res.status, body: body_text))
  end
end

fn mailbox_file_path(dir: Text) : Result(Text, MailError)
  clean = dir.trim.drop_suffix("/") or dir.trim
  if clean.empty? or has_ctl?(clean) or clean.contains?("..")
    return Error(InvalidProvider(reason: "invalid DevMailbox dir '#{dir}'"))
  end
  Ok("#{clean}/messages.jsonl")
end

## Sends `msg` via the configured HTTP provider or writes a `CapturedMail` line into `DevMailbox`.
fn deliver(
  provider: MailProvider,
  msg: MailMessage,
  net: Network,
  files: Files,
  rng: SecureRandom,
  clock: Clock
) : Result(SendResult, MailError)
  case provider
    DevMailbox(dir: d):
      _v = try validate_message(msg)
      clean_dir = d.trim.drop_suffix("/") or d.trim
      mbox = try mailbox_file_path(clean_dir)
      if not files.exists?(clean_dir)
        _mk = try files.make_folder(clean_dir).map_error(fn(e) StorageFailed(reason: "#{e}") end)
      end
      msg_id = "mail_#{rng.bytes(12).to_hex}"
      captured = CapturedMail(id: msg_id, sent_at: clock.now, message: msg)
      line = "#{Json.encode(captured)}\n"
      _wr = if files.exists?(mbox)
        try files.append_text(mbox, line).map_error(fn(e) StorageFailed(reason: "#{e}") end)
      else
        try files.write_text(mbox, line).map_error(fn(e) StorageFailed(reason: "#{e}") end)
      end
      Ok(SendResult(provider: "dev_mailbox", message_id: msg_id, status: 202))
    Resend(api_key: _, endpoint: _) | Postmark(server_token: _, endpoint: _) | AwsSes(
      region: _,
      access_key_id: _,
      secret_access_key: _,
      session_token: _,
      endpoint: _
    ) | Webhook(url: _, bearer_token: _): deliver_http(provider, msg, net, clock)
  end
end

## Reads all captured `CapturedMail` entries from a `DevMailbox` using `ReadFiles`.
fn list_dev_mailbox(rf: ReadFiles, dir: Text) : Result(List(CapturedMail), MailError)
  mbox = try mailbox_file_path(dir)
  return Ok([]) if not rf.exists?(mbox)
  raw = try rf.read_text(mbox).map_error(fn(e) StorageFailed(reason: "#{e}") end)
  var out = []
  for line in raw.lines
    trimmed = line.trim
    continue if trimmed.empty?
    item = try Json.decode_strict[CapturedMail](trimmed.bytes).map_error(
      fn(e) DecodeFailed(reason: e.to_text) end
    )
    out = out.append(item)
  end
  Ok(out)
end

## Deletes the captured mailbox JSONL log in `dir` if present.
fn clear_dev_mailbox(files: Files, dir: Text) : Result(Unit, MailError)
  mbox = try mailbox_file_path(dir)
  if files.exists?(mbox)
    try files.remove(mbox).map_error(fn(e) StorageFailed(reason: "#{e}") end)
  end
  Ok(Unit)
end

fn strip_url_trailing_punct(raw: Text) : Text
  var s = raw
  while s.ends_with?(".") or
    s.ends_with?(",") or
    s.ends_with?(";") or
    s.ends_with?(")") or
    s.ends_with?("\"") or
    s.ends_with?("'") or
    s.ends_with?(">")
    s = s.drop_suffix(".") or (
      s.drop_suffix(",") or (
        s.drop_suffix(";") or (
          s.drop_suffix(")") or (
            s.drop_suffix("\"") or (s.drop_suffix("'") or (s.drop_suffix(">") or s))
          )
        )
      )
    )
  end
  s
end

## Extracts `http(s)://` URLs from a message body (helpful for extracting magic links in tests).
fn extract_urls(text: Text) : List(Text)
  var out = []
  for w in text.words
    cand = strip_url_trailing_punct(w.trim)
    if cand.starts_with?("https://") or cand.starts_with?("http://")
      out = out.append(cand)
    end
  end
  out
end

fn request_header(req: Http.Request, name: Text) : Option(Text)
  target = name.ascii_lowercase
  for (k, v) in req.headers
    return Some(v) if k.ascii_lowercase == target
  end
  None
end

test "Mail validates header injection, sanitizes templates, signs HTTP/SES requests, and records DevMailbox"
  t0 = Time.parse("2026-11-27T10:00:00Z") or stop "t0"
  clk = Clock.fixed(t0)
  rng = SecureRandom.seeded(33)

  # Transactional template XSS & javascript: URL protection
  (txt_safe, html_safe) = render_transactional(
    "Sign in <Arvo>",
    "Click the button for Ada & Co:",
    "Continue",
    "https://app.example.test/magic?t=abc",
    "Ignore if unexpected."
  )
  assert html_safe.contains?("Sign in &lt;Arvo&gt;")
  assert html_safe.contains?("Ada &amp; Co:")
  assert html_safe.contains?("href=\"https://app.example.test/magic?t=abc\"")
  assert extract_urls(txt_safe) == ["https://app.example.test/magic?t=abc"]

  (txt_js, html_js) = render_transactional(
    "Alert",
    "Body",
    "Click",
    "javascript:alert(1)",
    "Footer"
  )
  assert not html_js.contains?("javascript:")
  assert not html_js.contains?("<a href=")
  assert extract_urls(txt_js).empty?

  # Header injection / empty field rejection
  bad_subj = MailMessage(
    from: "no-reply@example.test",
    to: ["ada@example.test"],
    reply_to: None,
    subject: "Hi\r\nBcc: evil@example.test",
    text_body: "hi",
    html_body: None,
    headers: []
  )
  assert validate_message(bad_subj) is Error(InvalidMessage(reason: _))

  bad_hdr = MailMessage(
    from: "no-reply@example.test",
    to: ["ada@example.test"],
    reply_to: None,
    subject: "Ok",
    text_body: "hi",
    html_body: None,
    headers: [("X-Custom", "ok\nX-Inject: 1")]
  )
  assert validate_message(bad_hdr) is Error(InvalidMessage(reason: _))

  msg = MailMessage(
    from: "no-reply@example.test",
    to: ["ada@example.test"],
    reply_to: Some("support@example.test"),
    subject: "Your magic link",
    text_body: txt_safe,
    html_body: Some(html_safe),
    headers: [("X-Request-Id", "req_1")]
  )
  assert decode_outbox_payload(encode_outbox_payload(msg)) == Ok(msg)

  # Build and deliver Resend, Postmark, AWS SES v2 (SigV4), and Webhook over Network.fake
  p_resend = Resend(api_key: "re_test_123", endpoint: None)
  p_postmark = Postmark(server_token: "pm_tok_456", endpoint: None)
  p_ses = AwsSes(
    region: "us-east-1",
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    session_token: Some("sts_tok"),
    endpoint: None
  )
  p_hook = Webhook(url: "https://hooks.example.test/mail", bearer_token: Some("wh_tok"))

  req_r = case build_http_request(p_resend, msg, t0)
    Ok(r): r
    Error(_): stop "resend build failed"
  end
  assert req_r.url == "https://api.resend.com/emails"
  assert request_header(req_r, "Authorization") == Some("Bearer re_test_123")

  req_pm = case build_http_request(p_postmark, msg, t0)
    Ok(r): r
    Error(_): stop "postmark build failed"
  end
  assert req_pm.url == "https://api.postmarkapp.com/email"
  assert request_header(req_pm, "X-Postmark-Server-Token") == Some("pm_tok_456")

  req_ses = case build_http_request(p_ses, msg, t0)
    Ok(r): r
    Error(_): stop "ses build failed"
  end
  assert req_ses.url == "https://email.us-east-1.amazonaws.com/v2/email/outbound-emails"
  ses_auth = request_header(req_ses, "Authorization") or ""
  assert ses_auth.contains?("Credential=AKIAIOSFODNN7EXAMPLE/20261127/us-east-1/ses/aws4_request")
  assert ses_auth.contains?(
    "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
  )
  assert request_header(req_ses, "x-amz-security-token") == Some("sts_tok")

  req_hook = case build_http_request(p_hook, msg, t0)
    Ok(r): r
    Error(_): stop "webhook build failed"
  end
  assert request_header(req_hook, "Authorization") == Some("Bearer wh_tok")

  net = Network.fake(
    Http.replies([
      (req_r, Http.reply(200, "{\"id\":\"re_msg_1\"}")),
      (req_pm, Http.reply(200, "{\"MessageID\":\"pm_msg_2\"}")),
      (req_ses, Http.reply(200, "{\"MessageId\":\"ses_msg_3\"}")),
      (req_hook, Http.reply(422, "{\"error\":\"bad\"}"))
    ])
  )
  files = Files.in_memory({})
  assert deliver(p_resend, msg, net, files, rng, clk) ==
    Ok(SendResult(provider: "resend", message_id: "re_msg_1", status: 200))
  assert deliver(p_postmark, msg, net, files, rng, clk) ==
    Ok(SendResult(provider: "postmark", message_id: "pm_msg_2", status: 200))
  assert deliver(p_ses, msg, net, files, rng, clk) ==
    Ok(SendResult(provider: "aws_ses", message_id: "ses_msg_3", status: 200))
  assert deliver(p_hook, msg, net, files, rng, clk) ==
    Error(ProviderRejected(status: 422, body: "{\"error\":\"bad\"}"))

  # DevMailbox captures locally and clear removes log
  mbox = DevMailbox(dir: ".arvo/mailbox")
  assert list_dev_mailbox(files.read_only, ".arvo/mailbox") == Ok([])
  assert deliver(mbox, msg, net, files, rng, clk) is Ok(res_dev1)
  assert res_dev1.provider == "dev_mailbox" and res_dev1.status == 202
  assert deliver(mbox, msg, net, files, rng, clk) is Ok(_)
  assert list_dev_mailbox(files.read_only, ".arvo/mailbox") is Ok(entries)
  assert entries.size == 2
  assert (entries.get(0) or stop "entry 0").message == msg
  assert clear_dev_mailbox(files, ".arvo/mailbox") == Ok(Unit)
  assert list_dev_mailbox(files.read_only, ".arvo/mailbox") == Ok([])
end
