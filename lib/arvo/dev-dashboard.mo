## Self-contained HTML/JSON local developer & operator dashboard (`/__arvo`) providing
## the Dev Mailbox (captured emails + one-click magic/verification URLs), job queue
## stats, active sessions, audit/replay timeline, and speculative worlds. Always returns `404` when disabled.
module Arvo.DevDashboard
expose DashboardConfig(..),
JobSummary(..),
JobQueueSnapshot(..),
SessionSummary(..),
AuditSummary(..),
SyncPeerSummary(..),
SearchPreviewHit(..),
StoreSnapshot(..),
ReplayCallSummary(..),
RowDiffSummary(..),
ReplayProposalSummary(..),
WorldSummary(..),
TimeTravelSnapshot(..),
DashboardSnapshot(..),
default_config,
empty_time_travel,
empty_snapshot,
handle,
render_overview_html,
render_mailbox_html,
render_audit_html,
render_replay_html
use Api
use Arvo.Inertia
use Arvo.Mail
use Arvo.Security
use Json

## Configuration for `DevDashboard.handle` (`enabled?: false` strictly fails closed with `404`).
struct DashboardConfig
  enabled?: Bool
  base_path: Text
  app_name: Text
  mailbox_dir: Option(Text)
end

## Storage-agnostic job summary displayed on `/__arvo`.
struct JobSummary
  id: Text
  queue: Text
  job_name: Text
  state: Text
  attempts: Int
  max_attempts: Int
  run_at: Text
  last_error: Option(Text)
end

## Aggregate job counts and recent items.
struct JobQueueSnapshot
  pending: Int
  running: Int
  completed: Int
  failed: Int
  recent: List(JobSummary)
end

## Active session summary (redacted; never carries raw tokens or CSRF values).
struct SessionSummary
  id: Text
  member_id: Text
  auth_method: Text
  mfa_verified?: Bool
  device_label: Text
  ip_prefix: Text
  expires_at: Text
end

## Audit log entry summary rendered on `/__arvo`.
struct AuditSummary
  seq: Int
  txid: Int
  principal: Text
  action: Text
  summary: Text
  at: Text
end

## Incremental sync cursor summary rendered on `/__arvo`.
struct SyncPeerSummary
  peer_id: Text
  acked_seq: Int
  acked_txid: Int
  pending_seq: Option(Int)
  updated_at: Text
end

## Search hit preview row rendered on `/__arvo`.
struct SearchPreviewHit
  doc_id: Text
  scope: Text
  score: Text
  matched_terms: List(Text)
end

## Storage-agnostic overview of persistence buckets, audit log tail, sync peers, and search hits.
struct StoreSnapshot
  engine: Text
  buckets: List(Text)
  audit_entries: List(AuditSummary)
  sync_peers: List(SyncPeerSummary)
  fts_query: Option(Text)
  fts_hits: List(SearchPreviewHit)
end

## Recorded replayable call summary rendered on `/__arvo/audit` and `/__arvo/replay`.
struct ReplayCallSummary
  seq: Int
  audit_seq: Option(Int)
  schema_version: Int
  principal: Text
  action: Text
  reason: Text
  at: Text
  outcome_kind: Text
  outcome_detail: Text
  world_id: Option(Text)
end

## Row-level diff summary for one storage bucket in a replay proposal.
struct RowDiffSummary
  bucket: Text
  added: Int
  removed: Int
  modified: Int
end

## Simulated or applied time-travel replay proposal summary.
struct ReplayProposalSummary
  id: Text
  description: Text
  status: Text
  created_by: Text
  created_at: Text
  total_calls: Int
  excluded: Int
  unchanged: Int
  reply_changed: Int
  now_refused: Int
  now_invariant_blocked: Int
  bucket_diffs: List(RowDiffSummary)
end

## Speculative agent workspace summary.
struct WorldSummary
  id: Text
  principal: Text
  grant_id: Text
  base_txid: Int
  step_count: Int
  status: Text
  created_at: Text
  expires_at: Text
end

## Time-travel replay call log, proposals, and speculative worlds.
struct TimeTravelSnapshot
  calls: List(ReplayCallSummary)
  proposals: List(ReplayProposalSummary)
  worlds: List(WorldSummary)
