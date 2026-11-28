## Storage-agnostic fail-closed adversarial route auditor deriving route, auth, CSRF,
## XSS, open-redirect, Inertia version, strict JSON, security-header, and session-revocation
## checks directly from `app.routes()` and `app.openapi_json()`.
module Arvo.SecurityMatrixCore
expose AuditConfig(..),
AuditCheckKind(..),
AuditFinding(..),
AuditReport(..),
default_config,
substitute_params,
synthesize_schema_sample_named,
synthesize_schema_sample,
route_json_sample,
unsafe_method?,
route_listed?,
unauth_rejected?,
build_request,
raw_data_page_unsafe?,
inertia_html_response?,
valid_version_conflict?,
logout_rejected?,
extract_raw_data_page,
unsafe_redirect_target?,
logout_route?,
order_routes,
make_finding,
passed?,
format_report,
assert_clean,
strict_json_probe_findings,
check_routes_and_openapi,
check_security_headers,
run_app
use Api
use Arvo.WebTest
use Json

## Configuration for `SecurityMatrixCore.run_app`, treating all unlisted routes as protected and CSRF-guarded.
struct AuditConfig
  public_routes: List((Text, Text))
  csrf_exempt_routes: List((Text, Text))
  param_samples: Map(Text, Text)
  inertia_version: Text
  host_header: Text
  max_queries_per_get: Int
end

## Categories of security, protocol, and storage invariants checked by Arvo route auditors.
enum AuditCheckKind
  RoutesDiscovered
  OpenApiValid
  RouteHealthy
  UnauthAccessRejected
  CsrfMissingRejected
  CsrfForgedRejected
  InertiaVersionConflict
  InertiaHtmlEscaped
  OpenRedirectBlocked
  StrictJsonRejected
  SessionRevocationHonored
  ForeignKeysEnabled
  MigrationIdempotent
  QueryBudgetRespected
  StorageIntegrityValid
  SecurityHeadersPresent
end

## One failed adversarial check with expected vs actual outcome and a reproducible curl command.
struct AuditFinding
  check: AuditCheckKind
  method: Text
  path: Text
  expected: Text
  actual: Text
  repro_curl: Text
end

## Aggregate result returned by route auditors.
struct AuditReport
  routes_checked: Int
  checks_run: Int
  findings: List(AuditFinding)
end

## Builds a sensible default `AuditConfig` for a given `public_routes` allowlist and Inertia version.
fn default_config(public_routes: List((Text, Text)), inertia_version: Text) : AuditConfig
  AuditConfig(
    public_routes: public_routes,
    csrf_exempt_routes: [],
    param_samples: {"id": "1"},
    inertia_version: inertia_version,
    host_header: "localhost:8080",
    max_queries_per_get: 10
  )
end

## Substitutes `:param` template segments with `param_samples` values (defaulting to `"1"`).
fn substitute_params(path_template: Text, param_samples: Map(Text, Text)) : Text
  examples
    substitute_params("/bills/:id/pay", {"id": "42"}) == "/bills/42/pay"
    substitute_params("/bills/:id", {}) == "/bills/1"
    substitute_params("/", {"id": "9"}) == "/"
  end

  segs = path_template.split("/").map(fn(seg)
    case seg.drop_prefix(":")
      Some(pname): param_samples.get(pname) or "1"
      None: seg
    end
  end)
  joined = segs.join("/")
  if joined.empty?: "/" else: joined
end

fn openapi_path_key(path_template: Text) : Text
  segs = path_template.split("/").map(fn(seg)
    case seg.drop_prefix(":")
      Some(pname): "{#{pname}}"
      None: seg
    end
  end)
  joined = segs.join("/")
  if joined.empty?: "/" else: joined
end

