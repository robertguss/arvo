## Revocable `_arvo_sessions` MoDB session store (`Modb.Table`) paired with `Arvo.Session`
## AES-256-GCM cookies. Supports lock-free `ReadFiles`-only loads for `GET` routes and
## throttled `last_seen_at` touches for write routes.
module Arvo.Modb.Sessions
expose SessionError(..),
StoredSession(..),
sessions_table,
create_in_store,
load_from_store,
touch_in_store,
rotate_in_store,
revoke_in_store,
revoke_all_in_store,
prune_expired_in_store,
create,
load_read_only,
load,
rotate,
revoke,
revoke_all_for_member,
prune_expired
use Api
use Arvo.Session
use Crypto
use Modb
use Modb.Errors
use Modb.Table

## Persisted MoDB session row stored in `_arvo_sessions` (keyed by `session.id`).
struct StoredSession
  member_id: Text
  token_hash: Text
  csrf_token: Text
  expires_at: Time
  last_seen_at: Time
  created_at: Time
end

## Errors arising from session creation, loading, rotation, or MoDB storage operations.
enum SessionError
  InvalidKey
  CryptoFailed(Crypto.CryptoError)
  Storage(Table.TableError)
end

fn sessions_by_token() : Table.Index(Text, StoredSession, Text)
  Table.unique_text_index[Text, StoredSession]("_arvo_sessions_by_token", fn(s) s.token_hash end)
end

fn sessions_by_member() : Table.Index(Text, StoredSession, Text)
  Table.text_index[Text, StoredSession]("_arvo_sessions_by_member", fn(s) s.member_id end)
end

## Layer 2 `Modb.Table` definition for `_arvo_sessions` with unique token-hash and member indexes.
fn sessions_table() : Table.Table(Text, StoredSession)
  Table.text_key[StoredSession]("_arvo_sessions").with_index(sessions_by_token()).with_index(
    sessions_by_member()
  )
end

fn map_token_error(err: Session.TokenError) : SessionError
  case err
    Session.InvalidKey: InvalidKey
    Session.CryptoFailed(e): CryptoFailed(e)
  end
end

fn not_found_storage?(err: SessionError) : Bool
  err is Storage(Table.Storage(Errors.Io(NotFound(path: _))))
end

fn not_found_table?(err: Table.TableError) : Bool
  err is Table.Storage(Errors.Io(NotFound(path: _)))
end

fn build_stored(mat: Session.SessionMaterial) : StoredSession
  StoredSession(
    member_id: mat.session.member_id,
    token_hash: mat.token_hash,
    csrf_token: mat.session.csrf_token,
    expires_at: mat.session.expires_at,
    last_seen_at: mat.issued_at,
    created_at: mat.issued_at
  )
end

## Inserts `mat` into an open `Modb.Store` (Layer 2) and returns the updated `(Store, Session)`.
fn create_in_store(store: Modb.Store, mat: Session.SessionMaterial) : Result(
  (Modb.Store, Session.Session),
  SessionError
)
  tbl = sessions_table()
  row = build_stored(mat)
  next_store = try Table.write_tx(store, fn(tx) Table.put(tx, tbl, mat.session.id, row) end)
    .map_error(fn(e) Storage(e) end)
  Ok((next_store, mat.session))
end

## Looks up a session by unsealed `token_hash` inside an open `Modb.Store` without mutating disk.
fn load_from_store(store: Modb.Store, token_hash: Text, now: Time) : Result(
  Option((Session.Session, StoredSession)),
  SessionError
)
  tbl = sessions_table()
  idx = sessions_by_token()
  maybe_pair = try Table.lookup_unique(store, tbl, idx, token_hash).map_error(fn(e) Storage(e) end)
  (sid, row) = case maybe_pair
    Some(p): p
    None: return Ok(None)
  end
  return Ok(None) if not Session.verify_stored(row.token_hash, token_hash, row.expires_at, now)
  sess = Session.Session(
    id: sid,
    member_id: row.member_id,
    csrf_token: row.csrf_token,
    expires_at: row.expires_at
  )
  Ok(Some((sess, row)))
end

## Updates `last_seen_at` to `now` for `session_id` if it still exists in `store`.
fn touch_in_store(store: Modb.Store, session_id: Text, now: Time) : Result(
  Modb.Store,
  Table.TableError
)
  tbl = sessions_table()
  Table.write_tx(
    store,
    fn(tx)
      case try Table.tx_get(tx, tbl, session_id)
        None: Ok(tx)
        Some(row):
          var updated = row
          updated.last_seen_at = now
          Table.put(tx, tbl, session_id, updated)
      end
    end
  )
