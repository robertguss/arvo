## Zero-config fail-closed adversarial route auditor deriving route, auth, CSRF,
## XSS, open-redirect, Inertia version, strict JSON, FK, migration, and N+1 checks
## directly from `app.routes()` and `app.openapi_json()`.
module Arvo.Testing.SecurityMatrix
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
use Arvo.SecurityMatrixCore
use Arvo.Sqlite.Migrations
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
  c = SecurityMatrixCore.default_config(public_routes, inertia_version)
  AuditConfig(
    public_routes: c.public_routes,
    csrf_exempt_routes: c.csrf_exempt_routes,
    param_samples: c.param_samples,
    inertia_version: c.inertia_version,
    host_header: c.host_header,
    max_queries_per_get: c.max_queries_per_get
  )
end

## Substitutes `:param` template segments with `param_samples` values (defaulting to `"1"`).
fn substitute_params(path_template: Text, param_samples: Map(Text, Text)) : Text
  SecurityMatrixCore.substitute_params(path_template, param_samples)
end

## Synthesizes a minimal JSON value satisfying a compiler-derived OpenAPI / JSON Schema node.
fn synthesize_schema_sample(schema: Json) : Json
  SecurityMatrixCore.synthesize_schema_sample(schema)
end

fn route_listed?(listed: List((Text, Text)), method: Text, path_template: Text) : Bool
  SecurityMatrixCore.route_listed?(listed, method, path_template)
end

fn unauth_rejected?(res: Api.Response) : Bool
  SecurityMatrixCore.unauth_rejected?(res)
end

fn raw_data_page_unsafe?(raw_attr: Text, parsed_ok?: Bool) : Bool
  SecurityMatrixCore.raw_data_page_unsafe?(raw_attr, parsed_ok?)
end

fn inertia_html_response?(res: Api.Response) : Bool
  SecurityMatrixCore.inertia_html_response?(res)
end

fn valid_version_conflict?(res: Api.Response) : Bool
  SecurityMatrixCore.valid_version_conflict?(res)
end

fn logout_rejected?(res: Api.Response) : Bool
  SecurityMatrixCore.logout_rejected?(res)
end

fn extract_raw_data_page(html: Text) : Option(Text)
  SecurityMatrixCore.extract_raw_data_page(html)
end

fn unsafe_redirect_target?(loc: Text) : Bool
  SecurityMatrixCore.unsafe_redirect_target?(loc)
end

fn logout_route?(r: ApiTest.RouteSpec) : Bool
  SecurityMatrixCore.logout_route?(r)
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

fn map_check_kind(k: SecurityMatrixCore.AuditCheckKind) : AuditCheckKind
  case k
    SecurityMatrixCore.RoutesDiscovered: RoutesDiscovered
    SecurityMatrixCore.OpenApiValid: OpenApiValid
    SecurityMatrixCore.RouteHealthy: RouteHealthy
    SecurityMatrixCore.UnauthAccessRejected: UnauthAccessRejected
    SecurityMatrixCore.CsrfMissingRejected: CsrfMissingRejected
    SecurityMatrixCore.CsrfForgedRejected: CsrfForgedRejected
    SecurityMatrixCore.InertiaVersionConflict: InertiaVersionConflict
    SecurityMatrixCore.InertiaHtmlEscaped: InertiaHtmlEscaped
    SecurityMatrixCore.OpenRedirectBlocked: OpenRedirectBlocked
    SecurityMatrixCore.StrictJsonRejected: StrictJsonRejected
    SecurityMatrixCore.SessionRevocationHonored: SessionRevocationHonored
    SecurityMatrixCore.ForeignKeysEnabled: ForeignKeysEnabled
    SecurityMatrixCore.MigrationIdempotent: MigrationIdempotent
    SecurityMatrixCore.QueryBudgetRespected | SecurityMatrixCore.StorageIntegrityValid | SecurityMatrixCore
      .SecurityHeadersPresent: QueryBudgetRespected
  end
end

fn from_core_finding(f: SecurityMatrixCore.AuditFinding) : AuditFinding
  AuditFinding(
    check: map_check_kind(f.check),
    method: f.method,
    path: f.path,
    expected: f.expected,
    actual: f.actual,
    repro_curl: f.repro_curl
  )
end

fn to_core_config(cfg: AuditConfig) : SecurityMatrixCore.AuditConfig
  SecurityMatrixCore.AuditConfig(
    public_routes: cfg.public_routes,
    csrf_exempt_routes: cfg.csrf_exempt_routes,
    param_samples: cfg.param_samples,
    inertia_version: cfg.inertia_version,
    host_header: cfg.host_header,
    max_queries_per_get: cfg.max_queries_per_get
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
  SecurityMatrixCore.strict_json_probe_findings(m, path, sample_res, bad_json_res, unknown_res).map(
    from_core_finding
  )
end

fn check_routes_and_openapi(ordered: List(ApiTest.RouteSpec), openapi: Option(Json)) : List(
  AuditFinding
)
  SecurityMatrixCore.check_routes_and_openapi(ordered, openapi).map(from_core_finding)
end

## Audits every route discovered via `app.routes()` fail-closed against `db` and `authed_session`.
fn run(app: ApiTest.App, db: Sqlite.Database, authed_session: WebTest.Session, cfg: AuditConfig) : AuditReport
  ordered = SecurityMatrixCore.order_routes(app.routes())
  var findings = []
  var checks_run = 0

  checks_run += 1
  if check_fk_enabled(db) is Some(fk_finding)
    findings = findings.append(fk_finding)
  end

  # Run SQLite N+1 query budget checks before `SecurityMatrixCore.run_app` revokes `authed_session` via logout.
  guest = WebTest.with_header(WebTest.start(), "Host", cfg.host_header)
  authed_base = WebTest.with_header(
    WebTest.without_inertia(authed_session),
    "Host",
    cfg.host_header
  )
  for r in ordered
    m = r.method.ascii_uppercase
    if m == "GET"
      path = substitute_params(r.path_template, cfg.param_samples)
      is_public? = route_listed?(cfg.public_routes, m, r.path_template)
      use_session = if is_public?: guest else: authed_base
      checks_run += 1
      db.reset_stats()
      (_gs, _get_res) = WebTest.send(
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
    end
  end

  core_rep = SecurityMatrixCore.run_app(app, authed_session, to_core_config(cfg))
  for cf in core_rep.findings
    findings = findings.append(from_core_finding(cf))
  end

  AuditReport(
    routes_checked: ordered.size,
    checks_run: checks_run + core_rep.checks_run,
    findings: findings
  )
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
  assert synthesize_schema_sample(
    Json.Object({
      "type": Json.String("array"),
      "minItems": Json.int(5),
      "items": Json.Object({"type": Json.String("integer")})
    })
  ) ==
    Json.Array([Json.int(1), Json.int(1), Json.int(1), Json.int(1), Json.int(1)])

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