end

## Complete dashboard snapshot passed into `DevDashboard.handle`.
struct DashboardSnapshot
  jobs: JobQueueSnapshot
  sessions: List(SessionSummary)
  store: StoreSnapshot
  time_travel: TimeTravelSnapshot
end

## Empty `TimeTravelSnapshot` for backends without replay history.
fn empty_time_travel() : TimeTravelSnapshot
  TimeTravelSnapshot(calls: [], proposals: [], worlds: [])
end

## Default configuration mounting at `/__arvo` (strictly gated by `enabled?`).
fn default_config(app_name: Text, enabled?: Bool, mailbox_dir: Option(Text)) : DashboardConfig
  DashboardConfig(
    enabled?: enabled?,
    base_path: "/__arvo",
    app_name: app_name,
    mailbox_dir: mailbox_dir
  )
end

## Empty `DashboardSnapshot` useful for routes without persistence metrics wired yet.
fn empty_snapshot(engine: Text) : DashboardSnapshot
  DashboardSnapshot(
    jobs: JobQueueSnapshot(pending: 0, running: 0, completed: 0, failed: 0, recent: []),
    sessions: [],
    store: StoreSnapshot(
      engine: engine,
      buckets: [],
      audit_entries: [],
      sync_peers: [],
      fts_query: None,
      fts_hits: []
    ),
    time_travel: empty_time_travel()
  )
end

fn esc(s: Text) : Text
  Inertia.escape_html(s)
end

fn safe_href(raw: Text) : Option(Text)
  t = raw.trim
  return None if t.empty? or t.contains?("\r") or t.contains?("\n") or t.contains?("\"")
  if t.starts_with?("https://") or t.starts_with?("http://") or t.starts_with?("/")
    Some(esc(t))
  else
    None
  end
end

fn normalize_base_path(raw: Text) : Text
  t = raw.trim
  return "/__arvo" if t.empty? or t == "/"
  prefixed = if t.starts_with?("/"): t else: "/#{t}"
  var cur = prefixed
  while cur.char_count > 1 and cur.ends_with?("/")
    cur = cur.drop_suffix("/") or cur
  end
  cur
end

fn relative_subpath(req_path: Text, base_path: Text) : Option(Text)
  norm_base = normalize_base_path(base_path)
  return Some("") if req_path == norm_base or req_path == "#{norm_base}/"
  case req_path.drop_prefix(norm_base)
    Some(rest) if rest.starts_with?("/"): Some(rest)
    Some(_) | None: None
  end
end

fn dashboard_headers(nonce: Text) : Security.SecurityHeadersConfig
  csp = [
    "default-src 'none'",
    "base-uri 'none'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    "form-action 'self'",
    "style-src 'nonce-#{nonce}'"
  ].join("; ")
  Security.SecurityHeadersConfig(
    csp: Some(csp),
    hsts_seconds: None,
    hsts_include_subdomains?: false,
    frame_options: "DENY",
    referrer_policy: "no-referrer",
    permissions_policy: "camera=(), microphone=(), geolocation=()",
    cross_origin_opener_policy: Some("same-origin")
  )
end