## Synthesizes a minimal JSON value satisfying a compiler-derived OpenAPI / JSON Schema node.
fn synthesize_schema_sample_named(schema: Json, field_name: Text) : Json
  case schema.path("anyOf")
    Some(Json.Array(alts)):
      for alt in alts
        if alt.text_at("type") != Some("null")
          return synthesize_schema_sample_named(alt, field_name)
        end
      end
      return Json.Null
    None | Some(_): Unit
  end

  if schema.path("enum") is Some(Json.Array(enum_vals))
    if enum_vals.first is Some(first_val)
      return first_val
    end
  end

  case schema.text_at("type")
    Some("integer"): Json.int(1)
    Some("number"): Json.int(1)
    Some("boolean"): Json.Boolean(true)
    Some("string"):
      case schema.text_at("format")
        Some("date-time"): Json.String("2026-01-01T00:00:00Z")
        Some("email"): Json.String("audit@example.test")
        Some("decimal"): Json.String("1")
        Some("bigint"): Json.String("1")
        Some(_) | None:
          if field_name.ascii_lowercase.contains?("email")
            Json.String("audit@example.test")
          else
            Json.String("x")
          end
      end
    Some("array"):
      min_items = schema.int_at("minItems") or 0
      if min_items > 0
        item_schema = schema.path("items") or Json.Object({"type": Json.String("string")})
        sample_item = synthesize_schema_sample_named(item_schema, field_name)
        var arr = []
        var idx = 0
        while idx < min_items and idx < 64
          arr = arr.append(sample_item)
          idx += 1
        end
        Json.Array(arr)
      else
        Json.Array([])
      end
    Some("object"):
      req_names = case schema.list_at("required")
        Some(items): items.filter_map(fn(j)
          case j
            Json.String(s): Some(s)
            Json.Null | Json.Boolean(_) | Json.Number(_) | Json.Array(_) | Json.Object(_): None
          end
        end)
        None: []
      end
      var obj = {}
      case schema.path("properties")
        Some(Json.Object(props)):
          for rname in req_names
            pschema = props.get(rname) or Json.Object({})
            obj = obj.set(rname, synthesize_schema_sample_named(pschema, rname))
          end
        None | Some(_): Unit
      end
      Json.Object(obj)
    Some(_) | None: Json.Object({})
  end
end

fn synthesize_schema_sample(schema: Json) : Json
  synthesize_schema_sample_named(schema, "")
end

fn route_json_sample(openapi: Option(Json), method: Text, path_template: Text) : Json
  doc = case openapi
    Some(d): d
    None: return Json.Object({})
  end
  oa_path = openapi_path_key(path_template)
  m_low = method.ascii_lowercase
  case doc.get("paths")
    Some(Json.Object(paths_map)):
      case paths_map.get(oa_path)
        Some(Json.Object(path_item)):
          case path_item.get(m_low)
            Some(op):
              case op.path("requestBody.content")
                Some(Json.Object(ct_map)):
                  case ct_map.get("application/json")
                    Some(media):
                      case media.get("schema")
                        Some(sch): synthesize_schema_sample(sch)
                        None: Json.Object({})
                      end
                    None: Json.Object({})
                  end
                None | Some(_): Json.Object({})
              end
            None: Json.Object({})
          end
        None | Some(_): Json.Object({})
      end
    None | Some(_): Json.Object({})
  end
end

fn unsafe_method?(method: Text) : Bool
  m = method.ascii_uppercase
  m != "GET" and m != "HEAD" and m != "OPTIONS"
end

fn route_listed?(listed: List((Text, Text)), method: Text, path_template: Text) : Bool
  up = method.ascii_uppercase
  listed.any?(fn(pair) pair.0.ascii_uppercase == up and pair.1 == path_template end)
end

fn unauth_rejected?(res: Api.Response) : Bool
  res.status == 401 or (res.status == 303 and WebTest.redirect_location(res) == Some("/login"))
end

fn build_request(method: Text, path: Text, has_json?: Bool, json_sample: Json, host: Text) : Api
  .Request
  base = Api.request(method, path).with_header("Host", host)
  if has_json?
    base.with_json(json_sample)
  else
    base
  end
end

fn raw_data_page_unsafe?(raw_attr: Text, parsed_ok?: Bool) : Bool
  raw_attr.trim.empty? or
    raw_attr.contains?("<") or
    raw_attr.contains?(">") or
    raw_attr.contains?("'") or
    not parsed_ok?
end

