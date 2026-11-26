## Arvo + MoDB + Inertia v2 full-stack starter server demonstrating zero-SQLite persistence,
## `ReadFiles`-only `GET` handlers, `Arvo.Modb.Sessions` (Layer 2), `Modb.Ledger` hash-chained
## audit trail & invariants (Layer 3), and transactional `Arvo.Modb.Jobs` drained by `mo serve`.
module Main
use Api
use Arvo.Inertia
use Arvo.Modb.Jobs
use Arvo.WebTest
use Json
use Modb.Ledger
use Routes

api
  port 8080
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

  job "arvo.jobs.drain" Routes.drain_jobs every 10.seconds

  status Routes.Unauthenticated = 401
  status Routes.Forbidden = 403
  status Routes.BillNotFound(_) = 404
  status Routes.VersionConflict(_) = 409
  status Routes.BadUpload(_) = 422
  status Routes.ServerFailed(_) = 500
end

fn must_page(res: Api.Response) : WebTest.InertiaPage
  case WebTest.inertia_page(res)
    Ok(p): p
    Error(_): stop "expected valid Inertia page"
  end
end

test "end-to-end Arvo + MoDB + Inertia v2 flow: ReadFiles auth/GET, CSRF, flash, CSV outbox job, Ledger verify, and logout"
  manifest_json = """
    {
      "src/main.tsx": {
        "file": "assets/main-a1b2c3d4.js",
        "css": ["assets/main-f9e8d7c6.css"],
        "isEntry": true
      }
    }
    """
  files = Files.in_memory({
    "public/manifest.json": manifest_json,
    "public/assets/main-a1b2c3d4.js": "console.log('arvo modb starter');",
    "public/assets/main-f9e8d7c6.css": "body{margin:0}"
  })
  expected_version = Inertia.version_from_manifest(manifest_json.bytes)

  rng = SecureRandom.seeded(2026)
  t0 = Time.parse("2026-11-22T09:00:00Z") or stop "t0"
  clock = Clock.fixed(t0)
  env = Env.of({
    "ARVO_SECRET_KEY": "1111111111111111111111111111111122222222222222222222222222222222",
    "ARVO_ALLOWLIST": "ada@household.local,grace@household.local",
    "ARVO_SEED_PASSWORD": "horse-staple-battery",
    "ARVO_INSECURE_COOKIES": "1"
  })

  # 1. Static asset serving (200 + immutable Cache-Control + ETag + 304 Not Modified)
  asset_res = ApiTest.send(Main, Api.get("/assets/main-a1b2c3d4.js"), files, clock, env, rng)
  assert asset_res.status == 200
  assert asset_res.header("Content-Type") == Some("text/javascript; charset=utf-8")
  assert asset_res.header("Cache-Control") == Some("public, max-age=31536000, immutable")
  etag = asset_res.header("ETag") or ""
  assert not etag.empty?

  not_mod = ApiTest.send(
    Main,
    Api.get("/assets/main-a1b2c3d4.js").with_header("If-None-Match", etag),
    files,
    clock,
    env,
    rng
  )
  assert not_mod.status == 304 and not_mod.body.size == 0

  # 2. Unauthenticated redirect on `/` vs optional auth on `/login` vs 401 on API routes
  #    Notice neither `sessions.modb` nor `starter.modb` exists yet — ReadFiles paths fail closed cleanly.
  guest = WebTest.new().with_header("Host", "localhost:8080")
  home_guest = ApiTest.send(Main, WebTest.prepare(guest, Api.get("/")), files, clock, env, rng)
  assert home_guest.status == 303
  assert WebTest.redirect_location(home_guest) == Some("/login")
  assert not files.exists?(Routes.sessions_db_path)
  assert not files.exists?(Routes.ledger_db_path)

  unauth_post = ApiTest.send(
    Main,
    WebTest.prepare(
      guest,
      Api.post("/bills/1/pay").with_json(Routes.PayInput(expected_version: 1, reason: None))
    ),
    files,
    clock,
    env,
    rng
  )
  assert unauth_post.status == 401

  login_html_res = ApiTest.send(
    Main,
    WebTest.prepare(guest, Api.get("/login")),
    files,
    clock,
    env,
    rng
  )
  assert login_html_res.status == 200
  assert login_html_res.text.contains?("/assets/main-a1b2c3d4.js")
  assert login_html_res.text.contains?("/assets/main-f9e8d7c6.css")
  login_page = must_page(login_html_res)
  assert login_page.component == "Login"
  assert login_page.version == expected_version
  assert (login_page.props.get("auth") or Json.String("bad")) == Json.Null

  # 3. Login -> emits BOTH `arvo_session` (HttpOnly) and `XSRF-TOKEN` Set-Cookie headers + 303 redirect
  login_form = Api.post("/login").with_bytes(
    "email=Ada%40Household.Local&password=horse-staple-battery".bytes,
    "application/x-www-form-urlencoded"
  )
  login_res = ApiTest.send(Main, WebTest.prepare(guest, login_form), files, clock, env, rng)
  assert login_res.status == 303
  assert WebTest.redirect_location(login_res) == Some("/")
  set_cookies = login_res.headers_named("Set-Cookie")
  assert set_cookies.any?(fn(c) c.starts_with?("arvo_session=") and c.contains?("HttpOnly") end)
  assert set_cookies.any?(fn(c) c.starts_with?("XSRF-TOKEN=") and not c.contains?("HttpOnly") end)

  authed = WebTest.absorb(guest, login_res)
  assert WebTest.cookie(authed, "arvo_session") != None
  assert WebTest.cookie(authed, "XSRF-TOKEN") != None

  # Initial authenticated HTML load (uses strictly ReadFiles!): proves data-page escaping and clears flash
  home_html_res = ApiTest.send(Main, WebTest.prepare(authed, Api.get("/")), files, clock, env, rng)
  assert home_html_res.status == 200
  assert home_html_res.text.contains?("&lt;Utility&gt;")
  assert not home_html_res.text.contains?("<Utility>")
  home_initial = must_page(home_html_res)
  assert home_initial.component == "Home"
  assert Json.Object(home_initial.props).text_at("auth.display_name") ==
    Some("Ada & Household <Team>")
  assert Json.Object(home_initial.props).text_at("flash.notice") == Some("Signed in")
  authed_clean = WebTest.absorb(authed, home_html_res)
  assert WebTest.cookie(authed_clean, "arvo_flash") == None

  # Authenticated visit to `/login` redirects to `/`
  revisit_login = ApiTest.send(
    Main,
    WebTest.prepare(authed_clean, Api.get("/login")),
    files,
    clock,
    env,
    rng
  )
  assert revisit_login.status == 303 and WebTest.redirect_location(revisit_login) == Some("/")

  # 4. CSRF enforcement: 403 without token, 303/200 with automatic X-XSRF-TOKEN
  csrf_missing_res = ApiTest.send(
    Main,
    WebTest.prepare_without_csrf(
      authed_clean,
      Api.post("/bills").with_bytes(
        "name=Water&category=utilities&amount_cents=4200".bytes,
        "application/x-www-form-urlencoded"
      )
    ),
    files,
    clock,
    env,
    rng
  )
  assert csrf_missing_res.status == 403

  # 5. Changeset validation error -> flash carried across 303 redirect -> cleared on subsequent read
  bad_bill_req = WebTest.prepare(
    authed_clean,
    Api.post("/bills").with_header("Referer", "http://localhost:8080/?status=due").with_bytes(
      "name=&category=invalid_cat&amount_cents=0".bytes,
      "application/x-www-form-urlencoded"
    )
  )
  bad_bill_res = ApiTest.send(Main, bad_bill_req, files, clock, env, rng)
  assert bad_bill_res.status == 303
  assert WebTest.redirect_location(bad_bill_res) == Some("/?status=due")
  with_err_flash = WebTest.absorb(authed_clean, bad_bill_res)
  assert WebTest.cookie(with_err_flash, "arvo_flash") != None

  xhr_client = WebTest.with_inertia(with_err_flash, expected_version)
  err_page_res = ApiTest.send(
    Main,
    WebTest.prepare(xhr_client, Api.get("/?status=due")),
    files,
    clock,
    env,
    rng
  )
  assert err_page_res.status == 200
  assert err_page_res.header("X-Inertia") == Some("true")
  err_page = must_page(err_page_res)
  assert err_page.url == "/?status=due"
  err_doc = Json.Object(err_page.props)
  assert err_doc.text_at("errors.name") == Some("can't be blank")
  assert err_doc.text_at("errors.category") != None
  assert err_doc.text_at("errors.amount_cents") == Some("must be greater than 0")

  after_flash_cleared = WebTest.absorb(xhr_client, err_page_res)
  assert WebTest.cookie(after_flash_cleared, "arvo_flash") == None
  second_read_res = ApiTest.send(
    Main,
    WebTest.prepare(after_flash_cleared, Api.get("/")),
    files,
    clock,
    env,
    rng
  )
  second_page = must_page(second_read_res)
  assert second_page.props.get("errors") == Some(Json.Object({}))

  # Valid bill creation succeeds with CSRF token
  good_bill_res = ApiTest.send(
    Main,
    WebTest.prepare(
      after_flash_cleared,
      Api.post("/bills").with_bytes(
        "name=Fiber+Internet&category=utilities&amount_cents=7500".bytes,
        "application/x-www-form-urlencoded"
      )
    ),
    files,
    clock,
    env,
    rng
  )
  assert good_bill_res.status == 303 and WebTest.redirect_location(good_bill_res) == Some("/")
  c_after_create = WebTest.absorb(after_flash_cleared, good_bill_res)

  # 6. Inertia XHR navigation, partial reload (`X-Inertia-Partial-Data`), and version mismatch (`409`)
  partial_req = WebTest.prepare(
    c_after_create,
    Api.get("/").with_header("X-Inertia-Partial-Component", "Home").with_header(
      "X-Inertia-Partial-Data",
      "total_due_cents"
    )
  )
  partial_res = ApiTest.send(Main, partial_req, files, clock, env, rng)
  assert partial_res.status == 200
  partial_page = must_page(partial_res)
  assert Json.Object(partial_page.props).int_at("total_due_cents") == Some(22000)
  assert partial_page.props.get("errors") == Some(Json.Object({}))
  assert partial_page.props.get("audit_feed") == None
  assert partial_page.props.get("auth") == None
  c_ready = WebTest.absorb(c_after_create, partial_res)

  stale_client = WebTest.with_inertia(c_ready, "outdated-manifest-sha")
  mismatch_res = ApiTest.send(
    Main,
    WebTest.prepare(stale_client, Api.get("/?status=due")),
    files,
    clock,
    env,
    rng
  )
  assert mismatch_res.status == 409
  assert mismatch_res.header("X-Inertia-Location") == Some("/?status=due")

  # 7. Multipart CSV upload + transactional MoDB job enqueue + `ApiTest.run_job` drain + optimistic lock
  csv_payload = "name,category,amount_cents\nCity Water,utilities,3800\nRent,housing,185000\n"
  mp_body = Bytes.join([
    "--arvoBoundary\r\nContent-Disposition: form-data; name=\"default_category\"\r\n\r\nutilities\r\n"
      .bytes,
    "--arvoBoundary\r\nContent-Disposition: form-data; name=\"statement\"; filename=\"bills.csv\"\r\nContent-Type: text/csv\r\n\r\n"
      .bytes,
    csv_payload.bytes,
    "\r\n--arvoBoundary--\r\n".bytes
  ])
  upload_res = ApiTest.send(
    Main,
    WebTest.prepare(
      c_ready,
      Api.post("/imports/csv").with_bytes(mp_body, "multipart/form-data; boundary=arvoBoundary")
    ),
    files,
    clock,
    env,
    rng
  )
  assert upload_res.status == 200
  assert Json.decode_strict[Map(Text, Int)](upload_res.text) == Ok({"imported": 2})

  # Verify job was enqueued transactionally and drain via `ApiTest.run_job`
  queued_jobs = case Jobs.list_recent(files.read_only, Routes.ledger_db_path, 10)
    Ok(js): js
    Error(_): stop "list_recent failed"
  end
  assert queued_jobs.size == 1
  assert (queued_jobs.get(0) or stop "job 0").state == "pending"
  assert (queued_jobs.get(0) or stop "job 0").job_name == "import.notify"

  assert ApiTest.run_job(Main, "arvo.jobs.drain", Json.Null, files, clock, env, rng) == Ok(Unit)
  drained_jobs = case Jobs.list_recent(files.read_only, Routes.ledger_db_path, 10)
    Ok(js): js
    Error(_): stop "list_recent failed"
  end
  assert drained_jobs.size == 1
  assert (drained_jobs.get(0) or stop "job 0").state == "completed"

  pay_ok_res = ApiTest.send(
    Main,
    WebTest.prepare(
      c_ready,
      Api.post("/bills/1/pay").with_json(
        Routes.PayInput(expected_version: 1, reason: Some("Paid from checking"))
      )
    ),
    files,
    clock,
    env,
    rng
  )
  assert pay_ok_res.status == 200
  paid_bill = case Json.decode_strict[Routes.Bill](pay_ok_res.text)
    Ok(b): b
    Error(_): stop "expected decoded Bill"
  end
  assert paid_bill.status == "in_flight" and paid_bill.version == 2

  stale_pay_res = ApiTest.send(
    Main,
    WebTest.prepare(
      c_ready,
      Api.post("/bills/1/pay").with_json(Routes.PayInput(expected_version: 1, reason: None))
    ),
    files,
    clock,
    env,
    rng
  )
  assert stale_pay_res.status == 409

  feed_res = ApiTest.send(Main, WebTest.prepare(c_ready, Api.get("/")), files, clock, env, rng)
  feed_page = must_page(feed_res)
  feed_items = Json.Object(feed_page.props).list_at("audit_feed") or []
  # migrate(v1) + seed.bootstrap + auth.login + bill.create + bills.csv_import + bill.mark_in_flight
  assert feed_items.size == 6

  # Verify full cryptographic MoDB storage + hash-chained Ledger + invariants
  ledger_verify = Ledger.read_locked(
    files.read_only,
    Routes.ledger_db_path,
    Routes.starter_schema(),
    fn(e) e end,
    fn(db) Ledger.verify_all(db) end
  )
  case ledger_verify
    Ok(rep):
      assert rep.audit.entry_count == 6
      assert rep.invariants_checked == 1
    Error(_): stop "Ledger.verify_all failed"
  end

  # 8. Logout -> revokes MoDB session row AND clears cookies -> subsequent requests unauthenticated
  logout_res = ApiTest.send(
    Main,
    WebTest.prepare(c_ready, Api.post("/logout")),
    files,
    clock,
    env,
    rng
  )
  assert logout_res.status == 303
  assert WebTest.redirect_location(logout_res) == Some("/login")

  replayed_res = ApiTest.send(Main, WebTest.prepare(c_ready, Api.get("/")), files, clock, env, rng)
  assert replayed_res.status == 303 and WebTest.redirect_location(replayed_res) == Some("/login")

  replayed_api = ApiTest.send(
    Main,
    WebTest.prepare(
      c_ready,
      Api.post("/bills/1/pay").with_json(Routes.PayInput(expected_version: 2, reason: None))
    ),
    files,
    clock,
    env,
    rng
  )
  assert replayed_api.status == 401

  logged_out = WebTest.absorb(c_ready, logout_res)
  assert WebTest.cookie(logged_out, "arvo_session") == None
  assert WebTest.cookie(logged_out, "XSRF-TOKEN") == None
end
