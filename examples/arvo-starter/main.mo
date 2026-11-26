## Arvo + Inertia v2 full-stack starter server demonstrating typed `Arvo.Inertia` pages,
## `PageContract` manifest export (`--arvo-contracts`), `Arvo.Seed` profiles, `Arvo.WebTest` v2,
## `Arvo.SecurityMatrix`, `Arvo.Sim`, and Executable Feature Maps (`Arvo.Feature`).
module Main
use Api
use Arvo.Inertia
use Arvo.Session
use Arvo.Sqlite.Migrations
use Arvo.Sqlite.Sessions
use Arvo.Testing.Feature
use Arvo.Testing.SecurityMatrix
use Arvo.Testing.Seed
use Arvo.Testing.Sim
use Arvo.Testing.SqliteTest
use Arvo.WebTest
use Http
use Json
use Routes

api
  port 8080
  sqlite db from "starter.sqlite"
  static "/assets" from "public/assets"
  auth Routes.Member via Routes.authenticate

  get "/login" Routes.show_login
  post "/login" Routes.post_login
  post "/logout" Routes.post_logout
  get "/" Routes.home

  scope "/bills"
    post "" Routes.create_bill
    post "/:id/pay" Routes.pay_bill
  end

  scope "/imports"
    post "/csv" Routes.import_csv
  end

  status Routes.Unauthenticated = 401
  status Routes.Forbidden = 403
  status Routes.BillNotFound(_) = 404
  status Routes.VersionConflict(_) = 409
  status Routes.BadUpload(_) = 422
  status Routes.ServerFailed(_) = 500
end

fn parse_flag_value(args: List(Text), flag: Text) : Option(Text)
  for (idx, a) in args.enumerate
    if a == flag
      return args.get(idx + 1)
    end
  end
  None
end

fn starter_db_path(args: List(Text)) : Result(Text, Text)
  if not args.contains?("--db")
    return Ok("starter.sqlite")
  end
  path = parse_flag_value(args, "--db") or ""
  if path.empty? or path.starts_with?("-")
    Error("--db requires a database path")
  else
    Ok(path)
  end
end

fn reset_starter_db(
  db: Sqlite.Database,
  profile: Text,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Unit, Text)
  profiles = Routes.seed_profiles()
  if Seed.find_profile(profiles, profile) is None
    return Seed.run_profile(profiles, profile, db, rng, clock, env)
  end
  _mig = try Migrations.run(db, clock, Routes.app_migrations()).map_error(fn(e) "#{e}" end)
  Sqlite.transaction(
    db,
    (profiles, profile, rng, clock, env),
    fn(tx, ctx)
      (seed_profiles, name, random, now, config) = ctx
      for tbl in ["arvo_sessions", "arvo_events", "bills", "members"]
        try tx.run("DELETE FROM #{tbl}", []).map_error(fn(e) "#{e}" end)
      end
      try tx.run("DELETE FROM sqlite_sequence WHERE name = 'bills'", []).map_error(fn(e) "#{e}" end)
      Seed.run_profile(seed_profiles, name, tx, random, now, config)
    end,
    fn(e) "#{e}" end
  )
end

## Prints `PageContract` manifest (`--arvo-contracts`) or applies `--arvo-seed` / `--arvo-reset` profiles.
fn main(args: Args, console: Console, sqlite: Sqlite, rng: SecureRandom, clock: Clock, env: Env) : Int
  alist = args.list
  if alist.contains?("--arvo-contracts")
    console.print(Json.encode(Routes.contracts()))
    0
  else if alist.contains?("--arvo-seed")
    profile = case parse_flag_value(alist, "--arvo-seed")
      Some(p):
        if p.empty? or p.starts_with?("-")
          console.error("--arvo-seed requires a profile name")
          return 2
        end
        p
      None:
        console.error("--arvo-seed requires a profile name")
        return 2
    end
    db_path = case starter_db_path(alist)
      Ok(p): p
      Error(e):
        console.error(e)
        return 2
    end
    db = case sqlite.open(db_path)
      Ok(d): d
      Error(e):
        console.error("failed opening #{db_path}: #{e}")
        return 1
    end
    case Seed.run_profile(Routes.seed_profiles(), profile, db, rng, clock, env)
      Ok(_):
        console.print(Json.Object({"seeded": Json.String(profile), "db": Json.String(db_path)}).to_text)
        0
      Error(err):
        console.error("seed failed: #{err}")
        1
    end
  else if alist.contains?("--arvo-reset")
    profile = case parse_flag_value(alist, "--arvo-reset")
      Some(p):
        if p.empty? or p.starts_with?("-")
          console.error("--arvo-reset requires a profile name")
          return 2
        end
        p
      None:
        console.error("--arvo-reset requires a profile name")
        return 2
    end
    db_path = case starter_db_path(alist)
      Ok(p): p
      Error(e):
        console.error(e)
        return 2
    end
    db = case sqlite.open(db_path)
      Ok(d): d
      Error(e):
        console.error("failed opening #{db_path}: #{e}")
        return 1
    end
    case reset_starter_db(db, profile, rng, clock, env)
      Ok(_):
        console.print(Json.Object({"reset": Json.String(profile), "db": Json.String(db_path)}).to_text)
        0
      Error(err):
        console.error("reset failed: #{err}")
        1
    end
  else
    console.print("Start the server with: mo serve main.mo --data .")
    0
  end
end

fn test_manifest_json() : Text
  """
    {
      "src/main.tsx": {
        "file": "assets/main-a1b2c3d4.js",
        "css": ["assets/main-f9e8d7c6.css"],
        "isEntry": true
      }
    }
    """
end

fn test_asset_map() : Map(Text, Text)
  {
    "public/manifest.json": test_manifest_json(),
    "public/assets/main-a1b2c3d4.js": "console.log('arvo starter');",
    "public/assets/main-f9e8d7c6.css": "body{margin:0}"
  }
end

fn test_env_map() : Map(Text, Text)
  {
    "ARVO_SECRET_KEY": "1111111111111111111111111111111122222222222222222222222222222222",
    "ARVO_ALLOWLIST": "ada@household.local,grace@household.local",
    "ARVO_SEED_PASSWORD": "horse-staple-battery",
    "ARVO_INSECURE_COOKIES": "1"
  }
end