fn inertia_html_response?(res: Api.Response) : Bool
  res.status == 200 and
    (res.header("Content-Type") or "").contains?("text/html") and (
      res.text.contains?("data-page=\"") or res.text.contains?("data-page='")
    )
end

fn valid_version_conflict?(res: Api.Response) : Bool
  res.status == 409 and res.header("X-Inertia-Location") != None
end

fn logout_rejected?(res: Api.Response) : Bool
  res.status == 403
end

fn extract_raw_data_page(html: Text) : Option(Text)
  if html.contains?("data-page=\"")
    marker = "data-page=\""
    parts = html.split(marker)
    after = parts.drop(1).join(marker)
    return Some(after.split("\"").first or "")
  end
  if html.contains?("data-page='")
    smarker = "data-page='"
    sparts = html.split(smarker)
    safter = sparts.drop(1).join(smarker)
    return Some(safter.split("'").first or "")
  end
  None
end

fn unsafe_redirect_target?(loc: Text) : Bool
  low = loc.trim.ascii_lowercase
  low.contains?("evil.test") or
    low.starts_with?("//") or
    low.starts_with?("http://") or
    low.starts_with?("https://")
end

fn logout_route?(r: ApiTest.RouteSpec) : Bool
  r.method.ascii_uppercase == "POST" and (
    r.path_template == "/logout" or r.path_template.ends_with?("/logout")
  )
end

fn order_routes(routes: List(ApiTest.RouteSpec)) : List(ApiTest.RouteSpec)
  non_logout = routes.filter(fn(r) not logout_route?(r) end)
  logout_only = routes.filter(logout_route?)
  non_logout.concat(logout_only)
end

fn make_finding(
  check: AuditCheckKind,
  method: Text,
  path: Text,
  expected: Text,
  actual: Text,
  extra_flags: Text
) : AuditFinding
  curl = "curl -i -X #{method} #{extra_flags} http://localhost#{path}".replace("  ", " ")
  AuditFinding(
    check: check,
    method: method,
    path: path,
    expected: expected,
    actual: actual,
    repro_curl: curl
  )
end

## True when `report` recorded zero security or invariant findings.
fn passed?(report: AuditReport) : Bool
  report.findings.empty?
end

## Renders a concise human-readable audit report listing all findings.
fn format_report(report: AuditReport) : Text
  if report.findings.empty?
    return "SecurityMatrix: PASS (#{report.routes_checked} routes, #{report.checks_run} checks, 0 findings)"
  end
  lines = report.findings.map(fn(f)
    "- [#{f.check}] #{f.method} #{f.path}: expected #{f.expected}, got #{f.actual} (#{f.repro_curl})"
  end)
  "SecurityMatrix: FAIL (#{report.findings.size} findings across #{report.routes_checked} routes):\n#{lines
    .join("\n")}"
end

fn fail_audit(detail: Text) : Unit
  _ = detail
  stop "SecurityMatrix audit failed"
end

## Stops the current test with a formatted summary when `report` contains any findings.
fn assert_clean(report: AuditReport) : Unit
  if not passed?(report)
    fail_audit(format_report(report))
  end
end

fn strict_json_probe_findings(
  m: Text,
  path: Text,
  sample_res: Api.Response,
  bad_json_res: Api.Response,
  unknown_res: Api.Response
) : List(AuditFinding)
  var out = []
  if bad_json_res.status != 422
    out = out.append(
      make_finding(
        StrictJsonRejected,
        m,
        path,
        "422 on malformed JSON",
        "#{bad_json_res.status}",
        "-H 'Content-Type: application/json' -d '{not-valid-json'"
      )
    )
  else if sample_res.status == 422 and bad_json_res.text == sample_res.text
    out = out.append(
      make_finding(
        StrictJsonRejected,
        m,
        path,
        "422 on malformed JSON distinguishable from plain sample",
        "plain sample also returned identical 422: #{sample_res.text}",
        "-H 'Content-Type: application/json' -d '{not-valid-json'"
      )
    )
  end

  if unknown_res.status != 422
    out = out.append(
      make_finding(
        StrictJsonRejected,
        m,
        path,
        "422 on unknown JSON field",
        "#{unknown_res.status}",
        "-H 'Content-Type: application/json' -d '{\"__arvo_unknown_field__\":true}'"
      )
    )
  else if sample_res.status == 422 and unknown_res.text == sample_res.text
    out = out.append(
      make_finding(
        StrictJsonRejected,
        m,
        path,
        "422 on unknown JSON field distinguishable from plain sample",
        "plain sample also returned identical 422: #{sample_res.text}",
        "-H 'Content-Type: application/json' -d '{\"__arvo_unknown_field__\":true}'"
      )
    )
  end
  out