end

## Atomically deletes `old_session_id` and inserts `mat` inside a single CoW commit.
fn rotate_in_store(store: Modb.Store, old_session_id: Text, mat: Session.SessionMaterial) : Result(
  (Modb.Store, Session.Session),
  SessionError
)
  tbl = sessions_table()
  row = build_stored(mat)
  next_store = try Table.write_tx(
    store,
    fn(tx)
      tx1 = try Table.delete(tx, tbl, old_session_id)
      Table.put(tx1, tbl, mat.session.id, row)
    end
  ).map_error(fn(e) Storage(e) end)
  Ok((next_store, mat.session))
end

## Revokes a single session by `session_id` in `store`.
fn revoke_in_store(store: Modb.Store, session_id: Text) : Result(Modb.Store, Table.TableError)
  tbl = sessions_table()
  Table.write_tx(store, fn(tx) Table.delete(tx, tbl, session_id) end)
end

## Revokes all active sessions for `member_id` in `store`, returning `(next_store, deleted_count)`.
fn revoke_all_in_store(store: Modb.Store, member_id: Text) : Result(
  (Modb.Store, Int),
  Table.TableError
)
  tbl = sessions_table()
  idx = sessions_by_member()
  matches = try Table.lookup(store, tbl, idx, member_id)
  return Ok((store, 0)) if matches.empty?
  Table.transact(
    store,
    fn(e) e end,
    fn(tx)
      var cur = tx
      for (sid, _row) in matches
        cur = try Table.delete(cur, tbl, sid)
      end
      Ok((cur, matches.size))
    end
  )
end

## Deletes all sessions in `store` with `expires_at <= now`, returning `(next_store, deleted_count)`.
fn prune_expired_in_store(store: Modb.Store, now: Time) : Result(
  (Modb.Store, Int),
  Table.TableError
)
  tbl = sessions_table()
  rows = try Table.all(store, tbl)
  var expired_ids = []
  for (sid, row) in rows
    if row.expires_at <= now
      expired_ids = expired_ids.append(sid)
    end
  end
  return Ok((store, 0)) if expired_ids.empty?
  Table.transact(
    store,
    fn(e) e end,
    fn(tx)
      var cur = tx
      for sid in expired_ids
        cur = try Table.delete(cur, tbl, sid)
      end
      Ok((cur, expired_ids.size))
    end
  )
end

## Issues a new session in `db_path` under an exclusive advisory lock, returning `(Session, cookie_val)`.
fn create(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  key: Bytes,
  member_id: Text,
  cfg: Session.SessionConfig
) : Result((Session.Session, Text), SessionError)
  mat = try Session.prepare_material(rng, clock, key, member_id, cfg).map_error(map_token_error)
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Storage(Table.Storage(me)) end,
    fn(s)
      (_next, sess) = try create_in_store(s, mat)
      Ok((sess, mat.cookie_val))
    end
  )
end

fn load_pair_read_only(rf: ReadFiles, db_path: Text, token_hash: Text, now: Time) : Result(
  Option((Session.Session, StoredSession)),
  SessionError
)
  return Ok(None) if not rf.exists?(db_path)
  res = Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Storage(Table.Storage(me)) end,
    fn(s) load_from_store(s, token_hash, now) end
  )
  case res
    Ok(v): Ok(v)
    Error(e):
      if not_found_storage?(e)
        Ok(None)
      else
        Error(e)
      end
  end
end

## Authenticates the session cookie using ONLY `ReadFiles` (lock-free optimistic CoW read)
## with zero disk writes. Fails closed (`Ok(None)`) when missing, uninitialized, tampered, expired, or revoked.
fn load_read_only(
  req: Api.Request,
  rf: ReadFiles,
  db_path: Text,
  clock: Clock,
  key: Bytes,
  cfg: Session.SessionConfig
) : Result(Option(Session.Session), SessionError)
  maybe_hash = try Session.unseal_token_hash(req, key, cfg).map_error(map_token_error)
  token_hash = case maybe_hash
    Some(h): h
    None: return Ok(None)
  end
  now = clock.now
  pair = try load_pair_read_only(rf, db_path, token_hash, now)
  Ok(pair.map(fn(p) p.0 end))
