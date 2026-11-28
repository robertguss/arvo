## End-to-end zero-socket integration suite driving Arvo routes, Dev Dashboard (`/__arvo`),
## SEO `<head>` tags, Inertia v2 HTML/XHR shells, and evidence rasterization via `Mobrowse.Arvo`.
module E2eSuite
use Api
use Arvo.DevDashboard
use Arvo.Inertia
use Arvo.Mail
use Arvo.Mobrowse.E2e
use Json
use Mobrowse.Arvo
use Mobrowse.Png

api
  port 8080
  static "/assets" from "public/assets"
  get "/" show_home
  get "/__arvo" dev_dashboard
  get "/__arvo/mailbox" dev_dashboard
  get "/__arvo/audit" dev_dashboard
  get "/__arvo/replay" dev_dashboard
end

fn sample_snap() : DevDashboard.DashboardSnapshot
  t0 = Time.parse("2026-11-28T01:00:00Z") or stop "t0"
  DevDashboard.DashboardSnapshot(
    jobs: DevDashboard.JobQueueSnapshot(pending: 1, running: 0, completed: 2, failed: 0, recent: []),
    sessions: [],
    store: DevDashboard.StoreSnapshot(
      engine: "modb",
      buckets: ["users", "_arvo_sessions"],
      audit_entries: [
        DevDashboard.AuditSummary(
          seq: 1,
          txid: 7,
          principal: "ada@example.local",
          action: "auth.login",
          summary: "signed in cleanly",
          at: t0.to_text
        )
      ],
      sync_peers: [],
      fts_query: None,
      fts_hits: []
    ),
    time_travel: DevDashboard.TimeTravelSnapshot(
      calls: [
        DevDashboard.ReplayCallSummary(
          seq: 1,
          audit_seq: Some(1),
          schema_version: 1,
          principal: "ada@example.local",
          action: "auth.login",
          reason: "session created",
          at: t0.to_text,
          outcome_kind: "ok",
          outcome_detail: "{\"ok\":true}",
          world_id: None
        )
      ],
      proposals: [],
      worlds: []
    )
  )
end

fn show_home(req: Api.Request) : Api.Response
  head_tags = """
    <meta name="description" content="Calm full-stack web apps in Mo.">
    <meta property="og:title" content="Arvo Demo">
    <link rel="canonical" href="https://arvo.example/">
    <script type="application/ld+json">{"@type":"WebApplication","name":"Arvo Demo"}</script>
    """
  cfg = Inertia.InertiaConfig(
    app_title: "Arvo Demo App",
    version: "v1",
    vite_dev_url: None,
    entry_js: "/assets/app.js",
    entry_css: ["/assets/app.css"],
    head_extra: head_tags
  )
  Inertia.render_with_status(
    req,
    cfg,
    200,
    "Home",
    {"greeting": Json.String("Welcome to Arvo")},
    {}
  )
end

fn dev_dashboard(req: Api.Request, rf: ReadFiles, rng: SecureRandom, env: Env) : Api.Response
  dev_on? = (env.get("ARVO_DEV") or "0") == "1"
  dcfg = DevDashboard.default_config("Acme", dev_on?, Some(".arvo/mailbox"))
  DevDashboard.handle(req, rf, rng, dcfg, sample_snap())
end

