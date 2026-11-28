## Bridge between `Modb.Feeds` (persistent CoW-pinned O(diff) change feeds) and
## `Arvo.Live` / Mo's cross-worker `SseBroker`. Enables multi-worker live push and
## `ReadFiles`-only `Last-Event-ID` / `txid` catch-up respecting `Modb.Policy` clearances.
module Arvo.Modb.LiveFeeds
expose LiveFeedError(..),
to_text,
publish_commit,
publish_commit_and_reload,
feed_event_to_sse,
stream_feed_from_store,
stream_feed
use Api
use Arvo.Live
use Arvo.Sse
use Json
use Modb
use Modb.Feeds
use Modb.Ledger
use Modb.Policy
use Modb.Table

## Errors raised while streaming a MoDB reactive feed over SSE.
enum LiveFeedError
  LedgerFailure(Ledger.LedgerError)
  FeedFailure(Feeds.FeedError)
end

## Formats a `LiveFeedError` as a human-readable diagnostic.
fn to_text(err: LiveFeedError) : Text
  case err
    LedgerFailure(e): Ledger.to_text(e)
    FeedFailure(e): Feeds.to_text(e)
  end
end

fn change_op_text(op: Feeds.ChangeOp) : Text
  case op
    Feeds.OpAdded: "added"
    Feeds.OpModified: "modified"
    Feeds.OpRemoved: "removed"
  end
end

## Attaches `X-Mo-Sse-Publish` directives containing `Feeds.commit_signal_json` for every
## touched bucket topic (`"bucket:<name>"`), `"bucket:*"`, and any explicit app `extra_topics`.
fn publish_commit(
  res: Api.Response,
  txid: Int,
  touched_buckets: List(Text),
  action: Text,
  extra_topics: List(Text)
) : Api.Response
  signal = Feeds.commit_signal_json(txid, touched_buckets, action)
  var topics = touched_buckets.map(Feeds.bucket_topic).append("bucket:*").concat(extra_topics)
  var deduped = []
  for t in topics
    clean = Sse.sanitize_field_value(t).trim
    if not clean.empty? and not deduped.contains?(clean)
      deduped = deduped.append(clean)
    end
  end
  var out = res
  for topic in deduped
    out = Live.publish(out, topic, "modb.commit", signal)
  end
  out
end

## Combines `publish_commit` with `Live.invalidate_inertia` so subscribed React views
## immediately partial-reload `only_props` alongside receiving commit delta signals.
fn publish_commit_and_reload(
  res: Api.Response,
  txid: Int,
  touched_buckets: List(Text),
  action: Text,
  reload_topics: List(Text),
  only_props: List(Text)
) : Api.Response
  after_commit = publish_commit(res, txid, touched_buckets, action, [])
  Live.invalidate_inertia(after_commit, reload_topics, only_props, Some(action))
end

## Converts one `Modb.Feeds.FeedEvent` into an SSE `(Some("modb.delta"), json_text)` frame.
fn feed_event_to_sse(to_txid: Int, ev: Feeds.FeedEvent) : (Option(Text), Text)
  payload = Json.Object({
    "txid": Json.int(to_txid),
    "bucket": Json.String(ev.bucket),
    "op": Json.String(change_op_text(ev.op)),
    "key_hex": Json.String(ev.key_hex),
    "key_text": case ev.key_text
      Some(k): Json.String(k)
      None: Json.Null
    end,
    "old_value_text": case ev.old_value_text
      Some(v): Json.String(v)
      None: Json.Null
    end,
    "new_value_text": case ev.new_value_text
      Some(v): Json.String(v)
      None: Json.Null
    end
  })
  (Some("modb.delta"), payload.to_text)
end

fn build_stream_from_batch(
  req: Api.Request,
  topics: List(Text),
  batch: Feeds.FeedBatch,
  cfg: Live.LiveConfig
) : Api.Response
  var initial_frames = batch.events.map(fn(ev) feed_event_to_sse(batch.to_txid, ev) end)
  cursor_json = Json.Object({
    "feed_id": Json.String(batch.feed_id),
    "from_txid": Json.int(batch.from_txid),
    "to_txid": Json.int(batch.to_txid),
    "truncated": Json.Boolean(batch.truncated),
    "filtered_buckets": batch.filtered_buckets.to_json
  }).to_text
  initial_frames = initial_frames.append((Some("modb.cursor"), cursor_json))
  Live.stream(req, topics, initial_frames, cfg)
end

## Streams a reactive feed from an already-open read-only `Modb.Store`, emitting any
## clearance-filtered `O(diff)` catch-up events and subscribing to `Feeds.feed_subscribe_topics`.
fn stream_feed_from_store(
  req: Api.Request,
  store: Modb.Store,
  pol: Policy.SensitivityPolicy,
  feed_id: Text,
  is_admin: Bool,
  catchup_limit: Int,
  now: Time,
  cfg: Live.LiveConfig
) : Result(Api.Response, LiveFeedError)
  sub = try (try Feeds.get_feed(store, feed_id).map_error(fn(e) FeedFailure(e) end)).or_fail(
    FeedFailure(Feeds.FeedNotFound(id: feed_id))
  )
  batch = try Feeds.poll_feed(store, pol, feed_id, is_admin, catchup_limit, now).map_error(
    fn(e) FeedFailure(e) end
  )
  topics = Feeds.feed_subscribe_topics(sub)
  Ok(build_stream_from_batch(req, topics, batch, cfg))
