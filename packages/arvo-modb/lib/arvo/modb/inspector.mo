## Strictly `ReadFiles`-only MoDB runtime inspector populating `Arvo.DevDashboard.DashboardSnapshot`
## across `Arvo.Modb.Jobs`, `Arvo.Modb.Sessions`, `Modb.buckets`, `_modb_audit`, `Modb.Sync`,
## `Modb.Replay` / `Modb.World` (`Arvo.Modb.TimeTravel`), and optional `Modb.Fts` previews.
module Arvo.Modb.Inspector
expose InspectorConfig(..), default_config, collect_store_snapshot, collect_snapshot
use Api
use Arvo.DevDashboard
use Arvo.Modb.Jobs
use Arvo.Modb.Sessions
use Arvo.Modb.TimeTravel
use Arvo.Session
use Json
use Modb
use Modb.Fts
use Modb.Ledger
use Modb.Sync
use Modb.Table

## Paths and preview caps used by `collect_snapshot`.
struct InspectorConfig
  db_path: Text
  sessions_db_path: Option(Text)
  jobs_db_path: Option(Text)
  max_recent_jobs: Int
  max_audit_entries: Int
  fts_preview: Option((Fts.FtsIndex, Text, Int))
end

## Default inspector configuration reading from `db_path` (caps: 20 recent jobs, 25 audit rows).
fn default_config(db_path: Text) : InspectorConfig
  InspectorConfig(
    db_path: db_path,
    sessions_db_path: None,
    jobs_db_path: None,
    max_recent_jobs: 20,
    max_audit_entries: 25,
    fts_preview: None
  )
end

fn clamp_cap(n: Int, fallback: Int) : Int
  if n < 0: 0 else if n == 0: fallback else: n
end

## Collects bucket list, audit tail, sync peers, and optional FTS preview from an open `Modb.Store`.
fn collect_store_snapshot(s: Modb.Store, cfg: InspectorConfig) : Result(
  DevDashboard.StoreSnapshot,
  Text
)
  buckets = try Modb.buckets(s).map_error(fn(e) e.to_text end)

  audit_cap = clamp_cap(cfg.max_audit_entries, 25)
  audit_entries = if buckets.contains?(Ledger.audit_bucket) and audit_cap > 0
    raw_audit = try Table.all(s, Ledger.audit_table()).map_error(fn(e) e.to_text end)
    raw_audit.reverse.take(audit_cap).map(fn(p)
      e = p.1
      DevDashboard.AuditSummary(
        seq: e.seq,
        txid: e.txid,
        principal: e.principal,
        action: e.action,
        summary: e.summary,
        at: e.at.to_text
      )
    end)
  else
    []
  end

  sync_peers = if buckets.contains?(Sync.sync_peers_bucket)
    peers = try Sync.list_peers(s).map_error(fn(e) Sync.to_text(e) end)
    peers.map(fn(sp)
      DevDashboard.SyncPeerSummary(
        peer_id: sp.peer_id,
        acked_seq: sp.acked_seq,
        acked_txid: sp.acked_txid,
        pending_seq: sp.pending_seq,
        updated_at: sp.updated_at.to_text
      )
    end)
  else
    []
  end

  (fts_query, fts_hits) = case cfg.fts_preview
    None: (None, [])
    Some((idx, q, lim)):
      eff_lim = if lim <= 0: 10 else: lim
      if q.trim.empty?
        (Some(q), [])
      else
        raw_hits = try Fts.search(s, idx, q, Fts.default_search_options(eff_lim)).map_error(
          fn(e) Fts.to_text(e) end
        )
        mapped = raw_hits.map(fn(h)
          DevDashboard.SearchPreviewHit(
            doc_id: h.doc_id,
            scope: h.scope,
            score: h.score.to_text,
            matched_terms: h.matched_terms
          )
        end)
        (Some(q), mapped)
      end
  end

  Ok(
    DevDashboard.StoreSnapshot(
      engine: "modb",
      buckets: buckets,
      audit_entries: audit_entries,
      sync_peers: sync_peers,
      fts_query: fts_query,
      fts_hits: fts_hits
    )
  )
end

fn collect_jobs(rf: ReadFiles, path: Text, max_recent: Int) : Result(
  DevDashboard.JobQueueSnapshot,
  Text
)
  if not rf.exists?(path)
    return Ok(
      DevDashboard.JobQueueSnapshot(pending: 0, running: 0, completed: 0, failed: 0, recent: [])
    )
  end
  stats = try Jobs.queue_stats(rf, path).map_error(fn(e) e.to_text end)
  cap = clamp_cap(max_recent, 20)
  rec_rows = try Jobs.list_recent(rf, path, cap).map_error(fn(e) e.to_text end)
  recent = rec_rows.map(fn(j)
    DevDashboard.JobSummary(
      id: j.id,
      queue: j.queue,
      job_name: j.job_name,
      state: j.state,
      attempts: j.attempts,
      max_attempts: j.max_attempts,
      run_at: j.run_at,
      last_error: j.last_error
    )
  end)
  Ok(
    DevDashboard.JobQueueSnapshot(
      pending: stats.pending,
      running: stats.running,
      completed: stats.completed,
      failed: stats.failed,
      recent: recent
    )
  )
end

