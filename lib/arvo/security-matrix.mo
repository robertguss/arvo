## Zero-config fail-closed adversarial route auditor deriving route, auth, CSRF,
## XSS, open-redirect, Inertia version, strict JSON, FK, migration, and N+1 checks
## directly from `app.routes()` and `app.openapi_json()`.
module Arvo.SecurityMatrix
expose AuditConfig(..),
AuditCheckKind(..),
AuditFinding(..),
AuditReport(..),
default_config,
substitute_params,
synthesize_schema_sample,
passed?,
format_report,
assert_clean,
run,
run_full
use Api
use Arvo.Fixtures.SecurityApp
use Arvo.Migrations
use Arvo.WebTest
use Json

## Configuration for `SecurityMatrix.run`, treating all unlisted routes as protected and CSRF-guarded.
struct AuditConfig
  public_routes: List((Text, Text))
  csrf_exempt_routes: List((Text, Text))
  param_samples: Map(Text, Text)
  inertia_version: Text
  host_header: Text
  max_queries_per_get: Int
end

## Categories of security, protocol, and database invariants checked by `SecurityMatrix`.
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

## Aggregate result returned by `SecurityMatrix.run` / `run_full`.
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
        while idx < min_items and idx < 4
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
    (res.header("Content-Type") or "").contains?("text/html") and
    (res.text.contains?("data-page=\"") or res.text.contains?("data-page='"))
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

fn check_fk_enabled(db: Sqlite.Database) : Option(AuditFinding)
  case db.query("PRAGMA foreign_keys", [])
    Ok(res):
      if res.rows != [[Sqlite.Integer(1)]]
        Some(make_finding(ForeignKeysEnabled, "PRAGMA", "foreign_keys", "1", "#{res.rows}", ""))
      else
        None
      end
    Error(e): Some(make_finding(ForeignKeysEnabled, "PRAGMA", "foreign_keys", "1", "#{e}", ""))
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

## Audits every route discovered via `app.routes()` fail-closed against `db` and `authed_session`.
fn run(app: ApiTest.App, db: Sqlite.Database, authed_session: WebTest.Session, cfg: AuditConfig) : AuditReport
  ordered = order_routes(app.routes())
  openapi = case Json.parse(app.openapi_json())
    Ok(doc): Some(doc)
    Error(_): None
  end
  var findings = check_routes_and_openapi(ordered, openapi)
  var checks_run = 2

  checks_run += 1
  if check_fk_enabled(db) is Some(fk_finding)
    findings = findings.append(fk_finding)
  end

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
      checks_run += 1
      db.reset_stats()
      (_gs, get_res) = WebTest.send(
        use_session,
        app,
        Api.get(path).with_header("Host", cfg.host_header)
      )
      qstats = db.stats()
      if qstats.query_count > cfg.max_queries_per_get
        findings = findings.append(
          make_finding(
            QueryBudgetRespected,
            m,
            path,
            "<= #{cfg.max_queries_per_get} SQLite queries",
            "#{qstats.query_count} queries",
            ""
          )
        )
      end

      checks_run += 1
      if get_res.status >= 500 or get_res.status == 404 or
        (not is_public? and unauth_rejected?(get_res))
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
        else if xss_res.text.contains?("<script>") or
          raw_data_page_unsafe?(xss_attr, xss_parsed?)
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

## Runs `SecurityMatrix.run` plus `MigrationIdempotent` verification against `migrations`.
fn run_full(
  app: ApiTest.App,
  db: Sqlite.Database,
  clock: Clock,
  authed_session: WebTest.Session,
  cfg: AuditConfig,
  migrations: List(Migrations.Migration)
) : AuditReport
  base = run(app, db, authed_session, cfg)
  var findings = base.findings
  checks = base.checks_run + 1
  case Migrations.run(db, clock, migrations)
    Ok(0): Unit
    Ok(applied): findings = findings.append(
      make_finding(
        MigrationIdempotent,
        "MIGRATE",
        "_arvo_migrations",
        "Ok(0) on re-run",
        "Ok(#{applied})",
        ""
      )
    )
    Error(e): findings = findings.append(
      make_finding(
        MigrationIdempotent,
        "MIGRATE",
        "_arvo_migrations",
        "Ok(0) on re-run",
        "Error(#{e})",
        ""
      )
    )
  end
  AuditReport(routes_checked: base.routes_checked, checks_run: checks, findings: findings)