fn wrap_layout(cfg: DashboardConfig, title: Text, active_tab: Text, nonce: Text, body_html: Text) : Text
  base = normalize_base_path(cfg.base_path)
  overview_cls = if active_tab == "overview": "tab active" else: "tab"
  mailbox_cls = if active_tab == "mailbox": "tab active" else: "tab"
  audit_cls = if active_tab == "audit": "tab active" else: "tab"
  replay_cls = if active_tab == "replay": "tab active" else: "tab"
  """
  <!doctype html>
  <html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>#{esc(title)} — #{esc(cfg.app_name)} Dev Dashboard</title>
    <style nonce="#{esc(nonce)}">
      body{font-family:ui-sans-serif,system-ui,sans-serif;margin:0;background:#0f172a;color:#e2e8f0;line-height:1.5}
      header{background:#1e293b;border-bottom:1px solid #334155;padding:14px 24px;display:flex;align-items:center;justify-content:space-between;gap:16px}
      nav{display:flex;flex-wrap:wrap;gap:8px}
      .tab{color:#cbd5e1;text-decoration:none;padding:6px 12px;border-radius:6px;font-size:14px;border:1px solid transparent}
      .tab.active{background:#334155;color:#fff;border-color:#475569}
      main{max-width:1100px;margin:24px auto;padding:0 20px}
      .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:24px}
      .card{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:14px 16px}
      .k{font-size:12px;color:#94a3b8;text-transform:uppercase;letter-spacing:.04em}
      .v{font-size:24px;font-weight:700;margin-top:4px}
      table{width:100%;border-collapse:collapse;background:#1e293b;border:1px solid #334155;border-radius:10px;overflow:hidden;margin-bottom:24px;font-size:13px}
      th,td{padding:10px 12px;text-align:left;border-bottom:1px solid #334155;vertical-align:top}
      th{background:#0f172a;color:#94a3b8;font-weight:600}
      code,pre{font-family:ui-monospace,SFMono-Regular,monospace;font-size:12px}
      pre{background:#020617;padding:12px;border-radius:8px;overflow:auto;white-space:pre-wrap}
      .btn{display:inline-block;background:#2563eb;color:#fff;padding:6px 12px;border-radius:6px;text-decoration:none;font-weight:600;font-size:13px;margin:4px 6px 4px 0}
      .badge{display:inline-block;background:#334155;color:#e2e8f0;padding:2px 8px;border-radius:999px;font-size:12px;margin:2px 4px 2px 0}
      iframe{width:100%;min-height:180px;border:1px solid #334155;border-radius:8px;background:#fff}
    </style>
  </head>
  <body>
    <header>
      <div><strong>#{esc(cfg.app_name)}</strong> <span class="badge">/__arvo dev</span></div>
      <nav>
        <a class="#{overview_cls}" href="#{esc(base)}">Overview</a>
        <a class="#{mailbox_cls}" href="#{esc(base)}/mailbox">Dev Mailbox</a>
        <a class="#{audit_cls}" href="#{esc(base)}/audit">Audit</a>
        <a class="#{replay_cls}" href="#{esc(base)}/replay">Replay</a>
        <a class="tab" href="#{esc(base)}/jobs.json">jobs.json</a>
        <a class="tab" href="#{esc(base)}/storage.json">storage.json</a>
        <a class="tab" href="#{esc(base)}/audit.json">audit.json</a>
        <a class="tab" href="#{esc(base)}/replay.json">replay.json</a>
      </nav>
    </header>
    <main>#{body_html}</main>
  </body>
  </html>
  """
end