test "starter end-to-end flow via WebTest v2, query budgets, Seed profiles, and Inertia fixture recording"
  expected_version = Inertia.version_from_manifest(test_manifest_json().bytes)
  files = Files.in_memory(test_asset_map()).read_only
  sql = Sqlite.in_memory()
  rng = SecureRandom.seeded(2026)
  t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of(test_env_map())
  app = ApiTest.start(Main, sql, clock, files, env, rng)
  assert sql.open("starter.sqlite") is Ok(db)

  # 0. CLI entrypoint, migrations, seed/reset flags, & contracts manifest cover both pages cleanly
  assert (Routes.app_migrations().first or stop "migration").version == 1
  c_contracts = Console.fake()
  assert main(Args.of(["--arvo-contracts"]), c_contracts, sql, rng, clock, env) == 0
  assert (c_contracts.printed.first or "").contains?("\"component\":\"Home\"")
  c_help = Console.fake()
  assert main(Args.of([]), c_help, sql, rng, clock, env) == 0
  assert (c_help.printed.first or "").contains?("mo serve main.mo")
  assert Routes.contracts().map(fn(c) c.component end) == ["Login", "Home"]

  # 0b. CLI --arvo-seed and --arvo-reset work deterministically and reject invalid args
  assert parse_flag_value(["--arvo-seed", "baseline", "--extra", "--db", "odd.sqlite"], "--db") ==
    Some("odd.sqlite")
  assert parse_flag_value(["--arvo-seed", "baseline", "--db"], "--db") == None
  sql_cli = Sqlite.in_memory()
  c_seed = Console.fake()
  assert main(
    Args.of(["--arvo-seed", "many_bills", "--db", "cli.sqlite"]),
    c_seed,
    sql_cli,
    rng,
    clock,
    env
  ) ==
    0
  assert (c_seed.printed.first or "").contains?("\"seeded\":\"many_bills\"")
  assert sql_cli.open("cli.sqlite") is Ok(db_cli)
  assert db_cli.query("SELECT id FROM bills", []) is Ok(cli_bills) and cli_bills.rows.size == 9

  c_rst = Console.fake()
  assert main(
    Args.of(["--arvo-reset", "baseline", "--db", "cli.sqlite"]),
    c_rst,
    sql_cli,
    rng,
    clock,
    env
  ) ==
    0
  assert (c_rst.printed.first or "").contains?("\"reset\":\"baseline\"")
  assert db_cli.query("SELECT id FROM bills", []) is Ok(rst_bills) and rst_bills.rows.size == 1

  c_bad_cli = Console.fake()
  assert main(Args.of(["--arvo-seed"]), c_bad_cli, sql_cli, rng, clock, env) == 2
  assert main(Args.of(["--arvo-seed", "--db"]), c_bad_cli, sql_cli, rng, clock, env) == 2
  assert main(Args.of(["--arvo-seed", "nope"]), c_bad_cli, sql_cli, rng, clock, env) == 1
  assert main(Args.of(["--arvo-seed", "baseline", "--db", "../bad.sqlite"]), c_bad_cli, sql_cli, rng, clock, env) == 1
  assert main(Args.of(["--arvo-reset"]), c_bad_cli, sql_cli, rng, clock, env) == 2
  assert main(Args.of(["--arvo-reset", "-x"]), c_bad_cli, sql_cli, rng, clock, env) == 2
  assert main(Args.of(["--arvo-reset", "nope"]), c_bad_cli, sql_cli, rng, clock, env) == 1
  assert main(Args.of(["--arvo-reset", "baseline", "--db", "../bad.sqlite"]), c_bad_cli, sql_cli, rng, clock, env) == 1
  assert main(Args.of(["--arvo-reset", "baseline", "--db"]), c_bad_cli, sql_cli, rng, clock, env) == 2
  assert main(Args.of(["--arvo-seed", "baseline", "--db", "--bad"]), c_bad_cli, sql_cli, rng, clock, env) == 2
  assert main(Args.of(["--arvo-reset", "nope", "--db", "cli.sqlite"]), c_bad_cli, sql_cli, rng, clock, env) == 1
  assert db_cli.query("SELECT id FROM bills", []) is Ok(after_bad_profile) and after_bad_profile == rst_bills
  assert db_cli.run(
    "CREATE TRIGGER fail_reset BEFORE INSERT ON bills BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    []
  ) == Ok(Unit)
  assert main(Args.of(["--arvo-reset", "baseline", "--db", "cli.sqlite"]), c_bad_cli, sql_cli, rng, clock, env) == 1
  assert db_cli.query("SELECT id FROM bills", []) is Ok(after_failed_seed) and after_failed_seed == rst_bills

  # 1. Static asset ETag / 304 behavior
  asset_res = app.send(Api.get("/assets/main-a1b2c3d4.js"))
  _ = WebTest.expect_status(asset_res, 200)
  assert asset_res.header("Cache-Control") == Some("public, max-age=31536000, immutable")
  etag = asset_res.header("ETag") or ""
  assert not etag.empty?
  not_mod = app.send(Api.get("/assets/main-a1b2c3d4.js").with_header("If-None-Match", etag))
  _ = WebTest.expect_status(not_mod, 304)

  # 2. Guest redirects and unauthenticated API 401
  fx_files = Files.in_memory({})
  s0 = WebTest.start().with_header("Host", "localhost:8080")
  (s1, guest_home) = WebTest.get(s0, app, "/")
  _ = WebTest.expect_redirect(guest_home, "/login")
  (s2, unauth_pay) = WebTest.post_json(
    s1,
    app,
    "/bills/1/pay",
    Routes.PayInput(expected_version: 1, reason: None)
  )
  _ = WebTest.expect_status(unauth_pay, 401)

  # 3. Login HTML load, typed props decode, and fixture export
  (s3, login_res) = WebTest.get(s2, app, "/login")
  _ = WebTest.expect_status(login_res, 200)
  login_props = WebTest.expect_inertia[Routes.LoginProps](login_res, "Login")
  assert login_props.allowlist_hint == "Household members only"
  assert WebTest.record_inertia_fixture(fx_files, "login_guest", login_res) == Ok(Unit)
  assert fx_files.exists?(".arvo/fixtures/Login/login_guest.json")

  # 4. Login -> 303 redirect -> follow redirect -> typed HomeProps + flash notice + HTML escaping
  (s4, post_login_res) = WebTest.post_form(
    s3,
    app,
    "/login",
    [("email", "Ada@Household.Local"), ("password", "horse-staple-battery")]
  )
  _ = WebTest.expect_redirect(post_login_res, "/")
  login_set_cookies = post_login_res.headers.filter(fn(h) h.0.ascii_lowercase == "set-cookie" end)
    .map(fn(h) h.1 end).join(";")
  assert login_set_cookies.contains?("Max-Age=1209600")
  assert not login_set_cookies.contains?("; Secure")
  (s5, home_res) = WebTest.follow_redirect(s4, app)
  _ = WebTest.expect_status(home_res, 200)
  assert home_res.text.contains?("&lt;Utility&gt;")
  assert not home_res.text.contains?("<Utility>")
  home_props = WebTest.expect_inertia[Routes.HomeProps](home_res, "Home")
  assert home_props.total_due_cents == 14500
  assert home_props.bills.size == 1
  WebTest.expect_flash_notice(home_res, "Signed in")
  assert WebTest.record_inertia_fixture(fx_files, "home_baseline", home_res) == Ok(Unit)

  # 5. Query-count budget on GET /
  db.reset_stats()
  (s6, budgeted_home) = WebTest.get(s5, app, "/")
  _ = WebTest.expect_status(budgeted_home, 200)
  SqliteTest.expect_max_queries(db, 10, "GET /")

  # Authenticated GET /login redirects to /
  (s7, revisit_login) = WebTest.get(s6, app, "/login")
  _ = WebTest.expect_redirect(revisit_login, "/")

  # 6. CSRF missing rejected 403
  (s8, no_csrf_res) = WebTest.post_without_csrf(
    s7,
    app,
    "/bills",
    "name=Water&category=utilities&amount_cents=4200".bytes,
    "application/x-www-form-urlencoded"
  )
  _ = WebTest.expect_status(no_csrf_res, 403)

  # 7. Validation errors carried across redirect + cleared on next GET
  s_ref = WebTest.with_header(s8, "Referer", "http://localhost:8080/?status=due")
  (s9, bad_bill) = WebTest.post_form(
    s_ref,
    app,
    "/bills",
    [("name", ""), ("category", "invalid_cat"), ("amount_cents", "0")]
  )
  _ = WebTest.expect_redirect(bad_bill, "/?status=due")
  s9_xhr = WebTest.with_inertia(s9, expected_version)
  (s10, err_page) = WebTest.follow_redirect(s9_xhr, app)
  _ = WebTest.expect_status(err_page, 200)
  WebTest.expect_validation_error(err_page, "name", "blank")
  WebTest.expect_validation_error(err_page, "category", "must be one of")
  WebTest.expect_validation_error(err_page, "amount_cents", "greater than 0")

  (s11, cleared_res) = WebTest.get(s10, app, "/")
  assert cleared_res.text.contains?("\"errors\":{}")

  # 8. Create valid bill + follow redirect + partial reload + stale version 409
  (s12, create_res) = WebTest.post_form(
    s11,
    app,
    "/bills",
    [("name", "Fiber Internet"), ("category", "utilities"), ("amount_cents", "7500")]
  )
  _ = WebTest.expect_redirect(create_res, "/")
  (s13, created_home) = WebTest.follow_redirect(s12, app)
  WebTest.expect_flash_notice(created_home, "Bill added")
  created_home_props = WebTest.expect_inertia[Routes.HomeProps](created_home, "Home")
  assert created_home_props.bills.any?(fn(b) b.name == "Fiber Internet" and b.version == 1 end)
  assert db.query("SELECT after_json FROM arvo_events WHERE action = 'bill.create' LIMIT 1", []) is
    Ok(ev_create_q)
  assert case ev_create_q.rows.first
    Some([Sqlite.String(aj)]): aj.contains?("\"version\":1")
    None | Some(_): false
  end

  partial_req = WebTest.prepare(
    s13.client,
    Api.get("/").with_header("X-Inertia-Partial-Component", "Home").with_header(
      "X-Inertia-Partial-Data",
      "total_due_cents"
    )
  )
  partial_res = app.send(partial_req)
  _ = WebTest.expect_status(partial_res, 200)
  assert partial_res.text.contains?("\"total_due_cents\":22000")
  assert not partial_res.text.contains?("audit_feed")

  (s14, mismatch_res) = WebTest.get(WebTest.with_inertia(s13, "outdated-sha"), app, "/?status=due")
  _ = WebTest.expect_status(mismatch_res, 409)
  assert mismatch_res.header("X-Inertia-Location") == Some("/?status=due")

  # 9. Multipart CSV upload + JSON optimistic-lock payment (200 then 409)
  s_good = WebTest.with_inertia(s14, expected_version)
  csv_bytes = "name,category,amount_cents\nCity Water,utilities,3800\nRent,housing,185000\n".bytes
  (s15, csv_res) = WebTest.post_multipart(
    s_good,
    app,
    "/imports/csv",
    [("default_category", "utilities")],
    [
      WebTest.TestFile(
        field_name: "statement",
        filename: "bills.csv",
        content_type: "text/csv",
        data: csv_bytes
      )
    ]
  )
  _ = WebTest.expect_status(csv_res, 200)
  assert Json.decode_strict[Map(Text, Int)](csv_res.text) == Ok({"imported": 2})

  (s16, pay_ok) = WebTest.post_json(
    WebTest.without_inertia(s15),
    app,
    "/bills/1/pay",
    Routes.PayInput(expected_version: 1, reason: Some("Paid from checking"))
  )
  _ = WebTest.expect_status(pay_ok, 200)
  assert Json.decode_strict[Routes.Bill](pay_ok.text) is Ok(paid_b)
  assert paid_b.status == "in_flight" and paid_b.version == 2

  (s17, pay_stale) = WebTest.post_json(
    s16,
    app,
    "/bills/1/pay",
    Routes.PayInput(expected_version: 1, reason: None)
  )
  _ = WebTest.expect_status(pay_stale, 409)

  (s18, feed_res) = WebTest.get(s17, app, "/")
  feed_props = WebTest.expect_inertia[Routes.HomeProps](feed_res, "Home")
  assert feed_props.audit_feed.size == 4

  (s_browser, browser_pay) = WebTest.post_json(
    WebTest.with_inertia(s18, expected_version),
    app,
    "/bills/2/pay",
    Routes.PayInput(expected_version: 1, reason: None)
  )
  _ = WebTest.expect_redirect(browser_pay, "/")
  (s_paid, browser_home) = WebTest.follow_redirect(s_browser, app)
  WebTest.expect_flash_notice(browser_home, "Bill marked in flight")
  browser_props = WebTest.expect_inertia[Routes.HomeProps](browser_home, "Home")
  assert browser_props.bills.any?(fn(b) b.id == 2 and b.status == "in_flight" and b.version == 2 end)
  (s_stale, browser_conflict) = WebTest.post_json(
    s_paid,
    app,
    "/bills/2/pay",
    Routes.PayInput(expected_version: 1, reason: None)
  )
  _ = WebTest.expect_redirect(browser_conflict, "/")
  (_s_current, browser_current) = WebTest.follow_redirect(s_stale, app)
  current_shared = WebTest.expect_inertia[Routes.SharedProps](browser_current, "Home")
  assert current_shared.flash.alert == Some("This bill changed; review its current status.")

  # 10. Logout revokes session & clears cookies so stale replay fails
  captured = s18
  (s19, logout_res) = WebTest.post_form(s18, app, "/logout", [])
  _ = WebTest.expect_redirect(logout_res, "/login")
  assert WebTest.cookie(s19, "arvo_session") == None

  (_rep1, replay_home) = WebTest.get(captured, app, "/")
  _ = WebTest.expect_redirect(replay_home, "/login")
  (_rep2, replay_api) = WebTest.post_json(
    captured,
    app,
    "/bills/1/pay",
    Routes.PayInput(expected_version: 2, reason: None)
  )
  _ = WebTest.expect_status(replay_api, 401)

  # 11. Arvo.Seed profiles (`empty`, `baseline`, `many_bills`) work deterministically
  profiles = Routes.seed_profiles()
  sql_emp = Sqlite.in_memory()
  assert sql_emp.open("s.sqlite") is Ok(db_emp)
  assert Seed.run_profile(profiles, "empty", db_emp, rng, clock, env) == Ok(Unit)
  assert db_emp.query("SELECT id FROM bills", []) is Ok(r_emp) and r_emp.rows.empty?

  sql_many = Sqlite.in_memory()
  assert sql_many.open("s.sqlite") is Ok(db_many)
  assert Seed.run_profile(profiles, "many_bills", db_many, rng, clock, env) == Ok(Unit)
  assert db_many.query("SELECT id FROM bills", []) is Ok(r_many) and r_many.rows.size == 9
  assert db_many.query("SELECT SUM(amount_cents) FROM bills", []) is Ok(r_sum)
  assert r_sum.rows.first == Some([Sqlite.Integer(324500)])