end

fn login_test_session(app: ApiTest.App) : WebTest.Session
  s0 = WebTest.with_header(WebTest.start(), "Host", "localhost:8080")
  (s1, res) = WebTest.post_form(s0, app, "/login", [])
  _ = WebTest.expect_status(res, 303)
  s1
end

test "SecurityMatrix passes cleanly on hardened routes and catches every injected vulnerability"
  t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"
  cfg = AuditConfig(
    public_routes: [("GET", "/login"), ("POST", "/login")],
    csrf_exempt_routes: [],
    param_samples: {"id": "1"},
    inertia_version: "sec_v1",
    host_header: "localhost:8080",
    max_queries_per_get: 10
  )
  run_with_flags = fn(flags)
    sql = Sqlite.in_memory()
    clk = Clock.fixed(t0)
    rng = SecureRandom.seeded(99)
    env = Env.of(flags)
    app = ApiTest.start(SecurityApp, sql, clk, rng, env)
    db = case sql.open("security.sqlite")
      Ok(d): d
      Error(_): stop "open failed"
    end
    authed = login_test_session(app)
    run_full(app, db, clk, authed, cfg, SecurityApp.app_migrations())
  end

  clean = run_with_flags({})
  assert passed?(clean)
  assert_clean(clean)
  assert format_report(clean).contains?("SecurityMatrix: PASS")
  assert clean.routes_checked == 6
  assert clean.checks_run == 37

  # Check exact base vs full checks_run (+1 for MigrationIdempotent) and boundary max_queries_per_get
  sql_b = Sqlite.in_memory()
  clk_b = Clock.fixed(t0)
  rng_b = SecureRandom.seeded(99)
  app_b = ApiTest.start(SecurityApp, sql_b, clk_b, rng_b, Env.of({}))
  assert sql_b.open("security.sqlite") is Ok(db_b)
  auth_b = login_test_session(app_b)
  cfg_exact = AuditConfig(
    public_routes: [("get", "/login"), ("POST", "/login")],
    csrf_exempt_routes: [],
    param_samples: {"id": "1"},
    inertia_version: "sec_v1",
    host_header: "localhost:8080",
    max_queries_per_get: 4
  )
  rep_base = run(app_b, db_b, auth_b, cfg_exact)
  assert rep_base.checks_run == 36
  assert passed?(rep_base)
  auth_b2 = login_test_session(app_b)
  rep_full = run_full(app_b, db_b, clk_b, auth_b2, cfg_exact, SecurityApp.app_migrations())
  assert rep_full.checks_run == rep_base.checks_run + 1

  # Boundary: max_queries_per_get: 3 triggers QueryBudgetRespected while 4 passes (kills > vs >=)
  cfg_tight = AuditConfig(
    public_routes: [("get", "/login"), ("POST", "/login")],
    csrf_exempt_routes: [],
    param_samples: {"id": "1"},
    inertia_version: "sec_v1",
    host_header: "localhost:8080",
    max_queries_per_get: 3
  )
  auth_b3 = login_test_session(app_b)
  rep_tight = run(app_b, db_b, auth_b3, cfg_tight)
  assert rep_tight.findings.any?(fn(f) f.check == QueryBudgetRespected and f.path == "/" end)

  # Unit checks for SecurityMatrix internal edge predicates
  assert not unauth_rejected?(Api.redirect_see_other("/other"))
  assert not unauth_rejected?(Api.html_response(303, "no loc"))
  assert unauth_rejected?(Api.redirect_see_other("/login"))
  assert unauth_rejected?(Api.html_response(401, "unauth"))

  assert route_listed?([("GET", "/login")], "get", "/login")
  assert not route_listed?([("GET", "/login")], "POST", "/login")
  assert raw_data_page_unsafe?("<", true)
  assert raw_data_page_unsafe?(">", true)
  assert raw_data_page_unsafe?("'", true)
  assert raw_data_page_unsafe?("clean", false)
  assert not raw_data_page_unsafe?("clean", true)
  assert not inertia_html_response?(Api.html_response(200, "<div>no data-page</div>"))
  assert not inertia_html_response?(Api.html_response(404, "<div data-page=\"x\"></div>"))
  assert inertia_html_response?(Api.html_response(200, "<div data-page=\"x\"></div>"))
  assert not valid_version_conflict?(Api.response(409, [], "".bytes))
  assert not valid_version_conflict?(Api.response(200, [("X-Inertia-Location", "/")], "".bytes))
  assert valid_version_conflict?(Api.response(409, [("X-Inertia-Location", "/")], "".bytes))
  assert logout_rejected?(Api.text_response(403, "csrf"))
  assert not logout_rejected?(Api.text_response(404, "missing"))

  assert extract_raw_data_page("<div>none</div>") == None
  assert extract_raw_data_page("<div data-page=\"abc\"></div>") == Some("abc")

  assert unsafe_redirect_target?("https://other.example/x")
  assert unsafe_redirect_target?("http://other.example/x")
  assert unsafe_redirect_target?("//other.example/x")
  assert unsafe_redirect_target?("/local?next=evil.test")
  assert not unsafe_redirect_target?("/bills?page=1")

  assert logout_route?(
    ApiTest.RouteSpec(
      method: "POST",
      path_template: "/auth/logout",
      auth_mode: "required",
      has_json_body?: false,
      job_names: []
    )
  )
  assert logout_route?(
    ApiTest.RouteSpec(
      method: "POST",
      path_template: "/logout",
      auth_mode: "required",
      has_json_body?: false,
      job_names: []
    )
  )
  assert not logout_route?(
    ApiTest.RouteSpec(
      method: "GET",
      path_template: "/logout",
      auth_mode: "none",
      has_json_body?: false,
      job_names: []
    )
  )

  # Prove able to fail: missing auth guard on GET /
  r_no_auth = run_with_flags({"BUG_NO_AUTH": "1"})
  assert not passed?(r_no_auth)
  assert r_no_auth.findings.any?(fn(f) f.check == UnauthAccessRejected and f.path == "/" end)
  assert format_report(r_no_auth).contains?("SecurityMatrix: FAIL")

  # Prove able to fail: missing CSRF check caught for both missing and forged X-XSRF-TOKEN
  r_no_csrf = run_with_flags({"BUG_NO_CSRF": "1"})
  assert r_no_csrf.findings.any?(fn(f) f.check == CsrfMissingRejected and f.path == "/items" end)
  assert r_no_csrf.findings.any?(fn(f) f.check == CsrfForgedRejected and f.path == "/items" end)

  # Prove able to fail: open redirect Referer leak
  r_open_redir = run_with_flags({"BUG_OPEN_REDIRECT": "1"})
  assert r_open_redir.findings.any?(fn(f) f.check == OpenRedirectBlocked and f.path == "/items" end)

  # Prove able to fail: N+1 query budget overrun
  r_n1 = run_with_flags({"BUG_N_PLUS_ONE": "1"})
  assert r_n1.findings.any?(fn(f) f.check == QueryBudgetRespected and f.path == "/" end)

  # Prove able to fail: unescaped <script> inside data-page, plain-seed unescaped data-page, and reflected _arvo_xss canary
  r_xss = run_with_flags({"BUG_XSS": "1"})
  assert r_xss.findings.any?(fn(f) f.check == InertiaHtmlEscaped and f.path == "/" end)
  r_xss_plain = run_with_flags({"BUG_XSS_PLAIN": "1"})
  assert r_xss_plain.findings.any?(fn(f) f.check == InertiaHtmlEscaped and f.path == "/" end)
  r_xss_ref = run_with_flags({"BUG_XSS_REFLECT": "1"})
  assert r_xss_ref.findings.any?(fn(f) f.check == InertiaHtmlEscaped and f.path == "/" end)

  # Prove able to fail: authenticated GET returning 500
  r_500 = run_with_flags({"BUG_HOME_500": "1"})
  assert r_500.findings.any?(fn(f) f.check == RouteHealthy and f.path == "/" end)

  # Prove able to fail: empty route list & broken OpenAPI document (F3)
  assert check_routes_and_openapi([], None).map(fn(f) f.check end) == [
    RoutesDiscovered,
    OpenApiValid
  ]

  # Prove able to fail: indistinguishable plain-sample 422 on strict-JSON probe (F5)
  r422 = Api.text_response(422, "invalid input")
  r200 = Api.text_response(200, "ok")
  assert strict_json_probe_findings("POST", "/items", r422, r422, r422).size == 2
  assert strict_json_probe_findings("POST", "/items", r200, r422, r422).empty?
  assert strict_json_probe_findings("POST", "/items", r200, r422, r200).size == 1

  # Prove able to fail: missing 409 X-Inertia-Version mismatch handling
  r_stale = run_with_flags({"BUG_STALE_VER": "1"})
  assert r_stale.findings.any?(fn(f) f.check == InertiaVersionConflict and f.path == "/" end)

  # Prove able to fail: logout fails to revoke session cookie
  r_no_rev = run_with_flags({"BUG_NO_REVOKE": "1"})
  assert r_no_rev.findings.any?(fn(f) f.check == SessionRevocationHonored end)

  # Prove able to fail: PRAGMA foreign_keys = OFF and non-idempotent / tampered migrations
  sql2 = Sqlite.in_memory()
  clk2 = Clock.fixed(t0)
  rng2 = SecureRandom.seeded(12)
  env2 = Env.of({})
  app2 = ApiTest.start(SecurityApp, sql2, clk2, rng2, env2)
  assert sql2.open("security.sqlite") is Ok(db2)
  authed2 = login_test_session(app2)
  assert db2.run("PRAGMA foreign_keys = OFF", []) == Ok(Unit)
  tampered_migs = [Migrations.Migration(version: 1, name: "init_sec", sql: "SELECT 1;")]
  cfg2 = default_config([("GET", "/login"), ("POST", "/login")], "sec_v1")
  assert cfg2.max_queries_per_get == 10
  bad_db_rep = run_full(app2, db2, clk2, authed2, cfg2, tampered_migs)
  assert bad_db_rep.findings.any?(fn(f) f.check == ForeignKeysEnabled end)
  assert bad_db_rep.findings.any?(fn(f) f.check == MigrationIdempotent end)