## Renders the HTML overview page for `snap`.
fn render_overview_html(cfg: DashboardConfig, snap: DashboardSnapshot, nonce: Text) : Text
  cards = [
    (
      "<div class=\"card\"><div class=\"k\">Pending Jobs</div><div class=\"v\">#{snap.jobs.pending}</div></div>"
    ),
    (
      "<div class=\"card\"><div class=\"k\">Failed Jobs</div><div class=\"v\">#{snap.jobs.failed}</div></div>"
    ),
    (
      "<div class=\"card\"><div class=\"k\">Active Sessions</div><div class=\"v\">#{snap.sessions
        .size}</div></div>"
    ),
    (
      "<div class=\"card\"><div class=\"k\">Buckets (#{esc(snap.store.engine)})</div><div class=\"v\">#{snap
        .store.buckets.size}</div></div>"
    )
  ].join("")

  job_rows = if snap.jobs.recent.empty?
    "<tr><td colspan=\"5\">No jobs recorded yet.</td></tr>"
  else
    snap.jobs.recent.map(fn(j)
      err_txt = esc(j.last_error or "-")
      "<tr><td><code>#{esc(j.id)}</code></td><td>#{esc(j.job_name)}</td><td><span class=\"badge\">#{esc(
        j.state
      )}</span></td><td>#{j.attempts}/#{j.max_attempts}</td><td>#{err_txt}</td></tr>"
    end).join("")
  end

  sess_rows = if snap.sessions.empty?
    "<tr><td colspan=\"5\">No active sessions.</td></tr>"
  else
    snap.sessions.map(fn(s)
      mfa = if s.mfa_verified?: "yes" else: "no"
      "<tr><td><code>#{esc(s.id)}</code></td><td><code>#{esc(s.member_id)}</code></td><td>#{esc(
        s.auth_method
      )}</td><td>#{mfa}</td><td>#{esc(s.expires_at)}</td></tr>"
    end).join("")
  end

  audit_rows = if snap.store.audit_entries.empty?
    "<tr><td colspan=\"5\">No audit entries yet.</td></tr>"
  else
    snap.store.audit_entries.map(fn(a)
      "<tr><td>##{a.seq} (tx #{a.txid})</td><td>#{esc(a.principal)}</td><td><code>#{esc(a.action)}</code></td><td>#{esc(
        a.summary
      )}</td><td>#{esc(a.at)}</td></tr>"
    end).join("")
  end

  bucket_badges = if snap.store.buckets.empty?
    "<span>None</span>"
  else
    snap.store.buckets.map(fn(b) "<span class=\"badge\">#{esc(b)}</span>" end).join("")
  end

  peer_rows = if snap.store.sync_peers.empty?
    "<tr><td colspan=\"4\">No replication/backup sync peers registered.</td></tr>"
  else
    snap.store.sync_peers.map(fn(p)
      pend = case p.pending_seq
        Some(n): n.to_text
        None: "-"
      end
      "<tr><td><code>#{esc(p.peer_id)}</code></td><td>seq #{p.acked_seq} (tx #{p.acked_txid})</td><td>#{pend}</td><td>#{esc(
        p.updated_at
      )}</td></tr>"
    end).join("")
  end

  fts_block = case snap.store.fts_query
    None: ""
    Some(q):
      hits = if snap.store.fts_hits.empty?
        "<tr><td colspan=\"4\">No matches for query.</td></tr>"
      else
        snap.store.fts_hits.map(fn(h)
          terms = h.matched_terms.map(esc).join(", ")
          "<tr><td><code>#{esc(h.doc_id)}</code></td><td>#{esc(h.scope)}</td><td>#{esc(h.score)}</td><td>#{terms}</td></tr>"
        end).join("")
      end
      """
      <h2>Search Preview: <code>#{esc(q)}</code></h2>
      <table><thead><tr><th>Doc</th><th>Scope</th><th>Score</th><th>Terms</th></tr></thead><tbody>#{hits}</tbody></table>
      """
  end

  body = """
  <div class="grid">#{cards}</div>
  <h2>Buckets</h2>
  <div class="card" style="margin-bottom:24px">#{bucket_badges}</div>
  <h2>Recent Background Jobs</h2>
  <table><thead><tr><th>ID</th><th>Job</th><th>State</th><th>Attempts</th><th>Last Error</th></tr></thead><tbody>#{job_rows}</tbody></table>
  <h2>Active Sessions</h2>
  <table><thead><tr><th>ID</th><th>Member</th><th>Method</th><th>MFA</th><th>Expires</th></tr></thead><tbody>#{sess_rows}</tbody></table>
  <h2>Hash-Chained Audit Tail</h2>
  <table><thead><tr><th>Seq / Tx</th><th>Principal</th><th>Action</th><th>Summary</th><th>At</th></tr></thead><tbody>#{audit_rows}</tbody></table>
  <h2>Sync &amp; Encrypted Backup Peers</h2>
  <table><thead><tr><th>Peer</th><th>Acked</th><th>Pending</th><th>Updated</th></tr></thead><tbody>#{peer_rows}</tbody></table>
  #{fts_block}
  """
  wrap_layout(cfg, "Overview", "overview", nonce, body)
end