end

test "starter passes zero-config Arvo.SecurityMatrix across all routes"
  expected_version = Inertia.version_from_manifest(test_manifest_json().bytes)
  files = Files.in_memory(test_asset_map()).read_only
  sql = Sqlite.in_memory()
  rng = SecureRandom.seeded(77)
  t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of(test_env_map())
  app = ApiTest.start(Main, sql, clock, files, env, rng)
  assert sql.open("starter.sqlite") is Ok(db)

  s0 = WebTest.start().with_header("Host", "localhost:8080")
  (authed, login_res) = WebTest.post_form(
    s0,
    app,
    "/login",
    [("email", "ada@household.local"), ("password", "horse-staple-battery")]
  )
  _ = WebTest.expect_redirect(login_res, "/")

  cfg = SecurityMatrix.AuditConfig(
    public_routes: [("GET", "/login"), ("POST", "/login")],
    csrf_exempt_routes: [],
    param_samples: {"id": "1"},
    inertia_version: expected_version,
    host_header: "localhost:8080",
    max_queries_per_get: 10
  )
  report = SecurityMatrix.run_full(app, db, clock, authed, cfg, Routes.app_migrations())
  assert SecurityMatrix.passed?(report)
  SecurityMatrix.assert_clean(report)
  assert report.routes_checked == 7
