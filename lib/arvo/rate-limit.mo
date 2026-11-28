## Storage-agnostic fixed-window rate-limiting evaluator, SHA-256 bucket keys,
## `promise`-enforced bounds, and RFC-compliant `X-RateLimit-*` / `Retry-After` HTTP helpers.
module Arvo.RateLimit
expose LimitRule(..),
BucketState(..),
LimitOutcome(..),
bucket_key,
retry_after_ceil,
evaluate,
attach_headers,
too_many_requests
use Api
use Crypto
use Json

## Configuration for a fixed-window rate limiter bucket.
struct LimitRule
  namespace: Text
  max_requests: Int
  window_seconds: Int
end

## Persisted state of one rate-limiter bucket for the current fixed window.
struct BucketState
  count: Int
  window_start: Time
  expires_at: Time
end

## Result of evaluating one request against a `LimitRule`.
enum LimitOutcome
  Allowed(remaining: Int, reset_at: Time, limit: Int)
  Limited(retry_after_seconds: Int, reset_at: Time, limit: Int)
end

fn effective_limit(rule: LimitRule) : Int
  if rule.max_requests < 1: 1 else: rule.max_requests
end

fn effective_window(rule: LimitRule) : Int
  if rule.window_seconds < 1
    1
  else if rule.window_seconds > 31536000
    31536000
  else
    rule.window_seconds
  end
end

## Computes a deterministic, collision-resistant SHA-256 storage key for `(namespace, subject)`.
fn bucket_key(namespace: Text, subject: Text) : Text
  examples
    bucket_key("login", "127.0.0.1") == bucket_key("login", "127.0.0.1")
    bucket_key("login", "a:b") != bucket_key("login:a", "b")
  end

  raw = Json.Array([Json.String(namespace), Json.String(subject)]).to_text
  "rl_#{Crypto.sha256(raw.bytes).to_hex}"
end

## Computes ceiling seconds until `reset_at`, always clamped to at least 1 second.
fn retry_after_ceil(reset_at: Time, now: Time) : Int
  examples
    case Time.parse("2026-11-27T12:00:00Z")
      Some(t0): retry_after_ceil(t0 + 500.milliseconds, t0) == 1
      None: false
    end
  end

  promise "Retry-After seconds is always at least 1"
    result >= 1
  end

  diff_ms = (reset_at - now).in_milliseconds
  if diff_ms <= 0
    1
  else
    (diff_ms + 999).floor_div(1000)
  end
end

fn valid_outcome?(o: LimitOutcome) : Bool
  case o
    Allowed(remaining: rem, reset_at: _, limit: lim): lim >= 1 and rem >= 0 and rem < lim
    Limited(retry_after_seconds: retry, reset_at: _, limit: lim): lim >= 1 and retry >= 1
  end
end

## Evaluates a single request against optional existing `BucketState` at `now`.
## Expired or exact-boundary (`expires_at <= now`) buckets start a fresh fixed window.
fn evaluate(existing: Option(BucketState), rule: LimitRule, now: Time) : (BucketState, LimitOutcome)
  examples
    case Time.parse("2026-11-27T12:00:00Z")
      Some(t0): evaluate(
        Some(BucketState(count: 2, window_start: t0, expires_at: t0 + 60.seconds)),
        LimitRule(namespace: "login", max_requests: 2, window_seconds: 60),
        t0 + 60.seconds
      ).0.count ==
        1
      None: false
    end
    case Time.parse("2026-11-27T12:00:00Z")
      Some(t0): evaluate(
        Some(BucketState(count: 2, window_start: t0, expires_at: t0 + 60.seconds)),
        LimitRule(namespace: "login", max_requests: 2, window_seconds: 60),
        t0 + 10.seconds
      ).1 ==
        Limited(retry_after_seconds: 50, reset_at: t0 + 60.seconds, limit: 2)
      None: false
    end
  end

  promise "evaluate preserves non-negative remaining counts and Retry-After >= 1"
    result.0.count >= 1 and valid_outcome?(result.1)
  end

  eff_max = effective_limit(rule)
  eff_win = effective_window(rule)
  case existing
    Some(st) if st.expires_at > now:
      cur_count = if st.count < 0: 0 else: st.count
      if cur_count < eff_max
        new_count = cur_count + 1
        next = BucketState(
          count: new_count,
          window_start: st.window_start,
          expires_at: st.expires_at
        )
        (next, Allowed(remaining: eff_max - new_count, reset_at: st.expires_at, limit: eff_max))
      else
        retry = retry_after_ceil(st.expires_at, now)
        (st, Limited(retry_after_seconds: retry, reset_at: st.expires_at, limit: eff_max))
      end
    Some(_) | None:
      exp = now.checked_add(eff_win.seconds) or now
      next = BucketState(count: 1, window_start: now, expires_at: exp)
      (next, Allowed(remaining: eff_max - 1, reset_at: exp, limit: eff_max))
  end