## Renders the Dev Mailbox HTML page displaying captured emails and sandboxed previews.
fn render_mailbox_html(cfg: DashboardConfig, mails: List(Mail.CapturedMail), nonce: Text) : Text
  cards = if mails.empty?
    "<div class=\"card\">Dev mailbox is empty. Trigger magic-link, verification, or invite emails to inspect them here.</div>"
  else
    mails.reverse.map(fn(m)
      recips = m.message.to.map(esc).join(", ")
      urls = Mail.extract_urls(m.message.text_body)
      links_html = if urls.empty?
        ""
      else
        btns = urls.filter_map(fn(u)
          safe_href(u).map(fn(hu) "<a class=\"btn\" href=\"#{hu}\">Open Action Link: #{hu}</a>" end)
        end).join("")
        if btns.empty?: "" else: "<div>#{btns}</div>"
      end
      iframe_html = case m.message.html_body
        Some(raw_html): "<iframe sandbox=\"\" srcdoc=\"#{esc(raw_html)}\"></iframe>"
        None: ""
      end
      """
      <div class="card" style="margin-bottom:16px">
        <div class="k">#{esc(m.sent_at.to_text)} &middot; ID <code>#{esc(m.id)}</code></div>
        <h3>#{esc(m.message.subject)}</h3>
        <p><strong>From:</strong> #{esc(m.message.from)} &middot; <strong>To:</strong> #{recips}</p>
        #{links_html}
        <pre>#{esc(m.message.text_body)}</pre>
        #{iframe_html}
      </div>
      """
    end).join("")
  end
  wrap_layout(cfg, "Dev Mailbox (#{mails.size})", "mailbox", nonce, cards)
end

## Renders the Audit & Replay Call Timeline HTML page.
fn render_audit_html(cfg: DashboardConfig, snap: DashboardSnapshot, nonce: Text) : Text
  audit_rows = if snap.store.audit_entries.empty?
    "<tr><td colspan=\"5\">No audit entries recorded yet.</td></tr>"
  else
    snap.store.audit_entries.map(fn(a)
      "<tr><td>##{a.seq} (tx #{a.txid})</td><td>#{esc(a.principal)}</td><td><code>#{esc(a.action)}</code></td><td>#{esc(
        a.summary
      )}</td><td>#{esc(a.at)}</td></tr>"
    end).join("")
  end

  call_rows = if snap.time_travel.calls.empty?
    "<tr><td colspan=\"6\">No replayable calls recorded yet.</td></tr>"
  else
    snap.time_travel.calls.map(fn(c)
      reason_txt = if c.reason.empty?: "-" else: c.reason
      "<tr><td>##{c.seq} (v#{c.schema_version})</td><td>#{esc(c.principal)}</td><td><code>#{esc(
        c.action
      )}</code></td><td><span class=\"badge\">#{esc(c.outcome_kind)}</span> #{esc(c.outcome_detail)}</td><td>#{esc(
        reason_txt
      )}</td><td>#{esc(c.at)}</td></tr>"
    end).join("")
  end

  body = """
  <h2>Audit &amp; Replay Timeline</h2>
  <div class="grid">
    <div class="card"><div class="k">Audit Entries</div><div class="v">#{snap.store.audit_entries
    .size}</div></div>
    <div class="card"><div class="k">Replayable Calls</div><div class="v">#{snap.time_travel.calls
    .size}</div></div>
  </div>
  <h2>Hash-Chained Audit Log</h2>
  <table><thead><tr><th>Seq / Tx</th><th>Principal</th><th>Action</th><th>Summary</th><th>At</th></tr></thead><tbody>#{audit_rows}</tbody></table>
  <h2>Replayable Action Log</h2>
  <table><thead><tr><th>Seq / Schema</th><th>Principal</th><th>Action</th><th>Outcome</th><th>Reason</th><th>At</th></tr></thead><tbody>#{call_rows}</tbody></table>
  """
  wrap_layout(cfg, "Audit Timeline", "audit", nonce, body)
end