end

struct StarterSimWorld
  ada_cookie: Text
  ada_csrf: Text
  grace_cookie: Text
  grace_csrf: Text
  stale_cookies: List(Text)
  created_count: Int
end

enum StarterSimAction
  PayBill(expected_version: Int)
  CreateBill(amount_cents: Int)
  ViewHome
end

test "starter passes Arvo.Sim multi-user concurrent bill-payment and session simulation"
  t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"

  mint_sim_actor = fn(db, rng, clock, member_id)
    key = Bytes.from_hex("1111111111111111111111111111111122222222222222222222222222222222") or
      "".bytes
    scfg = Session.default_config(false)
    (sess, raw_cookie) = try Sessions.create(db, rng, clock, key, member_id, scfg).map_error(
      fn(e) "#{e}" end
    )
    Ok((raw_cookie, sess.csrf_token))
  end

  starter_sim_invariants = fn()
    base = Sim.default_invariants()
    bills_inv = Sim.Invariant(
      name: "starter_bills_valid",
      check: fn(_w, db, _clk)
        rows = try db.query("SELECT id, amount_cents, status, version FROM bills", []).map_error(
          fn(e) "#{e}" end
        )
        for row in rows.rows
          case row
            [Sqlite.Integer(bid), Sqlite.Integer(amt), Sqlite.String(st), Sqlite.Integer(ver)]:
              if amt <= 0
                return Error("bill #{bid} has non-positive amount #{amt}")
              end
              if ver < 1 or (st == "in_flight" and ver < 2)
                return Error("bill #{bid} has invalid version #{ver} for status #{st}")
              end
            _: return Error("unexpected bill row shape")
          end
        end
        Ok(Unit)
      end
    )
    flight_inv = Sim.Invariant(
      name: "starter_single_flight_bill1",
      check: fn(_w, db, _clk)
        rows = try db.query(
          "SELECT id FROM arvo_events WHERE action = 'bill.mark_in_flight' AND entity_id = '1'",
          []
        ).map_error(fn(e) "#{e}" end)
        if rows.rows.size > 1
          Error("bill 1 marked in flight #{rows.rows.size} times")
        else
          Ok(Unit)
        end
      end
    )
    base.append(bills_inv).append(flight_inv)
  end

  init_world = fn(seed)
    files = Files.in_memory(test_asset_map()).read_only
    env = Env.of(test_env_map())
    sql = Sqlite.in_memory()
    clk = Clock.fixed(t0)
    srng = SecureRandom.seeded(seed)
    rng = Random.seeded(seed)
    app = ApiTest.start(Main, sql, clk, files, env, srng)
    db = case sql.open("starter.sqlite")
      Ok(d): d
      Error(_): stop "open starter.sqlite"
    end
    # Pre-seed schema, members, and bill directly (avoiding repeated scrypt in multi-seed DST loop)
    _m = case Migrations.run(db, clk, Routes.app_migrations())
      Ok(n): n
      Error(_e): stop "migrate failed"
    end
    now_s = clk.now.to_text
    _ins1 = db.run(
      "INSERT INTO members (id, email, password_hash, display_name, created_at) VALUES ('mem_ada', 'ada@household.local', 'sim-hash', 'Ada & Household <Team>', ?)",
      [Sqlite.String(now_s)]
    )
    _ins2 = db.run(
      "INSERT INTO members (id, email, password_hash, display_name, created_at) VALUES ('mem_grace', 'grace@household.local', 'sim-hash', 'Grace Partner', ?)",
      [Sqlite.String(now_s)]
    )
    _insb = db.run(
      "INSERT INTO bills (id, name, category, amount_cents, status, version, created_at) VALUES (1, 'Electric & Gas <Utility>', 'utilities', 14500, 'due', 1, ?)",
      [Sqlite.String(now_s)]
    )
    (ac, at) = case mint_sim_actor(db, srng, clk, "mem_ada")
      Ok(pair): pair
      Error(_e): stop "mint ada failed"
    end
    (gc, gt) = case mint_sim_actor(db, srng, clk, "mem_grace")
      Ok(pair): pair
      Error(_e): stop "mint grace failed"
    end
    w = StarterSimWorld(
      ada_cookie: ac,
      ada_csrf: at,
      grace_cookie: gc,
      grace_csrf: gt,
      stale_cookies: [],
      created_count: 0
    )
    (w, db, clk, srng, rng, app)
  end

  cfg = Sim.SimConfig(
    base_seed: 1,
    seed_count: 15,
    max_steps: 24,
    shrink_budget: 100,
    fault_probability_pct: 15
  )

  next_step = fn(rng, _w)
    if Sim.maybe_system_fault(rng, cfg, 2, ["bill.reminder"]) is Some(sys_ev)
      return Sim.System(event: sys_ev)
    end
    pick = rng.int(0, 6)
    if pick == 0
      Sim.AppAction(actor_idx: rng.int(0, 2), action: CreateBill(amount_cents: 1200 + rng.int(1, 500)))
    else if pick == 1
      Sim.AppAction(actor_idx: rng.int(0, 2), action: ViewHome)
    else
      Sim.AppAction(actor_idx: rng.int(0, 2), action: PayBill(expected_version: 1))
    end
  end

  apply_step = fn(w, step, db, clk, app)
    case step
      Sim.System(event: ev):
        case ev
          Sim.RotateActorSession(actor_idx: idx):
            old_cookie = if idx == 0: w.ada_cookie else: w.grace_cookie
            old_csrf = if idx == 0: w.ada_csrf else: w.grace_csrf
            logout_res = app.send(
              Api.post("/logout").with_header("Cookie", "arvo_session=#{old_cookie}").with_header(
                "X-XSRF-TOKEN",
                old_csrf
              )
            )
            if logout_res.status >= 500
              return Error("logout returned #{logout_res.status}")
            end
            srng = SecureRandom.seeded(100 + w.created_count + w.stale_cookies.size * 7 + idx)
            mid = if idx == 0: "mem_ada" else: "mem_grace"
            (nc, nt) = try mint_sim_actor(db, srng, clk, mid)
            next_w = if idx == 0
              StarterSimWorld(
                ada_cookie: nc,
                ada_csrf: nt,
                grace_cookie: w.grace_cookie,
                grace_csrf: w.grace_csrf,
                stale_cookies: w.stale_cookies.append(old_cookie),
                created_count: w.created_count
              )
            else
              StarterSimWorld(
                ada_cookie: w.ada_cookie,
                ada_csrf: w.ada_csrf,
                grace_cookie: nc,
                grace_csrf: nt,
                stale_cookies: w.stale_cookies.append(old_cookie),
                created_count: w.created_count
              )
            end
            Ok(next_w)
          Sim.ReplayStaleSessionCookie(actor_idx: _):
            case w.stale_cookies.last
              None: Ok(w)
              Some(sc):
                rep_get = app.send(Api.get("/").with_header("Cookie", "arvo_session=#{sc}"))
                if rep_get.status == 200
                  return Error("revoked session cookie unexpectedly rendered /")
                end
                rep_post = app.send(
                  Api.post("/bills/1/pay").with_header("Cookie", "arvo_session=#{sc}").with_json(
                    Routes.PayInput(expected_version: 1, reason: None)
                  )
                )
                if rep_post.status != 401
                  return Error("revoked session cookie expected 401, got #{rep_post.status}")
                end
                Ok(w)
            end
          Sim.InjectNetworkFault(target: t, fault: f):
            net = Network.fake_scripted([("GET", t, [f])])
            res = Http.get(t).send(net)
            try Sim.verify_network_fault(t, f, res, Network.recorded_calls(net))
            Ok(w)
          Sim.AdvanceClock(duration: _) | Sim.ExpirePruneSessions | Sim.RunNextJob(job_names: _) | Sim
            .CrashRunningJob | Sim.RequeueStaleJobs(stale_seconds: _):
            try Sim.apply_standard_system_event(ev, db, clk, app)
            Ok(w)
        end
      Sim.AppAction(actor_idx: actor_idx, action: action):
        ck = if actor_idx == 0: w.ada_cookie else: w.grace_cookie
        cs = if actor_idx == 0: w.ada_csrf else: w.grace_csrf
        req = case action
          PayBill(expected_version: ver): Api.post("/bills/1/pay").with_header(
            "Cookie",
            "arvo_session=#{ck}"
          ).with_header("X-XSRF-TOKEN", cs).with_json(
            Routes.PayInput(expected_version: ver, reason: None)
          )
          CreateBill(amount_cents: amt): Api.post("/bills").with_header(
            "Cookie",
            "arvo_session=#{ck}"
          ).with_header("X-XSRF-TOKEN", cs).with_bytes(
            "name=SimBill&category=utilities&amount_cents=#{amt}".bytes,
            "application/x-www-form-urlencoded"
          )
          ViewHome: Api.get("/").with_header("Cookie", "arvo_session=#{ck}").with_header(
            "Host",
            "localhost:8080"
          )
        end
        res = app.send(req)
        if res.status >= 500
          return Error("unexpected 5xx status #{res.status}")
        end
        next_cnt = if action is CreateBill(amount_cents: _): w.created_count + 1 else: w
          .created_count
        Ok(
          StarterSimWorld(
            ada_cookie: w.ada_cookie,
            ada_csrf: w.ada_csrf,
            grace_cookie: w.grace_cookie,
            grace_csrf: w.grace_csrf,
            stale_cookies: w.stale_cookies,
            created_count: next_cnt
          )
        )
    end
  end

  sim_res = Sim.run(cfg, init_world, next_step, apply_step, starter_sim_invariants())
  case sim_res
    Ok(summary):
      assert summary.seeds_run == 15
      assert summary.total_steps == 360
      assert summary.system_events_run > 0
    Error(f): assert Sim.format_failure(f) == "OK"
  end
