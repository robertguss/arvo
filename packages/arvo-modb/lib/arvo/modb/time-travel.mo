## Read-only MoDB Time-Travel inspector & selective-undo lifecycle wrapper over
## `Modb.Replay` and `Modb.World` feeding `Arvo.DevDashboard` (`/audit`, `/replay`) and React UIs.
module Arvo.Modb.TimeTravel
expose collect_time_travel_from_store,
collect_time_travel,
summarize_call,
summarize_proposal,
summarize_world,
preview_selective_undo,
propose_selective_undo,
accept_undo_proposal,
discard_undo_proposal
use Arvo.DevDashboard
use Json
use Modb
use Modb.Ledger
use Modb.Replay
use Modb.Table
use Modb.World

fn clamp_cap(n: Int, fallback: Int) : Int
  if n < 0: 0 else if n == 0: fallback else: n
end

## Formats one `Replay.CallRecord` for JSON/HTML dashboard inspection.
fn summarize_call(rec: Replay.CallRecord) : DevDashboard.ReplayCallSummary
  (okind, odetail) = case rec.outcome
    Replay.OrigOk(reply: r): ("ok", r.to_text)
    Replay.OrigRefused(error: err): ("refused", err)
  end
  DevDashboard.ReplayCallSummary(
    seq: rec.seq,
    audit_seq: rec.audit_seq,
    schema_version: rec.schema_version,
    principal: rec.principal,
    action: rec.action,
    reason: rec.reason,
    at: rec.at.to_text,
    outcome_kind: okind,
    outcome_detail: odetail,
    world_id: rec.world_id
  )
end

fn proposal_status_text(st: Replay.ProposalStatus) : Text
  case st
    Replay.Pending: "pending"
    Replay.Accepted(commit_txid: txid, accepted_by: _, accepted_at: _): "accepted (tx #{txid})"
    Replay.Discarded(discarded_by: _, discarded_at: _): "discarded"
  end
end

## Formats one `Replay.ReplayProposal` for JSON/HTML dashboard inspection.
fn summarize_proposal(prop: Replay.ReplayProposal) : DevDashboard.ReplayProposalSummary
  diffs = prop.bucket_diffs.map(fn(d)
    DevDashboard.RowDiffSummary(
      bucket: d.bucket,
      added: d.added,
      removed: d.removed,
      modified: d.modified
    )
  end)
  DevDashboard.ReplayProposalSummary(
    id: prop.id,
    description: prop.description,
    status: proposal_status_text(prop.status),
    created_by: prop.created_by,
    created_at: prop.created_at.to_text,
    total_calls: prop.summary.total_calls,
    excluded: prop.summary.excluded,
    unchanged: prop.summary.unchanged,
    reply_changed: prop.summary.reply_changed,
    now_refused: prop.summary.now_refused,
    now_invariant_blocked: prop.summary.now_invariant_blocked,
    bucket_diffs: diffs
  )
end

fn world_status_text(st: World.WorldStatus) : Text
  case st
    World.Open: "open"
    World.Landed(commit_txid: txid): "landed (tx #{txid})"
    World.Rejected(reason: r): "rejected (#{r})"
    World.Dropped: "dropped"
  end
end

## Formats one `World.WorldRecord` for JSON/HTML dashboard inspection.
fn summarize_world(w: World.WorldRecord) : DevDashboard.WorldSummary
  DevDashboard.WorldSummary(
    id: w.id,
    principal: w.principal,
    grant_id: w.grant_id,
    base_txid: w.base_txid,
    step_count: w.steps.size,
    status: world_status_text(w.status),
    created_at: w.created_at.to_text,
    expires_at: w.expires_at.to_text
  )
end

## Collects replay call tail, replay proposals, and speculative worlds from an open `Modb.Store`.
fn collect_time_travel_from_store(s: Modb.Store, max_calls: Int) : Result(
  DevDashboard.TimeTravelSnapshot,
  Text
)
  buckets = try Modb.buckets(s).map_error(fn(e) e.to_text end)
  cap = clamp_cap(max_calls, 25)

  calls = if buckets.contains?(Replay.replay_calls_bucket) and cap > 0
    raw = try Replay.list_calls_tail(s, cap).map_error(fn(e) Replay.to_text(e) end)
    raw.reverse.map(summarize_call)
  else
    []
  end

  proposals = if buckets.contains?(Replay.replay_proposals_bucket)
    raw_props = try Replay.list_proposals(s).map_error(fn(e) Replay.to_text(e) end)
    raw_props.reverse.map(summarize_proposal)
  else
    []
  end

  worlds = if buckets.contains?(World.worlds_bucket)
    raw_worlds = try World.list_worlds(s).map_error(fn(e) World.to_text(e) end)
    raw_worlds.reverse.map(summarize_world)
  else
    []
  end

  Ok(DevDashboard.TimeTravelSnapshot(calls: calls, proposals: proposals, worlds: worlds))