## Renders the Time-Travel Replay Proposals & Speculative Worlds HTML page.
fn render_replay_html(cfg: DashboardConfig, snap: DashboardSnapshot, nonce: Text) : Text
  prop_rows = if snap.time_travel.proposals.empty?
    "<tr><td colspan=\"6\">No time-travel replay proposals yet.</td></tr>"
  else
    snap.time_travel.proposals.map(fn(p)
      diff_badges = if p.bucket_diffs.empty?
        "<span>-</span>"
      else
        p.bucket_diffs.map(fn(d)
          "<span class=\"badge\">#{esc(d.bucket)}: +#{d.added} / ~#{d.modified} / -#{d.removed}</span>"
        end).join("")
      end
      "<tr><td><code>#{esc(p.id)}</code></td><td><span class=\"badge\">#{esc(p.status)}</span></td><td>#{esc(
        p.description
      )}</td><td>#{p.excluded} excl / #{p.unchanged} unch / #{p.reply_changed} chg</td><td>#{diff_badges}</td><td>#{esc(
        p.created_by
      )}</td></tr>"
    end).join("")
  end

  world_rows = if snap.time_travel.worlds.empty?
    "<tr><td colspan=\"6\">No speculative worlds recorded.</td></tr>"
  else
    snap.time_travel.worlds.map(fn(w)
      "<tr><td><code>#{esc(w.id)}</code></td><td>#{esc(w.principal)}</td><td><span class=\"badge\">#{esc(
        w.status
      )}</span></td><td>tx #{w.base_txid}</td><td>#{w.step_count}</td><td>#{esc(w.expires_at)}</td></tr>"
    end).join("")
  end

  body = """
  <h2>Time-Travel Replay &amp; Speculative Worlds</h2>
  <div class="grid">
    <div class="card"><div class="k">Proposals</div><div class="v">#{snap.time_travel.proposals.size}</div></div>
    <div class="card"><div class="k">Speculative Worlds</div><div class="v">#{snap.time_travel
    .worlds.size}</div></div>
  </div>
  <h2>Replay Proposals</h2>
  <table><thead><tr><th>ID</th><th>Status</th><th>Description</th><th>Outcome Summary</th><th>Bucket Diffs</th><th>Author</th></tr></thead><tbody>#{prop_rows}</tbody></table>
  <h2>Speculative Worlds</h2>
  <table><thead><tr><th>ID</th><th>Principal</th><th>Status</th><th>Base Tx</th><th>Steps</th><th>Expires</th></tr></thead><tbody>#{world_rows}</tbody></table>
  """
  wrap_layout(cfg, "Time-Travel Replay", "replay", nonce, body)
end

fn json_no_store(val: T, nonce: Text) : Api.Response where T: Json
  res = Api.encoded_json_response(200, val.to_json).with_header("Cache-Control", "no-store")
  Security.apply_headers(res, dashboard_headers(nonce))
end

fn read_mails(rf: ReadFiles, cfg: DashboardConfig) : List(Mail.CapturedMail)
  case cfg.mailbox_dir
    Some(dir):
      case Mail.list_dev_mailbox(rf, dir)
        Ok(ms): ms
        Error(_): []
      end
    None: []
  end
end