end

struct FeatWorld
  captured_cookie: Option(Text)
  grace_session: Option(WebTest.Session)
  last_home: Option(Routes.HomeProps)
end

auth_feature_spec = """
# Authentication and sessions

Household members sign in with an allowlisted email and passphrase to receive an encrypted session cookie and readable CSRF cookie, and revoke their server session when signing out.

## Sub-features

- `auth-guest-gate`: redirects unauthenticated browsers visiting `/` to `/login` and rejects API endpoints with `401`.
- `auth-login`: validates allowlist and password, issues session + CSRF cookies, and flashes a sign-in notice.
- `auth-logout`: revokes the active session so previously captured cookies cannot replay protected routes.

## How to get to it (user POV)

- Visit `/login` in a browser, enter `Email` and `Password`, and click `Sign in`.
- Click `Sign out` in the `Home` header to end the session.

## Scenarios

```gherkin
Feature: Authentication and sessions
  Background:
    Given seed profile "baseline"

  @smoke @browser @mobile @aria @screenshot
  Scenario: Guest visiting home is redirected to login and signs in successfully
    When I visit "/"
    Then the response redirects to "/login"
    When I visit "/login"
    Then the Inertia component is "Login"
    When I submit login form with email "Ada@Household.Local" and password "horse-staple-battery"
    Then the response redirects to "/"
    When I follow the redirect
    Then the Inertia component is "Home"
    And the flash notice is "Signed in"
    And the page shows heading "Ada & Household <Team>"

  @smoke @db-check
  Scenario: Sign out revokes session and blocks cookie replay
    Given signed in as "ada@household.local"
    When I sign out
    Then the response redirects to "/login"
    When I replay the previous session on "/"
    Then the response redirects to "/login"
    And audit trail contains action "auth.login" by "ada@household.local" for "members"

  @smoke
  Scenario: Non-allowlisted email shows validation error on login
    When I submit login form with email "intruder@evil.test" and password "anything"
    Then the response redirects to "/login"
    When I follow the redirect
    Then validation error for "email" contains "allowlist"
```

## Gotchas

- `display_name` intentionally contains `<` and `&` characters to prove HTML attribute escaping in `data-page`.
- Signing out must delete the server session row, not merely clear browser cookies.
"""

bills_feature_spec = """
# Paycheck bills and optimistic concurrency

Signed-in household members view due paycheck bills, create new bills with field validation, and mark a bill in flight with optimistic version checking.

## Sub-features

- `bill-create`: validates name, category, and positive amount before persisting and logging an audit event.
- `bill-pay-happy`: marks a due bill `in_flight` and increments its version alongside an audit record.
- `bill-pay-conflict`: rejects a stale concurrent `expected_version` update with `409 Conflict`.

## How to get to it (user POV)

- Sign in at `/login`, open `/` (`Home`), and submit the `Add Bill` form or click `Mark paid` beside a due bill.

## Scenarios

```gherkin
Feature: Paycheck bills and optimistic concurrency
  Background:
    Given seed profile "baseline"
    And signed in as "ada@household.local"

  @smoke @browser @mobile @aria @screenshot @db-check
  Scenario: Member creates a new bill and sees updated total due
    When I visit "/"
    Then the Inertia component is "Home"
    And the bill "Electric & Gas <Utility>" shows status "due"
    When I submit new bill name "Fiber Internet" category "utilities" amount_cents "7500"
    Then the response redirects to "/"
    When I follow the redirect
    Then the flash notice is "Bill added"
    And the bill "Fiber Internet" shows status "due"
    And total due cents is 22000
    And audit trail contains action "bill.create" by "ada@household.local" for "bills"

  @smoke @browser @db-check
  Scenario: Member marks a due bill in flight and stale version conflicts with 409
    When actor "ada" marks bill 1 in flight with expected version 1
    Then the response status is 200
    And the bill "Electric & Gas <Utility>" shows status "in_flight"
    When actor "grace" marks bill 1 in flight with expected version 1
    Then the response status is 409
    And audit trail contains action "bill.mark_in_flight" by "ada@household.local" for "bills"

  @smoke
  Scenario: Blank bill name and zero amount flash validation errors across redirect
    When I submit new bill name "" category "bad_cat" amount_cents "0"
    Then the response redirects to "/"
    When I follow the redirect
    Then validation error for "name" contains "blank"
    And validation error for "amount_cents" contains "greater than 0"
```

## Gotchas

- Concurrent partners must see `409 Conflict` when paying with a stale `expected_version` rather than silently overwriting the bill.
- Bill names contain `<` and `&` to verify XSS attribute escaping across initial HTML loads.
"""