end

## Strictly `ReadFiles`-only SSE endpoint handler for `GET` live feed routes:
## loads the CoW-pinned feed subscription, catches up missed diffs respecting `Modb.Policy`,
## and subscribes the response to `Feeds.feed_subscribe_topics`.
fn stream_feed(
  req: Api.Request,
  rf: ReadFiles,
  db_path: Text,
  schema: Ledger.Schema,
  pol: Policy.SensitivityPolicy,
  feed_id: Text,
  is_admin: Bool,
  catchup_limit: Int,
  now: Time,
  cfg: Live.LiveConfig
) : Result(Api.Response, LiveFeedError)
  if not rf.exists?(db_path)
    return Error(FeedFailure(Feeds.FeedNotFound(id: feed_id)))
  end
  (topics, batch) = try Ledger.read_locked(
    rf,
    db_path,
    schema,
    fn(e) LedgerFailure(e) end,
    fn(db)
      st = Ledger.store(db)
      sub = try (try Feeds.get_feed(st, feed_id).map_error(fn(e) FeedFailure(e) end)).or_fail(
        FeedFailure(Feeds.FeedNotFound(id: feed_id))
      )
      b = try Feeds.poll_feed(st, pol, feed_id, is_admin, catchup_limit, now).map_error(
        fn(e) FeedFailure(e) end
      )
      Ok((Feeds.feed_subscribe_topics(sub), b))
    end
  )
  Ok(build_stream_from_batch(req, topics, batch, cfg))
end

struct LiveNote
  title: Text
end

test "Arvo.Modb.LiveFeeds publishes commit signals and streams clearance-filtered O(diff) SSE catch-up"
  files = Files.in_memory({})
  rf = files.read_only
  path = "live_feeds.modb"
  t0 = Time.parse("2026-11-28T02:00:00Z") or stop "t0"
  sc = Ledger.schema(0).with_require_reason(false)
  pol = Policy.policy().with_bucket_sensitivity("vault", Policy.Secret)

  pub_tbl = Table.text_key[LiveNote]("notes")
  sec_tbl = Table.text_key[LiveNote]("vault")

  # Subscribe non-admin wildcard feed at baseline
  assert Ledger.init_locked(files, path, sc, t0) is Ok(_)
  sub = case Feeds.subscribe_locked(
    files,
    path,
    sc,
    Feeds.FeedSpec(
      id: "ui-feed",
      principal: "usr_1",
      grant_id: None,
      buckets: [],
      include_internal: false,
      from_beginning: false
    ),
    "subscribe ui",
    t0
  )
    Ok(s): s
    Error(_): stop "subscribe failed"
  end
  assert Feeds.feed_topic(sub.id) == "feed:ui-feed"

  # Write both a public note and a Secret vault record
  _w = Ledger.transact_locked(
    files,
    path,
    sc,
    Ledger.WriteMeta(principal: "usr_1", action: "notes.create", reason: "", at: t0),
    "add note + secret",
    Json.Null,
    fn(e) Ledger.to_text(e) end,
    fn(tx)
      t1 = try Table.put(tx, pub_tbl, "n_1", LiveNote(title: "Public Alert")).map_error(
        fn(e) e.to_text end
      )
      t2 = try Table.put(t1, sec_tbl, "s_1", LiveNote(title: "TOP_SECRET_KEY")).map_error(
        fn(e) e.to_text end
      )
      Ok((t2, Unit))
    end
  )

  # 1. Mutation publish attaches broker events + inertia reload directives
  mut_res = publish_commit_and_reload(
    Api.redirect_see_other("/"),
    2,
    ["notes", "vault"],
    "notes.create",
    [Live.user_topic("usr_1")],
    ["notes"]
  )
  evs = Sse.published_events(mut_res)
  assert evs.any?(fn(p) p.topic == "bucket:notes" and p.event == Some("modb.commit") end)
  assert evs.any?(fn(p) p.topic == "bucket:*" and p.event == Some("modb.commit") end)
  assert evs.any?(fn(p)
    p.topic == "user:usr_1" and p.event == Some("inertia.reload") and p.data.contains?("\"notes\"")
  end)

  # 2. Strictly ReadFiles stream_feed catches up public note while suppressing Secret bucket
  sse_res = case stream_feed(
    Api.get("/live/feed"),
    rf,
    path,
    sc,
    pol,
    "ui-feed",
    false,
    50,
    t0,
    Live.default_config()
  )
    Ok(r): r
    Error(_): stop "stream_feed failed"
  end
  assert sse_res.status == 200
  assert Sse.subscribed_topics(sse_res) == ["bucket:*", "feed:ui-feed"]
  assert sse_res.text.contains?("Public Alert")
  assert not sse_res.text.contains?("TOP_SECRET_KEY")
  assert sse_res.text.contains?("\"filtered_buckets\":[\"vault\"]")
end