## Handles HTTP requests to `/__arvo` (`cfg.enabled? == false` always fails closed with `404`).
fn handle(
  req: Api.Request,
  rf: ReadFiles,
  rng: SecureRandom,
  cfg: DashboardConfig,
  snap: DashboardSnapshot
) : Api.Response
  promise "disabled dev dashboard always returns 404"
    (not cfg.enabled?) implies result.status == 404
  end

  return Api.text_response(404, "not found") if not cfg.enabled?
  return Api.text_response(404, "not found") if req.method.ascii_uppercase != "GET"

  sub = case relative_subpath(req.path, cfg.base_path)
    Some(s): s
    None: return Api.text_response(404, "not found")
  end
  nonce = Security.csp_nonce(rng)
  hdrs = dashboard_headers(nonce)

  if sub == ""
    html = render_overview_html(cfg, snap, nonce)
    res = Api.html_response(200, html).with_header("Cache-Control", "no-store")
    Security.apply_headers(res, hdrs)
  else if sub == "/mailbox"
    mails = read_mails(rf, cfg)
    html = render_mailbox_html(cfg, mails, nonce)
    res = Api.html_response(200, html).with_header("Cache-Control", "no-store")
    Security.apply_headers(res, hdrs)
  else if sub == "/mailbox.json"
    mails = read_mails(rf, cfg).reverse.map(fn(m)
      Json.Object({
        "id": Json.String(m.id),
        "sent_at": Json.String(m.sent_at.to_text),
        "from": Json.String(m.message.from),
        "to": m.message.to.to_json,
        "subject": Json.String(m.message.subject),
        "text_body": Json.String(m.message.text_body),
        "urls": Mail.extract_urls(m.message.text_body).to_json
      })
    end)
    json_no_store(Json.Array(mails), nonce)
  else if sub == "/audit"
    html = render_audit_html(cfg, snap, nonce)
    res = Api.html_response(200, html).with_header("Cache-Control", "no-store")
    Security.apply_headers(res, hdrs)
  else if sub == "/audit.json"
    payload = Json.Object({
      "audit_entries": snap.store.audit_entries.to_json,
      "replay_calls": snap.time_travel.calls.to_json
    })
    json_no_store(payload, nonce)
  else if sub == "/replay"
    html = render_replay_html(cfg, snap, nonce)
    res = Api.html_response(200, html).with_header("Cache-Control", "no-store")
    Security.apply_headers(res, hdrs)
  else if sub == "/replay.json"
    json_no_store(snap.time_travel, nonce)
  else if sub == "/jobs.json"
    json_no_store(snap.jobs, nonce)
  else if sub == "/sessions.json"
    json_no_store(snap.sessions, nonce)
  else if sub == "/storage.json"
    json_no_store(snap.store, nonce)
  else
    Api.text_response(404, "not found")
  end
end