csv_feature_spec = """
# CSV statement import

Signed-in members upload a bank or utility CSV statement (`name,category,amount_cents`) via multipart form data to bulk-create due bills with a single audit event.

## Sub-features

- `csv-import-happy`: parses CSV rows, applies `default_category` when category is blank, inserts bills, and logs `bills.csv_import`.
- `csv-import-reject`: rejects malformed rows with `422` without partial failure of validation guards.

## How to get to it (user POV)

- Send `POST /imports/csv` with multipart field `statement` and active session + CSRF header.

## Scenarios

```gherkin
Feature: CSV statement import
  Background:
    Given seed profile "baseline"
    And signed in as "ada@household.local"

  @smoke @db-check
  Scenario: Valid CSV upload creates multiple bills and writes audit entry
    When I upload CSV bills with default category "utilities":
      | name | category | amount_cents |
      | City Water | utilities | 3800 |
      | Rent | housing | 185000 |
    Then the response status is 200
    And the bill "City Water" shows status "due"
    And the bill "Rent" shows status "due"
    And audit trail contains action "bills.csv_import" by "ada@household.local" for "bills"

  @smoke
  Scenario: Malformed CSV row returns 422
    When I upload raw CSV "BrokenRowOnlyOneColumn\\n"
    Then the response status is 422
```

## Gotchas

- CSV uploads require valid `X-XSRF-TOKEN` and UTF-8 bytes; missing columns or non-positive amounts must return `422`.
"""