end

## Collects a `DevDashboard.TimeTravelSnapshot` strictly via `ReadFiles`.
fn collect_time_travel(rf: ReadFiles, db_path: Text, max_calls: Int) : Result(
  DevDashboard.TimeTravelSnapshot,
  Text
)
  if not rf.exists?(db_path)
    return Ok(DevDashboard.empty_time_travel())
  end
  Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) me.to_text end,
    fn(s) collect_time_travel_from_store(s, max_calls) end
  )
end

## Simulates selective undo/replay offline via `ReadFiles` only (`Replay.preview_replay`),
## leaving live data completely untouched.
fn preview_selective_undo(
  rf: ReadFiles,
  db_path: Text,
  sc: Ledger.Schema,
  rc: Replay.ReplayCatalog,
  filter: Replay.ReplayFilter,
  proposal_id: Text,
  description: Text,
  created_by: Text,
  now: Time
) : Result(DevDashboard.ReplayProposalSummary, Text)
  Ledger.read_locked(
    rf,
    db_path,
    sc,
    fn(le) Ledger.to_text(le) end,
    fn(db)
      prop = try Replay.preview_replay(db, rc, filter, proposal_id, description, created_by, now)
        .map_error(fn(re) Replay.to_text(re) end)
      Ok(summarize_proposal(prop))
    end
  )
end

## Persists a simulated `ReplayProposal` under lock so an operator can review and accept or discard it.
fn propose_selective_undo(
  files: Files,
  db_path: Text,
  sc: Ledger.Schema,
  rc: Replay.ReplayCatalog,
  filter: Replay.ReplayFilter,
  proposal_id: Text,
  description: Text,
  created_by: Text,
  now: Time
) : Result(DevDashboard.ReplayProposalSummary, Text)
  prop = try Replay.simulate_replay_locked(
    files,
    db_path,
    sc,
    rc,
    filter,
    proposal_id,
    description,
    created_by,
    now
  ).map_error(fn(re) Replay.to_text(re) end)
  Ok(summarize_proposal(prop))
end

## Atomically lands a fresh pending replay proposal onto the live database with an audit entry.
fn accept_undo_proposal(
  files: Files,
  db_path: Text,
  sc: Ledger.Schema,
  proposal_id: Text,
  admin_meta: Ledger.WriteMeta
) : Result(DevDashboard.ReplayProposalSummary, Text)
  prop = try Replay.accept_proposal_locked(files, db_path, sc, proposal_id, admin_meta).map_error(
    fn(re) Replay.to_text(re) end
  )
  Ok(summarize_proposal(prop))
end

## Discards a pending replay proposal without touching live user tables or the audit chain.
fn discard_undo_proposal(
  files: Files,
  db_path: Text,
  sc: Ledger.Schema,
  proposal_id: Text,
  discarded_by: Text,
  now: Time
) : Result(DevDashboard.ReplayProposalSummary, Text)
  prop = try Replay.discard_proposal_locked(files, db_path, sc, proposal_id, discarded_by, now)
    .map_error(fn(re) Replay.to_text(re) end)
  Ok(summarize_proposal(prop))
end