end

test "synthesize_schema_sample covers all OpenAPI schema primitives, formats, enums, arrays, and objects"
  assert synthesize_schema_sample(Json.Object({"type": Json.String("integer")})) == Json.int(1)
  assert synthesize_schema_sample(Json.Object({"type": Json.String("number")})) == Json.int(1)
  assert synthesize_schema_sample(Json.Object({"type": Json.String("boolean")})) ==
    Json.Boolean(true)
  assert synthesize_schema_sample(Json.Object({"type": Json.String("array")})) == Json.Array([])
  assert synthesize_schema_sample(
    Json.Object({"type": Json.String("string"), "format": Json.String("date-time")})
  ) ==
    Json.String("2026-01-01T00:00:00Z")
  assert synthesize_schema_sample(
    Json.Object({"type": Json.String("string"), "format": Json.String("decimal")})
  ) ==
    Json.String("1")
  assert synthesize_schema_sample(
    Json.Object({"type": Json.String("string"), "format": Json.String("bigint")})
  ) ==
    Json.String("1")
  assert synthesize_schema_sample(Json.Object({"type": Json.String("string")})) == Json.String("x")
  assert synthesize_schema_sample(
    Json.Object({"type": Json.String("string"), "format": Json.String("email")})
  ) ==
    Json.String("audit@example.test")
  assert synthesize_schema_sample(
    Json.Object({
      "type": Json.String("object"),
      "required": Json.Array([Json.String("email")]),
      "properties": Json.Object({"email": Json.Object({"type": Json.String("string")})})
    })
  ) ==
    Json.Object({"email": Json.String("audit@example.test")})
  assert synthesize_schema_sample(
    Json.Object({
      "type": Json.String("array"),
      "minItems": Json.int(2),
      "items": Json.Object({"type": Json.String("integer")})
    })
  ) ==
    Json.Array([Json.int(1), Json.int(1)])
  assert synthesize_schema_sample(
    Json.Object({"enum": Json.Array([Json.String("pending"), Json.String("paid")])})
  ) ==
    Json.String("pending")
  assert synthesize_schema_sample(
    Json.Object({
      "anyOf": Json.Array([
        Json.Object({"type": Json.String("null")}),
        Json.Object({"type": Json.String("integer")})
      ])
    })
  ) ==
    Json.int(1)
  assert synthesize_schema_sample(
    Json.Object({"anyOf": Json.Array([Json.Object({"type": Json.String("null")})])})
  ) ==
    Json.Null
end