test "starter Executable Feature Maps pass all auth, bills, and csv scenarios in-memory"
  init_feat_world = fn()
    files = Files.in_memory(test_asset_map()).read_only
    sql = Sqlite.in_memory()
    rng = SecureRandom.seeded(4242)
    t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"
    clk = Clock.fixed(t0)
    env = Env.of(test_env_map())
    app = ApiTest.start(Main, sql, clk, files, env, rng)
    db = case sql.open("starter.sqlite")
      Ok(d): d
      Error(_): stop "open starter.sqlite"
    end
    sess = WebTest.start().with_header("Host", "localhost:8080")
    (
      FeatWorld(captured_cookie: None, grace_session: None, last_home: None),
      sess,
      db,
      clk,
      rng,
      env,
      app
    )
  end

  assert Feature.parse("specs/features/auth.feature.md", auth_feature_spec) is Ok(auth_doc)
  assert Feature.parse("specs/features/bills.feature.md", bills_feature_spec) is Ok(bills_doc)
  assert Feature.parse("specs/features/csv-import.feature.md", csv_feature_spec) is Ok(csv_doc)

  bindings = [
    Feature.StepBinding(
      kind: Some(Feature.Given),
      pattern: "seed profile \"{name}\"",
      handler: fn(w, sess, params, _tbl, db, clk, rng, env, _app)
        pname = params.get("name") or ""
        try Seed.run_profile(Routes.seed_profiles(), pname, db, rng, clk, env)
        Ok((w, sess))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Given),
      pattern: "signed in as \"{email}\"",
      handler: fn(w, _sess, params, _tbl, _db, _clk, _rng, _env, app)
        email = params.get("email") or ""
        do_login = fn(cur_app, em)
          s0 = WebTest.start().with_header("Host", "localhost:8080")
          (s1, res) = WebTest.post_form(
            s0,
            cur_app,
            "/login",
            [("email", em), ("password", "horse-staple-battery")]
          )
          _ = try WebTest.check_redirect(res, "/")
          Ok(s1)
        end
        authed = try do_login(app, email)
        grace_opt = if email == "ada@household.local"
          Some(try do_login(app, "grace@household.local"))
        else
          None
        end
        Ok((
          FeatWorld(
            captured_cookie: WebTest.cookie(authed, "arvo_session"),
            grace_session: grace_opt,
            last_home: w.last_home
          ),
          authed
        ))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.When),
      pattern: "I visit \"{path}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, app)
        path = params.get("path") or "/"
        (next_s, res) = WebTest.get(sess, app, path)
        next_home = case WebTest.check_inertia[Routes.HomeProps](res, "Home")
          Ok(hp): Some(hp)
          Error(_): w.last_home
        end
        Ok((
          FeatWorld(
            captured_cookie: w.captured_cookie,
            grace_session: w.grace_session,
            last_home: next_home
          ),
          next_s
        ))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.When),
      pattern: "I submit login form with email \"{email}\" and password \"{pw}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, app)
        email = params.get("email") or ""
        pw = params.get("pw") or ""
        (next_s, _res) = WebTest.post_form(
          sess,
          app,
          "/login",
          [("email", email), ("password", pw)]
        )
        Ok((w, next_s))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.When),
      pattern: "I follow the redirect",
      handler: fn(w, sess, _params, _tbl, _db, _clk, _rng, _env, app)
        (next_s, res) = WebTest.follow_redirect(sess, app)
        next_home = case WebTest.check_inertia[Routes.HomeProps](res, "Home")
          Ok(hp): Some(hp)
          Error(_): w.last_home
        end
        Ok((
          FeatWorld(
            captured_cookie: w.captured_cookie,
            grace_session: w.grace_session,
            last_home: next_home
          ),
          next_s
        ))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.When),
      pattern: "I sign out",
      handler: fn(w, sess, _params, _tbl, _db, _clk, _rng, _env, app)
        old_tok = WebTest.cookie(sess, "arvo_session")
        (next_s, _res) = WebTest.post_form(sess, app, "/logout", [])
        Ok((
          FeatWorld(
            captured_cookie: old_tok,
            grace_session: w.grace_session,
            last_home: w.last_home
          ),
          next_s
        ))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.When),
      pattern: "I replay the previous session on \"{path}\"",
      handler: fn(w, _sess, params, _tbl, _db, _clk, _rng, _env, app)
        path = params.get("path") or "/"
        tok = try w.captured_cookie.or_fail("no captured session cookie")
        stale_s = WebTest.start().with_header("Host", "localhost:8080").with_header(
          "Cookie",
          "arvo_session=#{tok}"
        )
        (next_s, _res) = WebTest.get(stale_s, app, path)
        Ok((w, next_s))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.When),
      pattern: "I submit new bill name \"{name}\" category \"{cat}\" amount_cents \"{amt}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, app)
        bname = params.get("name") or ""
        bcat = params.get("cat") or ""
        amt = params.get("amt") or "0"
        (next_s, _res) = WebTest.post_form(
          sess,
          app,
          "/bills",
          [("name", bname), ("category", bcat), ("amount_cents", amt)]
        )
        Ok((w, next_s))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.When),
      pattern: "actor \"{actor}\" marks bill {bid} in flight with expected version {ver}",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, app)
        actor_name = params.get("actor") or "ada"
        bid = try (params.get("bid") or "").to_int.or_fail("invalid bid")
        ver = try (params.get("ver") or "").to_int.or_fail("invalid ver")
        target_s = if actor_name == "grace"
          try w.grace_session.or_fail("no grace session")
        else
          sess
        end
        (after_s, res) = WebTest.post_json(
          target_s,
          app,
          "/bills/#{bid}/pay",
          Routes.PayInput(expected_version: ver, reason: None)
        )
        kept_s = if actor_name == "grace"
          WebTest.Session(client: sess.client, last_response: Some(res), history: sess.history)
        else
          after_s
        end
        next_grace = if actor_name == "grace": Some(after_s) else: w.grace_session
        Ok((
          FeatWorld(
            captured_cookie: w.captured_cookie,
            grace_session: next_grace,
            last_home: w.last_home
          ),
          kept_s
        ))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.When),
      pattern: "I upload CSV bills with default category \"{cat}\":",
      handler: fn(w, sess, params, table, _db, _clk, _rng, _env, app)
        dcat = params.get("cat") or "utilities"
        var lines = []
        for row in table
          lines = lines.append(row.join(","))
        end
        csv_bytes = "#{lines.join("\n")}\n".bytes
        (next_s, _res) = WebTest.post_multipart(
          sess,
          app,
          "/imports/csv",
          [("default_category", dcat)],
          [
            WebTest.TestFile(
              field_name: "statement",
              filename: "statement.csv",
              content_type: "text/csv",
              data: csv_bytes
            )
          ]
        )
        Ok((w, next_s))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.When),
      pattern: "I upload raw CSV \"{raw}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, app)
        raw = (params.get("raw") or "").replace("\\n", "\n")
        (next_s, _res) = WebTest.post_multipart(
          sess,
          app,
          "/imports/csv",
          [("default_category", "utilities")],
          [
            WebTest.TestFile(
              field_name: "statement",
              filename: "bad.csv",
              content_type: "text/csv",
              data: raw.bytes
            )
          ]
        )
        Ok((w, next_s))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Then),
      pattern: "the response status is {code}",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, _app)
        code = try (params.get("code") or "").to_int.or_fail("invalid status code")
        res = try sess.last_response.or_fail("no response recorded")
        _ = try WebTest.check_status(res, code)
        Ok((w, sess))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Then),
      pattern: "the response redirects to \"{loc}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, _app)
        loc = params.get("loc") or ""
        res = try sess.last_response.or_fail("no response recorded")
        _ = try WebTest.check_redirect(res, loc)
        Ok((w, sess))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Then),
      pattern: "the Inertia component is \"{comp}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, _app)
        comp = params.get("comp") or ""
        res = try sess.last_response.or_fail("no response recorded")
        page = try WebTest.inertia_page(res)
        if page.component != comp
          return Error("expected component '#{comp}', got '#{page.component}'")
        end
        Ok((w, sess))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Then),
      pattern: "the flash notice is \"{msg}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, _app)
        msg = params.get("msg") or ""
        res = try sess.last_response.or_fail("no response recorded")
        try WebTest.check_flash_notice(res, msg)
        Ok((w, sess))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Then),
      pattern: "the page shows heading \"{heading}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, _app)
        heading = params.get("heading") or ""
        res = try sess.last_response.or_fail("no response recorded")
        sp = try WebTest.check_inertia[Routes.SharedProps](res, "Home")
        case sp.auth
          Some(u):
            if u.display_name != heading
              return Error("expected heading '#{heading}', got '#{u.display_name}'")
            end
          None: return Error("expected signed-in auth display_name")
        end
        Ok((w, sess))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Then),
      pattern: "validation error for \"{field}\" contains \"{substr}\"",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, _app)
        field = params.get("field") or ""
        substr = params.get("substr") or ""
        res = try sess.last_response.or_fail("no response recorded")
        try WebTest.check_validation_error(res, field, substr)
        Ok((w, sess))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Then),
      pattern: "the bill \"{name}\" shows status \"{st}\"",
      handler: fn(w, sess, params, _tbl, db, _clk, _rng, _env, _app)
        bname = params.get("name") or ""
        st = params.get("st") or ""
        rows = try db.query("SELECT status FROM bills WHERE name = ?", [Sqlite.String(bname)])
          .map_error(fn(e) "#{e}" end)
        case rows.rows.first
          Some([Sqlite.String(got)]):
            if got != st
              return Error("bill '#{bname}' expected status '#{st}', got '#{got}'")
            end
            Ok((w, sess))
          None | Some(_): Error("bill '#{bname}' not found")
        end
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Then),
      pattern: "total due cents is {cents}",
      handler: fn(w, sess, params, _tbl, _db, _clk, _rng, _env, _app)
        cents = try (params.get("cents") or "").to_int.or_fail("invalid cents")
        hp = try w.last_home.or_fail("expected HomeProps")
        if hp.total_due_cents != cents
          return Error("expected total_due_cents #{cents}, got #{hp.total_due_cents}")
        end
        Ok((w, sess))
      end
    ),
    Feature.StepBinding(
      kind: Some(Feature.Then),
      pattern: "audit trail contains action \"{act}\" by \"{actor}\" for \"{tbl}\"",
      handler: fn(w, sess, params, _tbl, db, _clk, _rng, _env, _app)
        act = params.get("act") or ""
        actor_email = params.get("actor") or ""
        tbl = params.get("tbl") or ""
        rows = try db.query(
          "SELECT id FROM arvo_events WHERE action = ? AND actor = ? AND entity_table = ? LIMIT 1",
          [Sqlite.String(act), Sqlite.String(actor_email), Sqlite.String(tbl)]
        ).map_error(fn(e) "#{e}" end)
        if rows.rows.empty?
          Error("missing audit event action=#{act} actor=#{actor_email} table=#{tbl}")
        else
          Ok((w, sess))
        end
      end
    )
  ]
  docs = [auth_doc, bills_doc, csv_doc]
  assert Feature.browser_manifest(docs).size == 3

  for doc in docs
    rep = Feature.run_feature(doc, Some("@smoke"), bindings, init_feat_world)
    assert rep.total >= 2
    if rep.failed != 0 or rep.passed != rep.total
      assert Feature.format_report(rep) == "OK"
    end
  end
end