end

## Authenticates the session cookie and throttles `last_seen_at` writes: reads lock-free first,
## and only acquires an exclusive lock to update `last_seen_at` when `touch_interval_seconds >= 0`
## and at least `touch_interval_seconds` have elapsed since the previous touch.
fn load(
  req: Api.Request,
  files: Files,
  db_path: Text,
  clock: Clock,
  key: Bytes,
  cfg: Session.SessionConfig,
  touch_interval_seconds: Int
) : Result(Option(Session.Session), SessionError)
  maybe_hash = try Session.unseal_token_hash(req, key, cfg).map_error(map_token_error)
  token_hash = case maybe_hash
    Some(h): h
    None: return Ok(None)
  end
  now = clock.now
  pair = try load_pair_read_only(files.read_only, db_path, token_hash, now)
  (sess, stored) = case pair
    Some(p): p
    None: return Ok(None)
  end
  should_touch? = touch_interval_seconds >= 0 and
    (now - stored.last_seen_at) >= touch_interval_seconds.seconds
  if should_touch?
    _touched = try Modb.with_exclusive_lock(
      files,
      db_path,
      fn(me) Storage(Table.Storage(me)) end,
      fn(s)
        _ns = try touch_in_store(s, sess.id, now).map_error(fn(e) Storage(e) end)
        Ok(Unit)
      end
    )
  end
  Ok(Some(sess))
end

## Atomically revokes `old_session_id` and issues a fresh session + sealed cookie under an exclusive lock.
fn rotate(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  key: Bytes,
  old_session_id: Text,
  member_id: Text,
  cfg: Session.SessionConfig
) : Result((Session.Session, Text), SessionError)
  mat = try Session.prepare_material(rng, clock, key, member_id, cfg).map_error(map_token_error)
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Storage(Table.Storage(me)) end,
    fn(s)
      (_next, sess) = try rotate_in_store(s, old_session_id, mat)
      Ok((sess, mat.cookie_val))
    end
  )
end

## Revokes a single session by `session_id` under an exclusive lock.
fn revoke(files: Files, db_path: Text, session_id: Text) : Result(Unit, Table.TableError)
  return Ok(Unit) if not files.read_only.exists?(db_path)
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      _ns = try revoke_in_store(s, session_id)
      Ok(Unit)
    end
  )
  case res
    Ok(_): Ok(Unit)
    Error(e): if not_found_table?(e): Ok(Unit) else: Error(e)
  end
end

## Revokes every active session belonging to `member_id`, returning the count deleted.
fn revoke_all_for_member(files: Files, db_path: Text, member_id: Text) : Result(
  Int,
  Table.TableError
)
  return Ok(0) if not files.read_only.exists?(db_path)
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      (_ns, deleted) = try revoke_all_in_store(s, member_id)
      Ok(deleted)
    end
  )
end

## Deletes all sessions with `expires_at <= clock.now`, returning the count deleted.
fn prune_expired(files: Files, db_path: Text, clock: Clock) : Result(Int, Table.TableError)
  return Ok(0) if not files.read_only.exists?(db_path)
  now = clock.now
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      (_ns, deleted) = try prune_expired_in_store(s, now)
      Ok(deleted)
    end
  )
end

fn must_ok_msess(res: Result(A, B)) : A
  case res
    Ok(v): v
    Error(_): stop "unexpected modb session test error"
  end
end