test "Arvo.DevDashboard fails closed when disabled, renders Dev Mailbox & Audit/Replay cleanly, and escapes XSS"
  t0 = Time.parse("2026-11-28T01:00:00Z") or stop "t0"
  rng = SecureRandom.seeded(99)
  f = Files.in_memory({})
  rf = f.read_only
  snap = DashboardSnapshot(
    jobs: JobQueueSnapshot(
      pending: 1,
      running: 0,
      completed: 4,
      failed: 0,
      recent: [
        JobSummary(
          id: "job_1",
          queue: "default",
          job_name: "mail.send",
          state: "pending",
          attempts: 0,
          max_attempts: 5,
          run_at: t0.to_text,
          last_error: None
        )
      ]
    ),
    sessions: [
      SessionSummary(
        id: "s_1",
        member_id: "usr_1",
        auth_method: "passkey",
        mfa_verified?: true,
        device_label: "Safari",
        ip_prefix: "10.0.0.0/24",
        expires_at: t0.to_text
      )
    ],
    store: StoreSnapshot(
      engine: "embedded",
      buckets: ["bills", "_audit"],
      audit_entries: [
        AuditSummary(
          seq: 1,
          txid: 1,
          principal: "usr_1",
          action: "bill.create",
          summary: "<script>alert(1)</script>",
          at: t0.to_text
        )
      ],
      sync_peers: [
        SyncPeerSummary(
          peer_id: "s3-prod",
          acked_seq: 3,
          acked_txid: 12,
          pending_seq: None,
          updated_at: t0.to_text
        )
      ],
      fts_query: Some("water"),
      fts_hits: [
        SearchPreviewHit(doc_id: "doc_1", scope: "public", score: "1.42", matched_terms: ["water"])
      ]
    ),
    time_travel: TimeTravelSnapshot(
      calls: [
        ReplayCallSummary(
          seq: 1,
          audit_seq: Some(1),
          schema_version: 1,
          principal: "usr_1",
          action: "bill.create",
          reason: "<img src=x onerror=alert(1)>",
          at: t0.to_text,
          outcome_kind: "ok",
          outcome_detail: "{\"id\":1}",
          world_id: None
        )
      ],
      proposals: [
        ReplayProposalSummary(
          id: "prop_1",
          description: "<script>xss()</script> Undo #1",
          status: "pending",
          created_by: "usr_1",
          created_at: t0.to_text,
          total_calls: 1,
          excluded: 1,
          unchanged: 0,
          reply_changed: 0,
          now_refused: 0,
          now_invariant_blocked: 0,
          bucket_diffs: [RowDiffSummary(bucket: "bills", added: 0, removed: 1, modified: 0)]
        )
      ],
      worlds: [
        WorldSummary(
          id: "w_1",
          principal: "agent_1",
          grant_id: "g_1",
          base_txid: 2,
          step_count: 3,
          status: "open",
          created_at: t0.to_text,
          expires_at: t0.to_text
        )
      ]
    )
  )

  # Disabled config ALWAYS returns 404 across every endpoint
  off_cfg = default_config("Acme", false, Some("tmp/mailbox"))
  for p in [
    "/__arvo",
    "/__arvo/mailbox",
    "/__arvo/mailbox.json",
    "/__arvo/audit",
    "/__arvo/audit.json",
    "/__arvo/replay",
    "/__arvo/replay.json",
    "/__arvo/jobs.json"
  ]
    assert handle(Api.get(p), rf, rng, off_cfg, snap).status == 404
  end

  # Deliver a captured email into DevMailbox JSONL
  msg = Mail.MailMessage(
    from: "auth@acme.io",
    to: ["ada@acme.io"],
    reply_to: None,
    subject: "Sign in <b>Acme</b>",
    text_body: "Click https://localhost:8080/magic?token=abc_123 to sign in.",
    html_body: Some("<script>evil()</script><p>Hello</p>"),
    headers: []
  )
  assert Mail.deliver(
    Mail.DevMailbox(dir: "tmp/mailbox"),
    msg,
    Network.fake({}),
    f,
    rng,
    Clock.fixed(t0)
  ) is
    Ok(_)

  on_cfg = default_config("Acme", true, Some("tmp/mailbox"))
  ov = handle(Api.get("/__arvo"), rf, rng, on_cfg, snap)
  assert ov.status == 200
  assert ov.header("X-Frame-Options") == Some("DENY")
  assert (ov.header("Content-Security-Policy") or "").contains?("default-src 'none'")
  assert ov.text.contains?("s3-prod")
  assert ov.text.contains?("&lt;script&gt;alert(1)&lt;/script&gt;")
  assert not ov.text.contains?("<script>alert(1)</script>")

  mbox = handle(Api.get("/__arvo/mailbox"), rf, rng, on_cfg, snap)
  assert mbox.status == 200
  assert mbox.text.contains?("href=\"https://localhost:8080/magic?token=abc_123\"")
  assert mbox.text.contains?("<iframe sandbox=\"\" srcdoc=\"&lt;script&gt;evil()&lt;/script&gt;")

  audit_html = handle(Api.get("/__arvo/audit"), rf, rng, on_cfg, snap)
  assert audit_html.status == 200
  assert audit_html.text.contains?("&lt;img src=x onerror=alert(1)&gt;")
  assert not audit_html.text.contains?("<img src=x")

  assert handle(Api.get("/__arvo/audit.json"), rf, rng, on_cfg, snap) is adoc_res and
    adoc_res.status == 200 and
    adoc_res.text.contains?("\"replay_calls\"")

  replay_html = handle(Api.get("/__arvo/replay"), rf, rng, on_cfg, snap)
  assert replay_html.status == 200
  assert replay_html.text.contains?("&lt;script&gt;xss()&lt;/script&gt;")
  assert not replay_html.text.contains?("<script>xss()")
  assert replay_html.text.contains?("bills: +0 / ~0 / -1")
  assert replay_html.text.contains?("w_1")

  assert handle(Api.get("/__arvo/replay.json"), rf, rng, on_cfg, snap) is rdoc_res and
    rdoc_res.status == 200 and
    rdoc_res.text.contains?("\"prop_1\"")

  assert handle(Api.get("/__arvo/mailbox.json"), rf, rng, on_cfg, snap).status == 200
  assert handle(Api.get("/__arvo/jobs.json"), rf, rng, on_cfg, snap).json is Ok(jdoc) and
    jdoc.int_at("completed") == Some(4)
  assert handle(Api.get("/__arvo/sessions.json"), rf, rng, on_cfg, snap).status == 200
  assert handle(Api.get("/__arvo/storage.json"), rf, rng, on_cfg, snap).status == 200
  assert handle(Api.get("/__arvo/nope"), rf, rng, on_cfg, snap).status == 404
end