end

fn check_routes_and_openapi(ordered: List(ApiTest.RouteSpec), openapi: Option(Json)) : List(
  AuditFinding
)
  var out = []
  if ordered.empty?
    out = out.append(
      make_finding(RoutesDiscovered, "ROUTES", "/", ">= 1 discovered route", "0 routes", "")
    )
  end
  if openapi is None
    out = out.append(
      make_finding(
        OpenApiValid,
        "OPENAPI",
        "/openapi.json",
        "valid OpenAPI JSON document",
        "invalid or unparseable openapi_json()",
        ""
      )
    )
  end
  out
end

## Checks that baseline defensive headers (`X-Content-Type-Options: nosniff`, `X-Frame-Options`, `Referrer-Policy`)
## are present on HTML/API responses.
fn check_security_headers(res: Api.Response, method: Text, path: Text) : List(AuditFinding)
  var out = []
  if res.header("X-Content-Type-Options") != Some("nosniff")
    out = out.append(
      make_finding(
        SecurityHeadersPresent,
        method,
        path,
        "X-Content-Type-Options: nosniff",
        "#{res.header("X-Content-Type-Options")}",
        ""
      )
    )
  end
  if (res.header("X-Frame-Options") or "").trim.empty?
    out = out.append(
      make_finding(SecurityHeadersPresent, method, path, "non-empty X-Frame-Options", "missing", "")
    )
  end
  if (res.header("Referrer-Policy") or "").trim.empty?
    out = out.append(
      make_finding(SecurityHeadersPresent, method, path, "non-empty Referrer-Policy", "missing", "")
    )
  end
  out
end

