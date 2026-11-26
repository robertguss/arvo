## Outbound signed webhook publisher and constant-time HMAC-SHA256 verifier
## with timestamp replay protection, URL hygiene, and deterministic `Network.fake` delivery testing.
module Arvo.Webhooks
expose default_signature_header,
timestamp_header,
delivery_id_header,
event_header,
WebhookError(..),
DeliveryResult(..),
to_text,
unix_seconds,
validate_target_url,
compute_signature,
verify_signature,
build_request,
deliver,
next_retry_delay_seconds
use Crypto
use Http

default_signature_header = "X-Arvo-Signature-256"
timestamp_header = "X-Webhook-Timestamp"
delivery_id_header = "X-Webhook-Delivery"
event_header = "X-Webhook-Event"

## Errors from webhook secret, URL, event name, replay window, or HMAC signature validation.
enum WebhookError
  InvalidSecret
  InvalidUrl(reason: Text)
  InvalidEvent(reason: Text)
  MissingSignature
  InvalidSignature
  TimestampExpired
end

## Classification of an HTTP webhook delivery attempt for durable retry scheduling.
enum DeliveryResult
  Delivered(status: Int)
  RetryableFailure(status: Option(Int), reason: Text)
  PermanentFailure(status: Int, reason: Text)
end

## Formats a `WebhookError` as a readable diagnostic message.
fn to_text(err: WebhookError) : Text
  case err
    InvalidSecret: "webhook signing secret must not be empty"
    InvalidUrl(reason: r): "invalid webhook target URL: #{r}"
    InvalidEvent(reason: r): "invalid webhook event: #{r}"
    MissingSignature: "missing webhook HMAC signature"
    InvalidSignature: "invalid webhook HMAC signature"
    TimestampExpired: "webhook timestamp outside allowed replay window"
  end
end

## Whole seconds elapsed since `1970-01-01T00:00:00Z`.
fn unix_seconds(t: Time) : Int
  epoch = Time.parse("1970-01-01T00:00:00Z") or stop "epoch"
  (t - epoch).in_milliseconds.floor_div(1000)
end

fn unsafe_control_or_ws?(s: Text) : Bool
  s.chars.any?(fn(c) c.code < 33 or c.code == 127 end)
end

## Validates an outbound webhook target (`https://...` or loopback `http://localhost` / `http://127.0.0.1`).
fn validate_target_url(url: Text) : Result(Unit, WebhookError)
  examples
    validate_target_url("https://agent.acme.io/hooks/vellum") == Ok(Unit)
    validate_target_url("http://127.0.0.1:9000/hook") == Ok(Unit)
    validate_target_url("http://evil.example.com/hook") is Error(InvalidUrl(reason: _))
  end

  trimmed = url.trim
  if trimmed.empty? or unsafe_control_or_ws?(trimmed)
    return Error(InvalidUrl(reason: "URL must be non-empty without whitespace or control chars"))
  end
  is_https = trimmed.starts_with?("https://") and trimmed.byte_count > 8
  is_local = trimmed.starts_with?("http://127.0.0.1:") or
    trimmed.starts_with?("http://127.0.0.1/") or
    trimmed.starts_with?("http://localhost:") or
    trimmed.starts_with?("http://localhost/")
  if is_https or is_local
    Ok(Unit)
  else
    Error(InvalidUrl(reason: "only https:// or loopback http:// targets are permitted"))
  end
end

## Computes `sha256=<hex>` over `"<timestamp_secs>.<body>"` using `Crypto.hmac_sha256`.
fn compute_signature(secret: Text, timestamp_secs: Int, body: Bytes) : Result(Text, WebhookError)
  if secret.trim.empty?
    return Error(InvalidSecret)
  end
  signed_payload = Bytes.join(["#{timestamp_secs}.".bytes, body])
  digest_hex = Crypto.hmac_sha256(secret.bytes, signed_payload).to_hex
  Ok("sha256=#{digest_hex}")
end

## Verifies `header_sig` against `secret`, `timestamp_secs`, and `body` in constant time within `max_skew_seconds`.
fn verify_signature(
  secret: Text,
  timestamp_secs: Int,
  header_sig: Text,
  body: Bytes,
  now: Time,
  max_skew_seconds: Int
) : Result(Unit, WebhookError)
  sig = header_sig.trim
  if sig.empty?
    return Error(MissingSignature)
  end
  skew = unix_seconds(now) - timestamp_secs
  if max_skew_seconds >= 0 and (skew > max_skew_seconds or skew < -max_skew_seconds)
    return Error(TimestampExpired)
  end
  expected = try compute_signature(secret, timestamp_secs, body)
  if Crypto.constant_time_eq?(sig.bytes, expected.bytes)
    Ok(Unit)
  else
    Error(InvalidSignature)
  end