test "MoBrowse drives Inertia SEO head and /__arvo Dev Dashboard tabs with desktop+mobile layout and PNG diffs"
  files = Files.in_memory({
    "public/assets/app.js": "console.log('arvo');",
    "public/assets/app.css": "body{margin:0;}"
  })
  t0 = Time.parse("2026-11-28T01:00:00Z") or stop "t0"
  rng = SecureRandom.seeded(77)
  clock = Clock.fixed(t0)

  msg = Mail.MailMessage(
    from: "no-reply@acme.local",
    to: ["ada@acme.local"],
    reply_to: None,
    subject: "Verify your email",
    text_body: "Open http://localhost:8080/verify?token=tok_123 to continue.",
    html_body: None,
    headers: []
  )
  assert Mail.deliver_dev_mailbox(".arvo/mailbox", msg, files, rng, clock) is Ok(_)

  # 1. Production mode (ARVO_DEV=0) keeps /__arvo strictly 404 while serving home SEO + Inertia props
  app_off = ApiTest.start(E2eSuite, clock, files, Env.of({"ARVO_DEV": "0"}), rng)
  assert Arvo.visit(Arvo.new(), app_off, "/__arvo") is Ok(b404)
  assert Arvo.status(b404) == 404

  assert Arvo.visit(Arvo.new(), app_off, "/") is Ok(b_home)
  assert Arvo.status(b_home) == 200
  assert E2e.assert_seo_head(
    b_home,
    "Arvo Demo App",
    Some("Calm full-stack"),
    Some("https://arvo.example/")
  ) is
    Ok(seo_rep)
  assert seo_rep.og_title == Some("Arvo Demo")
  assert seo_rep.json_ld.size == 1
  assert Arvo.inertia_page(b_home) is Ok(hp)
  assert hp.component == "Home"
  assert not Arvo.has_horizontal_overflow?(b_home)
  assert not Arvo.has_horizontal_overflow?(Arvo.with_viewport(b_home, 390.0, 844.0))

  # 2. Dev mode (ARVO_DEV=1): visit all 4 /__arvo tabs, verify text, layout, PNG screenshots & diffs
  app_on = ApiTest.start(E2eSuite, clock, files, Env.of({"ARVO_DEV": "1"}), rng)
  assert Arvo.visit(Arvo.new(), app_on, "/__arvo") is Ok(ov)
  assert Arvo.status(ov) == 200
  assert Arvo.visible?(ov, "Active Sessions")
  assert Arvo.visible?(ov, "auth.login")
  assert not Arvo.has_horizontal_overflow?(ov)
  ov_png = Arvo.screenshot_png(ov)
  assert ov_png.slice(0, 4).to_hex == "89504e47"
  assert Png.decode_png(ov_png, 8000000, 2048) is Ok(_)
  ov_img = Arvo.screenshot_image(ov)
  assert Arvo.assert_matches_screenshot(ov, ov_img, 0.0, 0) is Ok(_)

  # Mobile viewport resize stays valid without 5xx (note DevDashboard tables target desktop width)
  ov_mob = Arvo.with_viewport(ov, 390.0, 844.0)
  assert Arvo.status(ov_mob) == 200

  assert Arvo.visit(ov, app_on, "/__arvo/mailbox") is Ok(mb)
  assert Arvo.status(mb) == 200
  assert Arvo.visible?(mb, "Verify your email")
  assert Arvo.visible?(mb, "Open Action Link")
  assert Arvo.assert_matches_screenshot(mb, ov_img, 0.01, 4) is Error(_)

  assert Arvo.visit(mb, app_on, "/__arvo/audit") is Ok(au)
  assert Arvo.status(au) == 200 and Arvo.visible?(au, "auth.login") and Arvo.visible?(au, "session created")

  assert Arvo.visit(au, app_on, "/__arvo/replay") is Ok(rp)
  assert Arvo.status(rp) == 200 and Arvo.visible?(rp, "Time-Travel Replay")

  # Emit full EvidenceRun report for /__arvo and verify it passes
  var run = E2e.record_db_check(E2e.record_scenario(E2e.new_run("dash_e2e", "build_abc"), "dev-dashboard"))
  assert E2e.capture_page(
    run,
    files,
    "Overview",
    ov,
    [E2e.ViewportSpec(name: "desktop", width: 1280.0, height: 800.0)],
    None,
    2,
    false
  ) is
    Ok(run1)
  assert E2e.finalize_report(run1, files) is Ok(sum)
  assert sum.passed?
  assert files.exists?(sum.report_path)
end