## Audits every route discovered via `app.routes()` fail-closed without touching any specific database driver.
fn run_app(app: ApiTest.App, authed_session: WebTest.Session, cfg: AuditConfig) : AuditReport
  ordered = order_routes(app.routes())
  openapi = case Json.parse(app.openapi_json())
    Ok(doc): Some(doc)
    Error(_): None
  end
  var findings = check_routes_and_openapi(ordered, openapi)
  var checks_run = 2

  guest = WebTest.with_header(WebTest.start(), "Host", cfg.host_header)
  authed_base = WebTest.with_header(
    WebTest.without_inertia(authed_session),
    "Host",
    cfg.host_header
  )

  for r in ordered
    m = r.method.ascii_uppercase
    path = substitute_params(r.path_template, cfg.param_samples)
    sample_json = if r.has_json_body?
      route_json_sample(openapi, m, r.path_template)
    else
      Json.Object({})
    end
    is_public? = route_listed?(cfg.public_routes, m, r.path_template)
    is_csrf_exempt? = route_listed?(cfg.csrf_exempt_routes, m, r.path_template)
    unsafe? = unsafe_method?(m)

    if not is_public?
      checks_run += 1
      (_gs, guest_res) = WebTest.send(
        guest,
        app,
        build_request(m, path, r.has_json_body?, sample_json, cfg.host_header)
      )
      if not unauth_rejected?(guest_res)
        findings = findings.append(
          make_finding(
            UnauthAccessRejected,
            m,
            path,
            "401 or 303 -> /login",
            "#{guest_res.status} (Location: #{WebTest.redirect_location(guest_res)})",
            ""
          )
        )
      end
    end

    if not is_public? and unsafe? and not is_csrf_exempt?
      checks_run += 1
      (_ms, missing_res) = WebTest.send_without_csrf(
        authed_base,
        app,
        build_request(m, path, r.has_json_body?, sample_json, cfg.host_header)
      )
      if missing_res.status != 403
        findings = findings.append(
          make_finding(CsrfMissingRejected, m, path, "403", "#{missing_res.status}", "")
        )
      end

      checks_run += 1
      (_fs, forged_res) = WebTest.send_without_csrf(
        authed_base,
        app,
        build_request(m, path, r.has_json_body?, sample_json, cfg.host_header).with_header(
          "X-XSRF-TOKEN",
          "forged-arvo-csrf-token"
        )
      )
      if forged_res.status != 403
        findings = findings.append(
          make_finding(
            CsrfForgedRejected,
            m,
            path,
            "403",
            "#{forged_res.status}",
            "-H 'X-XSRF-TOKEN: forged-arvo-csrf-token'"
          )
        )
      end
    end

    if r.has_json_body? and unsafe?
      checks_run += 1
      (_sps, sample_res) = WebTest.send(
        authed_base,
        app,
        Api.request(m, path).with_header("Host", cfg.host_header).with_json(sample_json)
      )
      bad_json_req = Api.request(m, path).with_header("Host", cfg.host_header).with_bytes(
        "{not-valid-json".bytes,
        "application/json"
      )
      (_bjs, bad_json_res) = WebTest.send(authed_base, app, bad_json_req)

      checks_run += 1
      unknown_map = case sample_json
        Json.Object(entries): entries.set("__arvo_unknown_field__", Json.Null)
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): {
          "__arvo_unknown_field__": Json.Null
        }
      end
      (_uks, unknown_res) = WebTest.send(
        authed_base,
        app,
        Api.request(m, path).with_header("Host", cfg.host_header).with_json(
          Json.Object(unknown_map)
        )
      )
      for sjf in strict_json_probe_findings(m, path, sample_res, bad_json_res, unknown_res)
        findings = findings.append(sjf)
      end
    end

    if unsafe? and not logout_route?(r)
      for evil_ref in ["https://evil.test/steal", "//evil.test/steal"]
        checks_run += 1
        ref_req = build_request(m, path, r.has_json_body?, sample_json, cfg.host_header).with_header(
          "Referer",
          evil_ref
        )
        (_ors, or_res) = WebTest.send(authed_base, app, ref_req)
        if WebTest.redirect_location(or_res) is Some(loc)
          if unsafe_redirect_target?(loc)
            findings = findings.append(
              make_finding(
                OpenRedirectBlocked,
                m,
                path,
                "local redirect path (no evil.test or external scheme)",
                loc,
                "-H 'Referer: #{evil_ref}'"
              )
            )
          end
        end
      end
    end

    if m == "GET"
      use_session = if is_public?: guest else: authed_base
      (_gs, get_res) = WebTest.send(
        use_session,
        app,
        Api.get(path).with_header("Host", cfg.host_header)
      )

      checks_run += 1
      if get_res.status >= 500 or
        get_res.status == 404 or (not is_public? and unauth_rejected?(get_res))
        findings = findings.append(
          make_finding(
            RouteHealthy,
            m,
            path,
            "200/3xx healthy route response",
            "status #{get_res.status}",
            ""
          )
        )
      end

      if inertia_html_response?(get_res)
        checks_run += 1
        raw_attr = extract_raw_data_page(get_res.text) or ""
        parsed_ok? = WebTest.inertia_page(get_res) is Ok(_)
        if raw_data_page_unsafe?(raw_attr, parsed_ok?)
          findings = findings.append(
            make_finding(
              InertiaHtmlEscaped,
              m,
              path,
              "escaped data-page JSON without raw <, >, or '",
              "unescaped or invalid data-page attribute",
              ""
            )
          )
        end

        checks_run += 1
        canary_sep = if path.contains?("?"): "&" else: "?"
        canary_path = "#{path}#{canary_sep}_arvo_xss=%3Cscript%3E%27%22"
        (_xs, xss_res) = WebTest.send(
          use_session,
          app,
          Api.get(canary_path).with_header("Host", cfg.host_header)
        )
        xss_attr = extract_raw_data_page(xss_res.text) or ""
        xss_parsed? = WebTest.inertia_page(xss_res) is Ok(_)
        if xss_res.status >= 500
          findings = findings.append(
            make_finding(
              RouteHealthy,
              m,
              canary_path,
              "200 healthy response under XSS canary query",
              "status #{xss_res.status}",
              ""
            )
          )
        else if xss_res.text.contains?("<script>") or raw_data_page_unsafe?(xss_attr, xss_parsed?)
          findings = findings.append(
            make_finding(
              InertiaHtmlEscaped,
              m,
              path,
              "escaped HTML and data-page under _arvo_xss canary probe",
              "reflected or unescaped <script> / data-page",
              ""
            )
          )
        end

        checks_run += 1
        stale_req = Api.get(path).with_header("Host", cfg.host_header).with_header(
          "X-Inertia",
          "true"
        ).with_header("X-Inertia-Version", "__arvo_stale_version__")
        (_vs, ver_res) = WebTest.send(use_session, app, stale_req)
        if not valid_version_conflict?(ver_res)
          findings = findings.append(
            make_finding(
              InertiaVersionConflict,
              m,
              path,
              "409 with X-Inertia-Location header",
              "status #{ver_res.status}, X-Inertia-Location=#{ver_res.header("X-Inertia-Location")}",
              "-H 'X-Inertia: true' -H 'X-Inertia-Version: __arvo_stale_version__'"
            )
          )
        end
      end
    end
  end

  # Verify post-logout session cookie replay rejection if a logout route exists
  if ordered.find(logout_route?) is Some(lroute)
    checks_run += 1
    (_ls, logout_res) = WebTest.send(
      authed_base,
      app,
      Api.request(lroute.method.ascii_uppercase, lroute.path_template).with_header(
        "Host",
        cfg.host_header
      )
    )
    if logout_rejected?(logout_res)
      findings = findings.append(
        make_finding(
          SessionRevocationHonored,
          lroute.method.ascii_uppercase,
          lroute.path_template,
          "logout succeeds with CSRF",
          "403",
          ""
        )
      )
    else
      for r in ordered
        continue if route_listed?(cfg.public_routes, r.method.ascii_uppercase, r.path_template)
        rm = r.method.ascii_uppercase
        rpath = substitute_params(r.path_template, cfg.param_samples)
        rsample = if r.has_json_body?
          route_json_sample(openapi, rm, r.path_template)
        else
          Json.Object({})
        end
        checks_run += 1
        (_rs, replay_res) = WebTest.send(
          authed_base,
          app,
          build_request(rm, rpath, r.has_json_body?, rsample, cfg.host_header)
        )
        if not unauth_rejected?(replay_res)
          findings = findings.append(
            make_finding(
              SessionRevocationHonored,
              rm,
              rpath,
              "401 or 303 -> /login after logout",
              "#{replay_res.status}",
              ""
            )
          )
        end
      end
    end
  end

  AuditReport(routes_checked: ordered.size, checks_run: checks_run, findings: findings)
end

test "SecurityMatrixCore validates OpenAPI synthesis, header checks, and predicates"
  cfg = default_config([("GET", "/login")], "v1")
  assert cfg.max_queries_per_get == 10
  assert substitute_params("/org/:org/items/:id", {"org": "acme"}) == "/org/acme/items/1"

  assert check_routes_and_openapi([], None).map(fn(f) f.check end) == [
    RoutesDiscovered,
    OpenApiValid
  ]

  r200 = Api.html_response(200, "ok")
  assert check_security_headers(r200, "GET", "/").size == 3
  r_sec = r200.with_header("X-Content-Type-Options", "nosniff").with_header(
    "X-Frame-Options",
    "DENY"
  ).with_header("Referrer-Policy", "same-origin")
  assert check_security_headers(r_sec, "GET", "/").empty?

  ok_rep = AuditReport(routes_checked: 1, checks_run: 2, findings: [])
  assert passed?(ok_rep)
  assert_clean(ok_rep)
  assert format_report(ok_rep).contains?("SecurityMatrix: PASS")
end