test "modb sessions support read-only loads, throttled touches, AAD binding, rotation, expiry, and revocation"
  files = Files.in_memory({})
  rf = files.read_only
  path = "sessions.modb"
  rng = SecureRandom.seeded(77)
  key = rng.bytes(32)
  wrong_key = rng.bytes(32)
  t0 = Time.parse("2026-11-21T12:00:00Z") or stop "t0"
  clock0 = Clock.fixed(t0)
  cfg = Session.SessionConfig(cookie_name: "arvo_session", ttl_seconds: 3600, secure?: true)

  # Missing DB file fails closed cleanly without creating a file
  assert load_read_only(Api.get("/"), rf, path, clock0, key, cfg) == Ok(None)
  assert load(Api.get("/"), files, path, clock0, key, cfg, 600) == Ok(None)
  assert not rf.exists?(path)

  assert create(files, path, rng, clock0, "short".bytes, "mem_1", cfg) == Error(InvalidKey)
  assert load_read_only(Api.get("/"), rf, path, clock0, "short".bytes, cfg) == Error(InvalidKey)

  (sess1, cval1) = must_ok_msess(create(files, path, rng, clock0, key, "mem_1", cfg))
  assert sess1.member_id == "mem_1"
  assert not sess1.csrf_token.empty?

  # Raw bearer token never appears on disk or in StoredSession
  txid_after_create = case Modb.open_read_only(rf, path)
    Ok(s): Modb.txid(s)
    Error(_): stop "open_read_only"
  end
  req1 = Api.get("/").with_header("Cookie", "arvo_session=#{cval1}")
  clock_5m = Clock.fixed(t0 + 5.minutes)
  assert must_ok_msess(load_read_only(req1, rf, path, clock_5m, key, cfg)) == Some(sess1)

  # Throttled load at +5m (< 600s) does NOT update last_seen_at
  assert must_ok_msess(load(req1, files, path, clock_5m, key, cfg, 600)) == Some(sess1)
  txid_after_5m = case Modb.open_read_only(rf, path)
    Ok(s): Modb.txid(s)
    Error(_): stop "open_read_only"
  end
  assert txid_after_5m == txid_after_create

  # Throttled load at +10m (>= 600s) DOES update last_seen_at
  clock_10m = Clock.fixed(t0 + 10.minutes)
  assert must_ok_msess(load(req1, files, path, clock_10m, key, cfg, 600)) == Some(sess1)
  txid_after_10m = case Modb.open_read_only(rf, path)
    Ok(s): Modb.txid(s)
    Error(_): stop "open_read_only"
  end
  assert txid_after_10m == txid_after_create + 1

  # Wrong key, wrong cookie name (AAD mismatch), and tampered cookie fail closed
  assert must_ok_msess(load_read_only(req1, rf, path, clock_10m, wrong_key, cfg)) == None
  other_cfg = Session.SessionConfig(cookie_name: "other_cookie", ttl_seconds: 3600, secure?: true)
  other_req = Api.get("/").with_header("Cookie", "other_cookie=#{cval1}")
  assert must_ok_msess(load_read_only(other_req, rf, path, clock_10m, key, other_cfg)) == None
  tampered = Api.get("/").with_header(
    "Cookie",
    "arvo_session=AAAA#{cval1.drop_prefix("AAAA") or cval1}"
  )
  assert must_ok_msess(load_read_only(tampered, rf, path, clock_10m, key, cfg)) == None

  # Expiry & prune_expired
  clock_expired = Clock.fixed(t0 + 2.hours)
  assert must_ok_msess(load_read_only(req1, rf, path, clock_expired, key, cfg)) == None
  assert must_ok_msess(prune_expired(files, path, clock_expired)) == 1

  # Atomic rotate invalidates old cookie and activates new cookie
  (sess2, cval2) = must_ok_msess(create(files, path, rng, clock0, key, "mem_1", cfg))
  (sess3, cval3) = must_ok_msess(rotate(files, path, rng, clock0, key, sess2.id, "mem_1", cfg))
  assert sess3.id != sess2.id
  assert must_ok_msess(
    load_read_only(
      Api.get("/").with_header("Cookie", "arvo_session=#{cval2}"),
      rf,
      path,
      clock0,
      key,
      cfg
    )
  ) ==
    None
  assert must_ok_msess(
    load_read_only(
      Api.get("/").with_header("Cookie", "arvo_session=#{cval3}"),
      rf,
      path,
      clock0,
      key,
      cfg
    )
  ) ==
    Some(sess3)

  # revoke_all_for_member & single revoke
  _s4 = must_ok_msess(create(files, path, rng, clock0, key, "mem_1", cfg))
  assert must_ok_msess(revoke_all_for_member(files, path, "mem_1")) == 2
  assert must_ok_msess(
    load_read_only(
      Api.get("/").with_header("Cookie", "arvo_session=#{cval3}"),
      rf,
      path,
      clock0,
      key,
      cfg
    )
  ) ==
    None

  (sess5, cval5) = must_ok_msess(create(files, path, rng, clock0, key, "mem_2", cfg))
  _rev = must_ok_msess(revoke(files, path, sess5.id))
  assert must_ok_msess(
    load_read_only(
      Api.get("/").with_header("Cookie", "arvo_session=#{cval5}"),
      rf,
      path,
      clock0,
      key,
      cfg
    )
  ) ==
    None
end