end

fn unix_seconds(t: Time) : Int
  epoch = Time.parse("1970-01-01T00:00:00Z") or t
  (t - epoch).in_milliseconds.floor_div(1000)
end

## Attaches `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` (and `Retry-After` when limited).
fn attach_headers(res: Api.Response, outcome: LimitOutcome) : Api.Response
  case outcome
    Allowed(remaining: rem, reset_at: rst, limit: lim): res.with_header(
      "X-RateLimit-Limit",
      lim.to_text
    ).with_header("X-RateLimit-Remaining", rem.to_text).with_header(
      "X-RateLimit-Reset",
      unix_seconds(rst).to_text
    )
    Limited(retry_after_seconds: retry, reset_at: rst, limit: lim): res.with_header(
      "X-RateLimit-Limit",
      lim.to_text
    ).with_header("X-RateLimit-Remaining", "0").with_header(
      "X-RateLimit-Reset",
      unix_seconds(rst).to_text
    ).with_header("Retry-After", retry.to_text)
  end
end

## Emits an HTTP `429 Too Many Requests` JSON error response with rate-limit and `Retry-After` headers.
fn too_many_requests(outcome: LimitOutcome, message: Text) : Api.Response
  retry = case outcome
    Limited(retry_after_seconds: r, reset_at: _, limit: _): r
    Allowed(remaining: _, reset_at: _, limit: _): 1
  end
  body = Json.Object({
    "error": Json.String("rate_limited"),
    "message": Json.String(message),
    "retry_after_seconds": Json.int(retry)
  })
  attach_headers(Api.encoded_json_response(429, body), outcome)
end

test "RateLimit evaluates windows, exact expiry boundary, sub-second Retry-After ceiling, and 429 headers"
  t0 = Time.parse("2026-11-27T12:00:00Z") or stop "t0"
  rule = LimitRule(namespace: "login", max_requests: 2, window_seconds: 60)

  # First request
  (s1, o1) = evaluate(None, rule, t0)
  assert s1.count == 1
  assert o1 == Allowed(remaining: 1, reset_at: t0 + 60.seconds, limit: 2)

  # Second request exhausts quota with remaining == 0
  (s2, o2) = evaluate(Some(s1), rule, t0 + 10.seconds)
  assert s2.count == 2
  assert o2 == Allowed(remaining: 0, reset_at: t0 + 60.seconds, limit: 2)

  # Third request is limited with ceiling Retry-After (e.g. 10.1s elapsed -> 50s remaining; 59.9s elapsed -> 1s)
  (s3, o3) = evaluate(Some(s2), rule, t0 + 10100.milliseconds)
  assert s3 == s2
  assert o3 == Limited(retry_after_seconds: 50, reset_at: t0 + 60.seconds, limit: 2)

  (_s_sub, o_sub) = evaluate(Some(s2), rule, t0 + 59900.milliseconds)
  assert o_sub == Limited(retry_after_seconds: 1, reset_at: t0 + 60.seconds, limit: 2)

  # Exact expiry boundary resets window immediately
  (s_exp, o_exp) = evaluate(Some(s2), rule, t0 + 60.seconds)
  assert s_exp.count == 1
  assert o_exp == Allowed(remaining: 1, reset_at: t0 + 120.seconds, limit: 2)

  # Headers and 429 response
  res_ok = attach_headers(Api.no_content(), o1)
  assert res_ok.header("X-RateLimit-Limit") == Some("2")
  assert res_ok.header("X-RateLimit-Remaining") == Some("1")
  assert res_ok.header("Retry-After") == None

  res_429 = too_many_requests(o3, "Slow down")
  assert res_429.status == 429
  assert res_429.header("Retry-After") == Some("50")
  assert res_429.header("X-RateLimit-Remaining") == Some("0")
  assert res_429.json is Ok(doc) and doc.int_at("retry_after_seconds") == Some(50)
end
