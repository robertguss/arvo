## Ergonomic web route plumbing built over `Arvo.Inertia`, `Arvo.Flash`, `Arvo.Security`,
## `Arvo.Csrf`, `Arvo.RateLimit`, and `Arvo.Changeset`: one-call version checks, flash
## carry/clear, CSP nonce injection, OWASP headers, JSON helpers, and mutation guards.
module Arvo.Web
expose WebConfig(..),
GuardResult(..),
default_config,
render_page,
render_page_with_status,
redirect_with_notice,
redirect_with_alert,
redirect_with_errors,
redirect_with_changeset,
json_ok,
json_created,
json_error,
guard_csrf,
guard_rate_limit,
guard_csrf_and_limit
use Api
use Arvo.Changeset
use Arvo.Csrf
use Arvo.Flash
use Arvo.Inertia
use Arvo.Keyring
use Arvo.RateLimit
use Arvo.Security
use Crypto
use Json

## Unified response, CSP, cookie security, and Inertia configuration for route handlers.
struct WebConfig
  inertia: Inertia.InertiaConfig
  headers: Security.SecurityHeadersConfig
  secure_cookies?: Bool
  enable_csp_nonce?: Bool
end

## Outcome of evaluating request pre-flight security guards (`Csrf` / `RateLimit`).
enum GuardResult
  GuardPassed(headers: List((Text, Text)))
  GuardRejected(response: Api.Response)
end

## Constructs a hardened default `WebConfig` from `inertia` and HTTPS deployment flag `https?`.
fn default_config(inertia: Inertia.InertiaConfig, https?: Bool) : WebConfig
  WebConfig(
    inertia: inertia,
    headers: Security.default_headers_config(https?),
    secure_cookies?: https?,
    enable_csp_nonce?: true
  )
end

fn apply_nonce_headers(res: Api.Response, cfg: WebConfig, nonce: Text) : Api.Response
  var hdrs = cfg.headers
  if cfg.enable_csp_nonce? and hdrs.csp is None
    hdrs.csp = Some(Security.strict_csp(nonce, cfg.inertia.vite_dev_url))
  end
  Security.apply_headers(res, hdrs)
end

## Renders an Inertia v2 page with explicit HTTP `status`, performing version-mismatch `409`
## handling, sealed `Flash` cookie take + clear, CSP script nonce generation, and OWASP headers.
fn render_page_with_status(
  req: Api.Request,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  cfg: WebConfig,
  status: Int,
  component: Text,
  props: P,
  build_shared: fn(Flash.FlashData) : S
) : Api.Response
  where P: Json, S: Json
  case Inertia.check_version(req, cfg.inertia)
    Some(r409): return Security.apply_headers(r409, cfg.headers)
    None: Unit
  end
  (flash, had_flash?) = Flash.take_with_keyring(req, keyring)
  shared = build_shared(flash)
  nonce = if cfg.enable_csp_nonce?: Security.csp_nonce(rng) else: ""
  rendered = if cfg.enable_csp_nonce?
    Inertia.render_page_with_status_and_nonce(
      req,
      cfg.inertia,
      status,
      component,
      props,
      shared,
      nonce
    )
  else
    Inertia.render_page_with_status(req, cfg.inertia, status, component, props, shared)
  end
  cleared = Flash.clear_if_present(rendered, had_flash?, cfg.secure_cookies?)
  apply_nonce_headers(cleared, cfg, nonce)
end

## Renders a `200 OK` Inertia v2 page using `render_page_with_status`.
fn render_page(
  req: Api.Request,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  cfg: WebConfig,
  component: Text,
  props: P,
  build_shared: fn(Flash.FlashData) : S
) : Api.Response
  where P: Json, S: Json
  render_page_with_status(req, rng, keyring, cfg, 200, component, props, build_shared)
end

fn redirect_with_flash(
  target: Text,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  cfg: WebConfig,
  data: Flash.FlashData
) : Api.Response
  redir = Inertia.redirect(target)
  flashed = Flash.attach_with_keyring(redir, rng, keyring, data, cfg.secure_cookies?)
  Security.apply_headers(flashed, cfg.headers)
end

## Redirects (`303 See Other`) to `target` carrying a signed `notice` flash message.
fn redirect_with_notice(
  target: Text,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  cfg: WebConfig,
  message: Text
) : Api.Response
  redirect_with_flash(target, rng, keyring, cfg, Flash.with_notice(message))