end

## Builds a signed outbound `Http.Request` (`POST`) carrying HMAC-SHA256 signature and metadata headers.
fn build_request(
  url: Text,
  secret: Text,
  delivery_id: Text,
  event: Text,
  body: Bytes,
  now: Time,
  sig_header: Text
) : Result(Http.Request, WebhookError)
  _u = try validate_target_url(url)
  clean_event = event.trim
  if clean_event.empty? or unsafe_control_or_ws?(clean_event)
    return Error(InvalidEvent(reason: "event name must be non-empty without spaces"))
  end
  clean_hdr = if sig_header.trim.empty?: default_signature_header else: sig_header.trim
  ts = unix_seconds(now)
  sig = try compute_signature(secret, ts, body)
  var req = Http.post(url.trim)
  req.headers = req.headers.filter(fn(h) h.0.ascii_lowercase != "content-type" end).append((
    "Content-Type",
    "application/json; charset=utf-8"
  )).append((clean_hdr, sig)).append((timestamp_header, ts.to_text)).append((
    delivery_id_header,
    delivery_id.trim
  )).append((event_header, clean_event))
  req.body = body
  Ok(req)
end

## Signs and sends one webhook delivery via `net`, classifying `Delivered` vs `RetryableFailure` vs `PermanentFailure`.
fn deliver(
  url: Text,
  secret: Text,
  delivery_id: Text,
  event: Text,
  body: Bytes,
  now: Time,
  sig_header: Text,
  net: Network
) : Result(DeliveryResult, WebhookError)
  req = try build_request(url, secret, delivery_id, event, body, now, sig_header)
  case Http.send(req, net)
    Error(e): Ok(RetryableFailure(status: None, reason: e.to_text))
    Ok(res):
      if res.status >= 200 and res.status < 300
        Ok(Delivered(status: res.status))
      else if res.status == 408 or res.status == 429 or res.status >= 500
        Ok(RetryableFailure(status: Some(res.status), reason: "HTTP #{res.status}"))
      else
        Ok(PermanentFailure(status: res.status, reason: "HTTP #{res.status}"))
      end
  end
end

## Computes capped exponential backoff in seconds (`5s, 10s, 20s, ..., max 3600s`).
fn next_retry_delay_seconds(attempt: Int) : Int
  promise "retry delay stays bounded in [5, 3600]"
    result >= 5 and result <= 3600
  end

  clamped = if attempt <= 0
    0
  else if attempt > 12
    12
  else
    attempt
  end
  var delay = 5
  var i = 0
  while i < clamped
    delay = delay * 2
    if delay > 3600
      return 3600
    end
    i += 1
  end
  delay
end

test "webhook HMAC-SHA256 signing, constant-time verification, replay window, and Network.fake delivery"
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  ts0 = unix_seconds(t0)
  secret = "whsec_vellum_test_key_123"
  body = "{\"event\":\"page.updated\",\"page_id\":\"pg_1\"}".bytes
  url = "https://agent.acme.io/webhooks/vellum"

  req = case build_request(url, secret, "del_1", "page.updated", body, t0, "X-Vellum-Signature-256")
    Ok(r): r
    Error(_): stop "build_request failed"
  end
  sig = req.headers.find(fn(h) h.0 == "X-Vellum-Signature-256" end).map(fn(h) h.1 end) or stop "sig"
  assert sig.starts_with?("sha256=")
  assert verify_signature(secret, ts0, sig, body, t0 + 10.seconds, 300) == Ok(Unit)
  assert verify_signature(secret, ts0, sig, "{\"tampered\":true}".bytes, t0, 300) ==
    Error(InvalidSignature)
  assert verify_signature("wrong-secret", ts0, sig, body, t0, 300) == Error(InvalidSignature)
  assert verify_signature(secret, ts0, sig, body, t0 + 10.minutes, 300) == Error(TimestampExpired)

  net_ok = Network.fake(Http.replies([(req, Http.reply(202, "{\"ok\":true}"))]))
  assert deliver(url, secret, "del_1", "page.updated", body, t0, "X-Vellum-Signature-256", net_ok) ==
    Ok(Delivered(status: 202))

  net_429 = Network.fake(Http.replies([(req, Http.reply(429, "slow down"))]))
  assert deliver(url, secret, "del_1", "page.updated", body, t0, "X-Vellum-Signature-256", net_429) is
    Ok(RetryableFailure(status: Some(429), reason: _))

  net_400 = Network.fake(Http.replies([(req, Http.reply(400, "bad payload"))]))
  assert deliver(url, secret, "del_1", "page.updated", body, t0, "X-Vellum-Signature-256", net_400) is
    Ok(PermanentFailure(status: 400, reason: _))
end