fn collect_sessions(rf: ReadFiles, path: Text) : Result(List(DevDashboard.SessionSummary), Text)
  if not rf.exists?(path)
    return Ok([])
  end
  Modb.with_shared_lock(
    rf,
    path,
    fn(me) me.to_text end,
    fn(s)
      buckets = try Modb.buckets(s).map_error(fn(e) e.to_text end)
      if not buckets.contains?("_arvo_sessions")
        return Ok([])
      end
      rows = try Table.all(s, Sessions.sessions_table()).map_error(fn(e) e.to_text end)
      Ok(
        rows.map(fn(row)
          sid = row.0
          st = row.1
          DevDashboard.SessionSummary(
            id: sid,
            member_id: st.member_id,
            auth_method: st.auth_method or "session",
            mfa_verified?: st.mfa_verified_at is Some(_),
            device_label: st.user_agent or "unknown",
            ip_prefix: st.ip_prefix or "-",
            expires_at: st.expires_at.to_text
          )
        end)
      )
    end
  )
end

## Collects a full `DevDashboard.DashboardSnapshot` strictly via `ReadFiles`.
fn collect_snapshot(rf: ReadFiles, cfg: InspectorConfig) : Result(
  DevDashboard.DashboardSnapshot,
  Text
)
  jobs_path = cfg.jobs_db_path or cfg.db_path
  sess_path = cfg.sessions_db_path or cfg.db_path
  jobs = try collect_jobs(rf, jobs_path, cfg.max_recent_jobs)
  sessions = try collect_sessions(rf, sess_path)
  audit_cap = clamp_cap(cfg.max_audit_entries, 25)
  (store, time_travel) = if rf.exists?(cfg.db_path)
    try Modb.with_shared_lock(
      rf,
      cfg.db_path,
      fn(me) me.to_text end,
      fn(s)
        st = try collect_store_snapshot(s, cfg)
        tt = try TimeTravel.collect_time_travel_from_store(s, audit_cap)
        Ok((st, tt))
      end
    )
  else
    (
      DevDashboard.StoreSnapshot(
        engine: "modb",
        buckets: [],
        audit_entries: [],
        sync_peers: [],
        fts_query: None,
        fts_hits: []
      ),
      DevDashboard.empty_time_travel()
    )
  end
  Ok(
    DevDashboard.DashboardSnapshot(
      jobs: jobs,
      sessions: sessions,
      store: store,
      time_travel: time_travel
    )
  )
end

test "Arvo.Modb.Inspector collects ReadFiles-only snapshot across Jobs, Sessions, Ledger, Sync, and FTS"
  files = Files.in_memory({})
  rf = files.read_only
  path = "inspect.modb"
  rng = SecureRandom.seeded(5150)
  t0 = Time.parse("2026-11-28T03:00:00Z") or stop "t0"
  clk = Clock.fixed(t0)

  # Missing DB returns clean empty snapshot
  empty_snap = case collect_snapshot(rf, default_config(path))
    Ok(v): v
    Error(_): stop "expected empty snapshot"
  end
  assert empty_snap.store.engine == "modb" and empty_snap.store.buckets.empty?

  # Populate Ledger + FTS + Jobs + Sessions + Sync peer
  sc = Ledger.schema(0).with_require_reason(false)
  fidx = Fts.index("notes")
  _tx = Ledger.transact_locked(
    files,
    path,
    sc,
    Ledger.WriteMeta(principal: "usr_1", action: "note.index", reason: "", at: t0),
    "indexed doc",
    Json.Null,
    fn(e) Ledger.to_text(e) end,
    fn(tx)
      tx1 = try Fts.tx_index_document(
        tx,
        fidx,
        Fts.DocumentInput(
          doc_id: "n1",
          scope: "public",
          fields: [Fts.FieldInput(name: "body", text: "water bill due friday", weight: 1)]
        )
      ).map_error(fn(e) Fts.to_text(e) end)
      Ok((tx1, Unit))
    end
  )
  _job = Jobs.enqueue(files, path, rng, clk, "mail.send", Json.Object({}))
  _sess = Sessions.create(
    files,
    path,
    rng,
    clk,
    rng.bytes(32),
    "usr_1",
    Session.default_config(true)
  )
  _peer = Sync.init_peer_locked(files, path, "s3-prod", false, false, t0)

  var cfg = default_config(path)
  cfg.fts_preview = Some((fidx, "water", 5))
  snap = case collect_snapshot(rf, cfg)
    Ok(v): v
    Error(_): stop "collect_snapshot failed"
  end
  assert snap.jobs.pending == 1
  assert snap.jobs.recent.size == 1
  assert snap.sessions.size == 1 and (snap.sessions.first or stop "s0").member_id == "usr_1"
  assert snap.store.audit_entries.size == 1
  assert snap.store.sync_peers.size == 1 and
    (snap.store.sync_peers.first or stop "p0").peer_id == "s3-prod"
  assert snap.store.fts_hits.size == 1 and (snap.store.fts_hits.first or stop "h0").doc_id == "n1"

  # Feeds straight into Arvo.DevDashboard cleanly
  res = DevDashboard.handle(
    Api.get("/__arvo"),
    rf,
    rng,
    DevDashboard.default_config("AcmeMoDB", true, None),
    snap
  )
  assert res.status == 200 and
    res.text.contains?("s3-prod") and
    res.text.contains?("water") and
    res.text.contains?("note.index")
  assert snap.time_travel.calls.empty?
  audit_res = DevDashboard.handle(
    Api.get("/__arvo/audit"),
    rf,
    rng,
    DevDashboard.default_config("AcmeMoDB", true, None),
    snap
  )
  assert audit_res.status == 200 and audit_res.text.contains?("note.index")
end