test "Arvo.Modb.TimeTravel collects calls, previews selective undo via ReadFiles, and accepts/discards proposals"
  files = Files.in_memory({})
  rf = files.read_only
  path = "timetravel.modb"
  t1 = Time.parse("2026-11-28T07:00:00Z") or stop "t1"
  t2 = Time.parse("2026-11-28T07:05:00Z") or stop "t2"
  t3 = Time.parse("2026-11-28T07:10:00Z") or stop "t3"
  t4 = Time.parse("2026-11-28T07:15:00Z") or stop "t4"

  assert collect_time_travel(rf, path, 10) == Ok(DevDashboard.empty_time_travel())

  items = Table.text_key[Int]("items")
  sc = Ledger.schema(0).with_require_reason(false)
  rc = Replay.catalog().with_action(
    "item.put",
    fn(tx, args)
      k = args.text_at("k") or "missing"
      v = args.int_at("v") or 0
      tx1 = try Table.put(tx, items, k, v).map_error(fn(e) e.to_text end)
      Ok((tx1, Json.Object({"k": Json.String(k), "v": Json.int(v)})))
    end
  )

  # Execute two replayable actions
  assert Ledger.locked(
    files,
    path,
    sc,
    t1,
    fn(e) Replay.LedgerFailure(e) end,
    fn(db)
      meta1 = Ledger.WriteMeta(principal: "ada@local", action: "item.put", reason: "add a", at: t1)
      (_d1, _rep1, c1) = try Replay.execute(
        db,
        rc,
        meta1,
        Json.Object({"k": Json.String("a"), "v": Json.int(10)})
      )
      Ok(c1)
    end
  ) is
    Ok(_)
  assert Ledger.locked(
    files,
    path,
    sc,
    t2,
    fn(e) Replay.LedgerFailure(e) end,
    fn(db)
      meta2 = Ledger.WriteMeta(
        principal: "grace@local",
        action: "item.put",
        reason: "add b",
        at: t2
      )
      (_d2, _rep2, c2) = try Replay.execute(
        db,
        rc,
        meta2,
        Json.Object({"k": Json.String("b"), "v": Json.int(20)})
      )
      Ok(c2)
    end
  ) is
    Ok(_)

  snap1 = case collect_time_travel(rf, path, 25)
    Ok(s): s
    Error(_): stop "collect_time_travel failed"
  end
  assert snap1.calls.size == 2
  assert (snap1.calls.first or stop "first").seq == 2
  assert (snap1.calls.first or stop "first").principal == "grace@local"

  # ReadFiles-only selective undo preview leaves live table untouched
  prev = case preview_selective_undo(
    rf,
    path,
    sc,
    rc,
    Replay.ExcludeSeqs(seqs: [2]),
    "undo_prev",
    "Preview undo call #2",
    "ada@local",
    t3
  )
    Ok(p): p
    Error(_): stop "preview failed"
  end
  assert prev.excluded == 1 and prev.unchanged == 1
  assert prev.bucket_diffs.any?(fn(d) d.bucket == "items" and d.removed == 1 end)
  assert Modb.with_shared_lock(
    rf,
    path,
    fn(me) me.to_text end,
    fn(s) Table.get(s, items, "b").map_error(fn(te) te.to_text end) end
  ) ==
    Ok(Some(20))

  # Persist two proposals, discard one, then accept the other to roll back item "b" cleanly
  assert propose_selective_undo(
    files,
    path,
    sc,
    rc,
    Replay.ExcludeSeqs(seqs: [2]),
    "undo_2",
    "Undo call #2",
    "ada@local",
    t3
  ) is
    Ok(_)
  assert propose_selective_undo(
    files,
    path,
    sc,
    rc,
    Replay.ExcludeSeqs(seqs: [1]),
    "undo_1",
    "Undo call #1",
    "ada@local",
    t3
  ) is
    Ok(_)

  assert discard_undo_proposal(files, path, sc, "undo_1", "ada@local", t3) is Ok(disc) and
    disc.status == "discarded"

  admin_meta = Ledger.WriteMeta(
    principal: "ada@local",
    action: "replay.accept",
    reason: "revert mistake",
    at: t4
  )
  assert accept_undo_proposal(files, path, sc, "undo_2", admin_meta) is Ok(acc) and
    acc.status.starts_with?("accepted (tx ")

  # Item "a" remains; item "b" was selectively undone; proposals reflect accepted + discarded
  assert Modb.with_shared_lock(
    rf,
    path,
    fn(me) me.to_text end,
    fn(s) Table.get(s, items, "a").map_error(fn(te) te.to_text end) end
  ) ==
    Ok(Some(10))
  assert Modb.with_shared_lock(
    rf,
    path,
    fn(me) me.to_text end,
    fn(s) Table.get(s, items, "b").map_error(fn(te) te.to_text end) end
  ) ==
    Ok(None)

  snap2 = case collect_time_travel(rf, path, 25)
    Ok(s): s
    Error(_): stop "collect_time_travel after accept failed"
  end
  assert snap2.proposals.size == 2
end