end

## Redirects (`303 See Other`) to `target` carrying a signed `alert` flash message.
fn redirect_with_alert(
  target: Text,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  cfg: WebConfig,
  message: Text
) : Api.Response
  redirect_with_flash(target, rng, keyring, cfg, Flash.with_alert(message))
end

## Redirects (`303 See Other`) to `target` carrying signed validation `errors`.
fn redirect_with_errors(
  target: Text,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  cfg: WebConfig,
  errors: Map(Text, List(Text))
) : Api.Response
  redirect_with_flash(target, rng, keyring, cfg, Flash.with_errors(errors))
end

## Redirects (`303 See Other`) to `target` carrying signed validation errors from `cs`.
fn redirect_with_changeset(
  target: Text,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  cfg: WebConfig,
  cs: Changeset.Changeset(T)
) : Api.Response
  redirect_with_errors(target, rng, keyring, cfg, cs.errors)
end

fn apply_api_headers(res: Api.Response, cfg: WebConfig) : Api.Response
  Security.apply_headers(res.with_header("Cache-Control", "no-store"), cfg.headers)
end

## Returns a `200 OK` JSON response with `Cache-Control: no-store` and OWASP security headers.
fn json_ok(value: T, cfg: WebConfig) : Api.Response where T: Json
  apply_api_headers(Api.encoded_json_response(200, value.to_json), cfg)
end

## Returns a `201 Created` JSON response with `Cache-Control: no-store` and OWASP security headers.
fn json_created(value: T, cfg: WebConfig) : Api.Response where T: Json
  apply_api_headers(Api.encoded_json_response(201, value.to_json), cfg)
end

## Returns a structured JSON error response with OWASP security headers and `Cache-Control: no-store`.
fn json_error(status: Int, code: Text, message: Text, cfg: WebConfig) : Api.Response
  body = Json.Object({"error": Json.String(code), "message": Json.String(message)})
  apply_api_headers(Api.encoded_json_response(status, body), cfg)
end

## Verifies CSRF protection for unsafe HTTP methods using `X-XSRF-TOKEN` vs `expected_csrf_token`.
fn guard_csrf(req: Api.Request, expected_csrf_token: Text) : GuardResult
  return GuardPassed(headers: []) if Csrf.safe_method?(req)
  if expected_csrf_token.empty?
    return GuardRejected(
      response: Api.encoded_json_response(
        403,
        Json.Object({
          "error": Json.String("csrf_failed"),
          "message": Json.String("Invalid or missing CSRF token")
        })
      )
    )
  end
  raw = case req.header(Csrf.header_name)
    Some(v): v.trim
    None: ""
  end
  decoded = Api.percent_decode(raw, false) or raw
  ok? = (not decoded.empty?) and Crypto.constant_time_eq?(decoded.bytes, expected_csrf_token.bytes)
  if ok?
    GuardPassed(headers: [])
  else
    GuardRejected(
      response: Api.encoded_json_response(
        403,
        Json.Object({
          "error": Json.String("csrf_failed"),
          "message": Json.String("Invalid or missing CSRF token")
        })
      )
    )
  end
end

## Translates a `RateLimit.LimitOutcome` into `GuardPassed` headers or `429 Too Many Requests`.
fn guard_rate_limit(outcome: RateLimit.LimitOutcome) : GuardResult
  case outcome
    RateLimit.Allowed(remaining: _, reset_at: _, limit: _):
      seeded = RateLimit.attach_headers(Api.no_content(), outcome)
      GuardPassed(headers: seeded.headers)
    RateLimit.Limited(retry_after_seconds: _, reset_at: _, limit: _): GuardRejected(
      response: RateLimit.too_many_requests(outcome, "Too many requests")
    )
  end
end

## Enforces rate limiting first (fast `429` fail-closed on floods), then CSRF verification.
fn guard_csrf_and_limit(
  req: Api.Request,
  expected_csrf_token: Text,
  outcome: RateLimit.LimitOutcome
) : GuardResult
  case guard_rate_limit(outcome)
    GuardRejected(response: r): GuardRejected(response: r)
    GuardPassed(headers: rl_hdrs):
      case guard_csrf(req, expected_csrf_token)
        GuardPassed(headers: _): GuardPassed(headers: rl_hdrs)
        GuardRejected(response: r403):
          var out = r403
          for (k, v) in rl_hdrs
            out = out.with_header(k, v)
          end
          GuardRejected(response: out)
      end
  end