test "starter covers route boundaries, config, audit limit, and CSV edge cases"
  t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"

  # 1. Secure cookies flag & VITE_DEV_URL config branches
  sec_env = Env.of(
    test_env_map().set("ARVO_INSECURE_COOKIES", "0").set("VITE_DEV_URL", "http://127.0.0.1:5173")
  )
  app_sec = ApiTest.start(
    Main,
    Sqlite.in_memory(),
    Clock.fixed(t0),
    Files.in_memory(test_asset_map()).read_only,
    sec_env,
    SecureRandom.seeded(101)
  )
  (sl0, sec_login_page) = WebTest.get(
    WebTest.start().with_header("Host", "localhost:8080"),
    app_sec,
    "/login"
  )
  _ = WebTest.expect_status(sec_login_page, 200)
  assert sec_login_page.text.contains?("http://127.0.0.1:5173/src/main.tsx")
  (_sl1, sec_post) = WebTest.post_form(
    sl0,
    app_sec,
    "/login",
    [("email", "ada@household.local"), ("password", "horse-staple-battery")]
  )
  sec_cookies = sec_post.headers.filter(fn(h) h.0.ascii_lowercase == "set-cookie" end).map(
    fn(h) h.1 end
  ).join(";")
  assert sec_cookies.contains?("; Secure")

  blank_dev_env = Env.of(test_env_map().set("VITE_DEV_URL", "   "))
  app_blank = ApiTest.start(
    Main,
    Sqlite.in_memory(),
    Clock.fixed(t0),
    Files.in_memory(test_asset_map()).read_only,
    blank_dev_env,
    SecureRandom.seeded(102)
  )
  (_sb, blank_res) = WebTest.get(
    WebTest.start().with_header("Host", "localhost:8080"),
    app_blank,
    "/login"
  )
  assert blank_res.text.contains?("/assets/main-a1b2c3d4.js")

  # 2. Main app for create_bill boundaries, home LIMIT 20, and import_csv edge cases
  sql = Sqlite.in_memory()
  app = ApiTest.start(
    Main,
    sql,
    Clock.fixed(t0),
    Files.in_memory(test_asset_map()).read_only,
    Env.of(test_env_map()),
    SecureRandom.seeded(202)
  )
  assert sql.open("starter.sqlite") is Ok(db)
  (s_auth, login_redir) = WebTest.post_form(
    WebTest.start().with_header("Host", "localhost:8080"),
    app,
    "/login",
    [("email", "ada@household.local"), ("password", "horse-staple-battery")]
  )
  _ = WebTest.expect_redirect(login_redir, "/")
  s0 = WebTest.with_inertia(s_auth, Inertia.version_from_manifest(test_manifest_json().bytes))

  # 2a. Non-int amount -> 0 -> fails > 0 (kills `or 0` -> `or 1`)
  (s1, r_bad_int) = WebTest.post_form(
    s0,
    app,
    "/bills",
    [("name", "Water"), ("category", "utilities"), ("amount_cents", "abc")]
  )
  _ = WebTest.expect_redirect(r_bad_int, "/")
  (s2, r_bad_int_f) = WebTest.follow_redirect(s1, app)
  WebTest.expect_validation_error(r_bad_int_f, "amount_cents", "greater than 0")

  # 2b. Name length boundaries 1 (fail), 2 (pass), 80 (pass), 81 (fail)
  (s3, _) = WebTest.post_form(
    s2,
    app,
    "/bills",
    [("name", "A"), ("category", "utilities"), ("amount_cents", "100")]
  )
  (s4, r_len1) = WebTest.follow_redirect(s3, app)
  WebTest.expect_validation_error(r_len1, "name", "at least 2")

  (s5, _) = WebTest.post_form(
    s4,
    app,
    "/bills",
    [("name", "AB"), ("category", "utilities"), ("amount_cents", "100")]
  )
  (s6, r_len2) = WebTest.follow_redirect(s5, app)
  WebTest.expect_flash_notice(r_len2, "Bill added")

  var n80 = ""
  var k = 0
  while k < 80
    n80 = "#{n80}x"
    k += 1
  end
  n81 = "#{n80}y"
  (s7, _) = WebTest.post_form(
    s6,
    app,
    "/bills",
    [("name", n80), ("category", "utilities"), ("amount_cents", "100")]
  )
  (s8, r_len80) = WebTest.follow_redirect(s7, app)
  WebTest.expect_flash_notice(r_len80, "Bill added")

  (s9, _) = WebTest.post_form(
    s8,
    app,
    "/bills",
    [("name", n81), ("category", "utilities"), ("amount_cents", "100")]
  )
  (s10, r_len81) = WebTest.follow_redirect(s9, app)
  WebTest.expect_validation_error(r_len81, "name", "at most 80")

  # 2c. CSV edge cases: headerless row, blank line + empty category fallback, line-number errors, and 65537-byte limit
  (s11, csv_hdr_blank) = WebTest.post_multipart(
    s10,
    app,
    "/imports/csv",
    [("default_category", "card")],
    [
      WebTest.TestFile(
        field_name: "statement",
        filename: "mix.csv",
        content_type: "text/csv",
        data: "name,category,amount_cents\nName,housing,1\nWater,,4500\n\n".bytes
      )
    ]
  )
  _ = WebTest.expect_status(csv_hdr_blank, 200)
  assert Json.decode_strict[Map(Text, Int)](csv_hdr_blank.text) == Ok({"imported": 2})
  assert db.query("SELECT category FROM bills WHERE name = 'Water'", []) is Ok(cat_q)
  assert cat_q.rows.first == Some([Sqlite.String("card")])

  (s12, csv_no_hdr) = WebTest.post_multipart(
    s11,
    app,
    "/imports/csv",
    [],
    [
      WebTest.TestFile(
        field_name: "statement",
        filename: "direct.csv",
        content_type: "text/csv",
        data: "DirectRow,card,500\n".bytes
      )
    ]
  )
  _ = WebTest.expect_status(csv_no_hdr, 200)
  assert Json.decode_strict[Map(Text, Int)](csv_no_hdr.text) == Ok({"imported": 1})

  var csv_s = s12
  for (bad_csv, expect_sub) in [
    ("name,category,amount_cents\nBadCols,two\n", "line 2"),
    ("name,category,amount_cents\nBadInt,utilities,nope\n", "line 2"),
    ("name,category,amount_cents\n,utilities,500\n", "line 2"),
    ("name,category,amount_cents\nZeroBill,utilities,0\n", "line 2")
  ]
    (next_s, bad_res) = WebTest.post_multipart(
      csv_s,
      app,
      "/imports/csv",
      [],
      [
        WebTest.TestFile(
          field_name: "statement",
          filename: "err.csv",
          content_type: "text/csv",
          data: bad_csv.bytes
        )
      ]
    )
    csv_s = next_s
    _ = WebTest.expect_status(bad_res, 422)
    assert bad_res.text.contains?(expect_sub)
  end

  # Exact 65537-byte valid multipart body fails 65536 cap with 422
  mp_head = "--arvoBig\r\nContent-Disposition: form-data; name=\"statement\"; filename=\"big.csv\"\r\nContent-Type: text/csv\r\n\r\nname,category,amount_cents\nBigOk,utilities,100\n\r\n--arvoBig\r\nContent-Disposition: form-data; name=\"pad\"\r\n\r\n"
  mp_tail = "\r\n--arvoBig--\r\n"
  need_pad = 65537 - mp_head.byte_count - mp_tail.byte_count
  var pad_chunks = []
  var pi = 0
  while pi < need_pad
    pad_chunks = pad_chunks.append("p")
    pi += 1
  end
  raw_mp = "#{mp_head}#{pad_chunks.join("")}#{mp_tail}".bytes
  assert raw_mp.size == 65537
  (s13, res_too_big) = WebTest.send(
    csv_s,
    app,
    Api.post("/imports/csv").with_bytes(raw_mp, "multipart/form-data; boundary=arvoBig")
  )
  _ = WebTest.expect_status(res_too_big, 422)

  # 2d. Routes.home audit LIMIT 20 (kills 20 -> 21)
  var ai = 0
  while ai < 21
    _ev_ins = db.run(
      "INSERT INTO arvo_events (id, actor, action, entity_table, entity_id, created_at) VALUES (?, 'ada@household.local', 'limit.check', 'bills', '1', ?)",
      [Sqlite.String("evt_lim_#{ai}"), Sqlite.String(t0.to_text)]
    )
    ai += 1
  end
  (_s_lim, lim_res) = WebTest.get(s13, app, "/")
  lim_home = WebTest.expect_inertia[Routes.HomeProps](lim_res, "Home")
  assert lim_home.audit_feed.size == 20
end
