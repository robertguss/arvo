## Liveness (`200`) and readiness (`200`/`503`) HTTP healthcheck responses with `Cache-Control: no-store`.
module Arvo.Health
expose CheckResult(..),
HealthPayload(..),
ok_check,
fail_check,
all_ok?,
liveness_response,
readiness_response
use Api

## Outcome of one dependency readiness probe.
struct CheckResult
  name: Text
  ok?: Bool
  detail: Option(Text)
  duration_ms: Int
end

## JSON healthcheck body emitted by liveness and readiness endpoints.
struct HealthPayload
  status: Text
  checked_at: Time
  checks: List(CheckResult)
end

## Constructs a passing dependency `CheckResult`.
fn ok_check(name: Text, duration_ms: Int, detail: Option(Text)) : CheckResult
  CheckResult(name: name, ok?: true, detail: detail, duration_ms: duration_ms)
end

## Constructs a failing dependency `CheckResult`.
fn fail_check(name: Text, duration_ms: Int, detail: Text) : CheckResult
  CheckResult(name: name, ok?: false, detail: Some(detail), duration_ms: duration_ms)
end

## True when every check in `checks` passed.
fn all_ok?(checks: List(CheckResult)) : Bool
  checks.all?(fn(c) c.ok? end)
end

## Emits `200 OK` JSON liveness payload with `Cache-Control: no-store`.
fn liveness_response(clock: Clock) : Api.Response
  payload = HealthPayload(status: "ok", checked_at: clock.now, checks: [])
  Api.encoded_json_response(200, payload.to_json).with_header("Cache-Control", "no-store")
end

## Emits `200 OK` (or `503 Service Unavailable` if any check failed) with `Cache-Control: no-store`.
fn readiness_response(clock: Clock, checks: List(CheckResult)) : Api.Response
  healthy? = all_ok?(checks)
  status_code = if healthy?: 200 else: 503
  status_text = if healthy?: "ok" else: "degraded"
  payload = HealthPayload(status: status_text, checked_at: clock.now, checks: checks)
  Api.encoded_json_response(status_code, payload.to_json).with_header("Cache-Control", "no-store")
end

test "Health liveness returns 200 and readiness returns 200 or 503 with no-store"
  t0 = Time.parse("2026-11-27T00:00:00Z") or stop "t0"
  clk = Clock.fixed(t0)

  live = liveness_response(clk)
  assert live.status == 200
  assert live.header("Cache-Control") == Some("no-store")
  assert live.json is Ok(ldoc)
  assert ldoc.text_at("status") == Some("ok")
  assert ldoc.text_at("checked_at") == Some("2026-11-27T00:00:00Z")

  ok_checks = [ok_check("store", 2, Some("rw")), ok_check("jobs", 1, None)]
  assert all_ok?(ok_checks)
  ready_ok = readiness_response(clk, ok_checks)
  assert ready_ok.status == 200
  assert ready_ok.header("Cache-Control") == Some("no-store")
  assert ready_ok.json is Ok(r1) and r1.text_at("status") == Some("ok")

  bad_checks = [ok_check("store", 1, None), fail_check("worker", 15, "queue stalled")]
  assert not all_ok?(bad_checks)
  ready_bad = readiness_response(clk, bad_checks)
  assert ready_bad.status == 503
  assert ready_bad.header("Cache-Control") == Some("no-store")
  assert ready_bad.json is Ok(r2) and r2.text_at("status") == Some("degraded")
end