end

struct SampleProps
  count: Int
end

struct SampleShared
  notice: Option(Text)
  errors: Json
end

test "Arvo.Web handles version 409, flash round-trip with Keyring, CSP nonces, changesets, and guards"
  rng = SecureRandom.seeded(9101)
  assert Keyring.single("k1", rng.bytes(32)) is Ok(kr)
  icfg = Inertia.InertiaConfig(
    app_title: "ArvoApp",
    version: "v42",
    vite_dev_url: Some("http://localhost:5173"),
    entry_js: "/src/main.tsx",
    entry_css: [],
    head_extra: ""
  )
  cfg = default_config(icfg, false)

  # 1. Stale X-Inertia-Version returns 409 immediately
  stale = Api.get("/").with_header("X-Inertia", "true").with_header("X-Inertia-Version", "old")
  r409 = render_page(
    stale,
    rng,
    kr,
    cfg,
    "Home",
    SampleProps(count: 1),
    fn(f) SampleShared(notice: f.notice, errors: Changeset.inertia_error_map_json(f.errors)) end
  )
  assert r409.status == 409
  assert r409.header("X-Inertia-Location") == Some("/")
  assert r409.header("X-Frame-Options") == Some("DENY")

  # 2. Flash notice round-trips across 303 redirect and clears on render_page with CSP nonce
  redir = redirect_with_notice("/bills", rng, kr, cfg, "Saved bill")
  assert redir.status == 303
  assert redir.header("Location") == Some("/bills")
  raw_cookie = (redir.header("Set-Cookie") or "").split(";").first or ""

  req_html = Api.get("/bills").with_header("Cookie", raw_cookie)
  page_res = render_page(
    req_html,
    rng,
    kr,
    cfg,
    "Bills",
    SampleProps(count: 3),
    fn(f) SampleShared(notice: f.notice, errors: Changeset.inertia_error_map_json(f.errors)) end
  )
  assert page_res.status == 200
  assert page_res.text.contains?("Saved bill")
  assert page_res.text.contains?("<script type=\"module\" nonce=\"")
  csp = page_res.header("Content-Security-Policy") or ""
  assert csp.contains?("'nonce-") and csp.contains?("ws://localhost:5173")
  assert (page_res.header("Set-Cookie") or "").contains?("Max-Age=0")

  # 3. Changeset errors redirect + JSON helpers
  cs = Changeset.require_non_empty(Changeset.new({"name": ""}), "name", "")
  cs_redir = redirect_with_changeset("/bills", rng, kr, cfg, cs)
  cs_cookie = (cs_redir.header("Set-Cookie") or "").split(";").first or ""
  xhr = Api.get("/bills").with_header("X-Inertia", "true").with_header("X-Inertia-Version", "v42")
    .with_header("Cookie", cs_cookie)
  xhr_res = render_page(
    xhr,
    rng,
    kr,
    cfg,
    "Bills",
    SampleProps(count: 3),
    fn(f) SampleShared(notice: f.notice, errors: Changeset.inertia_error_map_json(f.errors)) end
  )
  assert xhr_res.status == 200 and xhr_res.text.contains?("can't be blank")
  assert json_created({"ok": true}, cfg).status == 201
  assert json_error(422, "invalid", "bad input", cfg).status == 422

  # 4. guard_csrf_and_limit checks rate limit before CSRF
  t0 = Time.parse("2026-11-27T12:00:00Z") or stop "t0"
  rule = RateLimit.LimitRule(namespace: "post", max_requests: 1, window_seconds: 60)
  (st1, out1) = RateLimit.evaluate(None, rule, t0)
  (_st2, out2) = RateLimit.evaluate(Some(st1), rule, t0)

  ok_req = Api.post("/bills").with_header("X-XSRF-TOKEN", "tok+1/2")
  bad_req = Api.post("/bills")
  assert guard_csrf_and_limit(ok_req, "tok+1/2", out1) is GuardPassed(headers: hdrs) and
    hdrs.size == 3
  assert guard_csrf_and_limit(bad_req, "tok+1/2", out1) is GuardRejected(response: r403) and
    r403.status == 403
  assert guard_csrf_and_limit(bad_req, "tok+1/2", out2) is GuardRejected(response: r429) and
    r429.status == 429
end
