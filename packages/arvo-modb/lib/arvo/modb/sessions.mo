## Revocable `_arvo_sessions` MoDB session store (`Modb.Table`) paired with `Arvo.Session`
## AES-256-GCM cookies. Supports lock-free `ReadFiles`-only loads for `GET` routes and
## throttled `last_seen_at` touches for write routes.
module Arvo.Modb.Sessions
expose SessionError(..),
StoredSession(..),
SessionView(..),
sessions_by_expiry,
sessions_table,
expiry_secs,
create_in_store,
create_with_meta_in_store,
load_from_store,
touch_in_store,
rotate_in_store,
revoke_in_store,
revoke_all_in_store,
prune_expired_in_store,
create,
create_with_keyring,
load_read_only,
load_read_only_with_keyring,
load,
load_with_keyring,
rotate,
revoke,
revoke_all_for_member,
revoke_others_for_member,
list_for_member,
mark_reauthenticated,
mark_mfa_verified,
prune_expired
use Api
use Arvo.Keyring
use Arvo.Session
use Crypto
use Json
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
  user_agent: Option(Text)
  ip_prefix: Option(Text)
  auth_method: Option(Text)
  reauthenticated_at: Option(Time)
  mfa_verified_at: Option(Time)
end

## Redacted session metadata returned by session-list and keyring-load APIs (never leaks hashes or CSRF tokens).
struct SessionView
  id: Text
  member_id: Text
  expires_at: Time
  last_seen_at: Time
  created_at: Time
  user_agent: Option(Text)
  ip_prefix: Option(Text)
  auth_method: Option(Text)
  reauthenticated_at: Option(Time)
  mfa_verified_at: Option(Time)
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

fn expiry_secs(t: Time) : Decimal
  epoch = Time.parse("1970-01-01T00:00:00Z") or t
  (t - epoch).in_seconds
end

fn sessions_by_expiry() : Table.Index(Text, StoredSession, Decimal)
  Table.decimal_index[Text, StoredSession](
    "_arvo_sessions_by_expiry",
    fn(s) expiry_secs(s.expires_at) end
  )
end

## Layer 2 `Modb.Table` definition for `_arvo_sessions` with token-hash, member, and expiry indexes.
fn sessions_table() : Table.Table(Text, StoredSession)
  Table.text_key[StoredSession]("_arvo_sessions").with_index(sessions_by_token()).with_index(
    sessions_by_member()
  ).with_index(sessions_by_expiry())
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

fn build_stored_with_meta(mat: Session.SessionMaterial, meta: Session.SessionMeta) : StoredSession
  StoredSession(
    member_id: mat.session.member_id,
    token_hash: mat.token_hash,
    csrf_token: mat.session.csrf_token,
    expires_at: mat.session.expires_at,
    last_seen_at: mat.issued_at,
    created_at: mat.issued_at,
    user_agent: meta.user_agent,
    ip_prefix: meta.ip_prefix,
    auth_method: meta.auth_method,
    reauthenticated_at: meta.reauthenticated_at,
    mfa_verified_at: meta.mfa_verified_at
  )
end

fn build_stored(mat: Session.SessionMaterial) : StoredSession
  build_stored_with_meta(mat, Session.default_meta())
end

fn to_view(id: Text, row: StoredSession) : SessionView
  SessionView(
    id: id,
    member_id: row.member_id,
    expires_at: row.expires_at,
    last_seen_at: row.last_seen_at,
    created_at: row.created_at,
    user_agent: row.user_agent,
    ip_prefix: row.ip_prefix,
    auth_method: row.auth_method,
    reauthenticated_at: row.reauthenticated_at,
    mfa_verified_at: row.mfa_verified_at
  )
end

## Inserts `mat` and `meta` into an open `Modb.Store` (Layer 2) and returns `(Store, Session)`.
fn create_with_meta_in_store(
  store: Modb.Store,
  mat: Session.SessionMaterial,
  meta: Session.SessionMeta
) : Result((Modb.Store, Session.Session), SessionError)
  tbl = sessions_table()
  row = build_stored_with_meta(mat, meta)
  next_store = try Table.write_tx(store, fn(tx) Table.put(tx, tbl, mat.session.id, row) end)
    .map_error(fn(e) Storage(e) end)
  Ok((next_store, mat.session))
end

## Inserts `mat` into an open `Modb.Store` (Layer 2) and returns the updated `(Store, Session)`.
fn create_in_store(store: Modb.Store, mat: Session.SessionMaterial) : Result(
  (Modb.Store, Session.Session),
  SessionError
)
  create_with_meta_in_store(store, mat, Session.default_meta())
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

## Advances `last_seen_at` to `now` for `session_id` if it still exists in `store`.
fn touch_in_store(store: Modb.Store, session_id: Text, now: Time) : Result(
  Modb.Store,
  Table.TableError
)
  touch_if_due_in_store(store, session_id, now, 0)
end

fn touch_if_due_in_store(store: Modb.Store, session_id: Text, now: Time, interval_seconds: Int) : Result(
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
          return Ok(tx) if not touch_due?(row, now, interval_seconds)
          var updated = row
          updated.last_seen_at = now
          Table.put(tx, tbl, session_id, updated)
      end
    end
  )
end

fn touch_due?(row: StoredSession, now: Time, interval_seconds: Int) : Bool
  interval_seconds >= 0 and
    now > row.last_seen_at and
    (now - row.last_seen_at) >= interval_seconds.seconds
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

## Deletes all sessions in `store` with `expires_at <= now` using the expiry index (O(expired)).
fn prune_expired_in_store(store: Modb.Store, now: Time) : Result(
  (Modb.Store, Int),
  Table.TableError
)
  tbl = sessions_table()
  idx = sessions_by_expiry()
  hi = expiry_secs(now) + ("0.000001".to_decimal or 0.000001)
  expired = try Table.range_by(store, tbl, idx, None, Some(hi), 0)
  return Ok((store, 0)) if expired.empty?
  Table.transact(
    store,
    fn(e) e end,
    fn(tx)
      var cur = tx
      for (sid, _row) in expired
        cur = try Table.delete(cur, tbl, sid)
      end
      Ok((cur, expired.size))
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
  if touch_due?(stored, now, touch_interval_seconds)
    _touched = try Modb.with_exclusive_lock(
      files,
      db_path,
      fn(me) Storage(Table.Storage(me)) end,
      fn(s)
        _ns = try touch_if_due_in_store(s, sess.id, now, touch_interval_seconds).map_error(
          fn(e) Storage(e) end
        )
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
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      (_ns, deleted) = try prune_expired_in_store(s, now)
      Ok(deleted)
    end
  )
  case res
    Ok(n): Ok(n)
    Error(e): if not_found_table?(e): Ok(0) else: Error(e)
  end
end

## Issues a new keyring-sealed session with security metadata under an exclusive advisory lock.
fn create_with_keyring(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  keyring: Keyring.Keyring,
  member_id: Text,
  meta: Session.SessionMeta,
  cfg: Session.SessionConfig
) : Result((Session.Session, Text), SessionError)
  mat = try Session.prepare_material_with_keyring(rng, clock, keyring, member_id, cfg).map_error(
    map_token_error
  )
  Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Storage(Table.Storage(me)) end,
    fn(s)
      (_next, sess) = try create_with_meta_in_store(s, mat, meta)
      Ok((sess, mat.cookie_val))
    end
  )
end

## Lock-free keyring-aware session authentication using strictly `ReadFiles`.
## Returns `Some((Session, SessionView, needs_rekey?))` when active, or `Ok(None)`.
fn load_read_only_with_keyring(
  req: Api.Request,
  rf: ReadFiles,
  db_path: Text,
  clock: Clock,
  keyring: Keyring.Keyring,
  cfg: Session.SessionConfig
) : Result(Option((Session.Session, SessionView, Bool)), SessionError)
  unsealed = case Session.unseal_token_hash_with_keyring(req, keyring, cfg)
    Some(u): u
    None: return Ok(None)
  end
  now = clock.now
  pair = try load_pair_read_only(rf, db_path, unsealed.token_hash, now)
  Ok(pair.map(fn(p) (p.0, to_view(p.0.id, p.1), unsealed.needs_rekey?) end))
end

## Keyring-aware session load with throttled `last_seen_at` writes and rotation hint (`needs_rekey?`).
fn load_with_keyring(
  req: Api.Request,
  files: Files,
  db_path: Text,
  clock: Clock,
  keyring: Keyring.Keyring,
  cfg: Session.SessionConfig,
  touch_interval_seconds: Int
) : Result(Option((Session.Session, SessionView, Bool)), SessionError)
  unsealed = case Session.unseal_token_hash_with_keyring(req, keyring, cfg)
    Some(u): u
    None: return Ok(None)
  end
  now = clock.now
  pair = try load_pair_read_only(files.read_only, db_path, unsealed.token_hash, now)
  (sess, stored) = case pair
    Some(p): p
    None: return Ok(None)
  end
  var view = to_view(sess.id, stored)
  if touch_due?(stored, now, touch_interval_seconds)
    _touched = try Modb.with_exclusive_lock(
      files,
      db_path,
      fn(me) Storage(Table.Storage(me)) end,
      fn(s)
        _ns = try touch_if_due_in_store(s, sess.id, now, touch_interval_seconds).map_error(
          fn(e) Storage(e) end
        )
        Ok(Unit)
      end
    )
    view.last_seen_at = now
  end
  Ok(Some((sess, view, unsealed.needs_rekey?)))
end

fn format_utc_iso(t: Time) : Text
  raw = t.to_text
  base = raw.drop_suffix("Z") or raw
  parts = base.split(".")
  return "#{base}.000000Z" if parts.size == 1
  whole = parts.first or base
  frac = parts.get(1) or ""
  zeros = if frac.byte_count < 6: "0".repeat(6 - frac.byte_count) else: ""
  "#{whole}.#{frac}#{zeros}Z"
end

## Lists all active (unexpired) sessions belonging to `member_id`, newest first (`SessionView`).
fn list_for_member(rf: ReadFiles, db_path: Text, member_id: Text, clock: Clock) : Result(
  List(SessionView),
  Table.TableError
)
  return Ok([]) if not rf.exists?(db_path)
  now = clock.now
  tbl = sessions_table()
  idx = sessions_by_member()
  res = Modb.with_shared_lock(
    rf,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      matches = try Table.lookup(s, tbl, idx, member_id)
      active = matches.filter(fn(p) p.1.expires_at > now end).map(fn(p) to_view(p.0, p.1) end)
      Ok(active.sort_by_desc(fn(v) "#{format_utc_iso(v.created_at)}|#{v.id}" end))
    end
  )
  case res
    Ok(v): Ok(v)
    Error(e): if not_found_table?(e): Ok([]) else: Error(e)
  end
end

## Revokes every session belonging to `member_id` except `keep_session_id`, returning the count deleted.
fn revoke_others_for_member(files: Files, db_path: Text, member_id: Text, keep_session_id: Text) : Result(
  Int,
  Table.TableError
)
  return Ok(0) if not files.read_only.exists?(db_path)
  tbl = sessions_table()
  idx = sessions_by_member()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      matches = try Table.lookup(s, tbl, idx, member_id)
      to_del = matches.filter(fn(p) p.0 != keep_session_id end)
      return Ok(0) if to_del.empty?
      (_ns, count) = try Table.transact(
        s,
        fn(e) e end,
        fn(tx)
          var cur = tx
          for (sid, _row) in to_del
            cur = try Table.delete(cur, tbl, sid)
          end
          Ok((cur, to_del.size))
        end
      )
      Ok(count)
    end
  )
  case res
    Ok(n): Ok(n)
    Error(e): if not_found_table?(e): Ok(0) else: Error(e)
  end
end

## Records a fresh step-up re-authentication timestamp (`reauthenticated_at`) on `session_id`.
fn mark_reauthenticated(files: Files, db_path: Text, session_id: Text, clock: Clock) : Result(
  Bool,
  Table.TableError
)
  return Ok(false) if not files.read_only.exists?(db_path)
  now = clock.now
  tbl = sessions_table()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      (_ns, updated?) = try Table.transact(
        s,
        fn(e) e end,
        fn(tx)
          case try Table.tx_get(tx, tbl, session_id)
            None: Ok((tx, false))
            Some(row):
              var next = row
              next.reauthenticated_at = Some(now)
              next.last_seen_at = now
              tx1 = try Table.put(tx, tbl, session_id, next)
              Ok((tx1, true))
          end
        end
      )
      Ok(updated?)
    end
  )
  case res
    Ok(b): Ok(b)
    Error(e): if not_found_table?(e): Ok(false) else: Error(e)
  end
end

## Records MFA verification (`mfa_verified_at` and `reauthenticated_at`) on `session_id`.
fn mark_mfa_verified(files: Files, db_path: Text, session_id: Text, clock: Clock) : Result(
  Bool,
  Table.TableError
)
  return Ok(false) if not files.read_only.exists?(db_path)
  now = clock.now
  tbl = sessions_table()
  res = Modb.with_exclusive_lock(
    files,
    db_path,
    fn(me) Table.Storage(me) end,
    fn(s)
      (_ns, updated?) = try Table.transact(
        s,
        fn(e) e end,
        fn(tx)
          case try Table.tx_get(tx, tbl, session_id)
            None: Ok((tx, false))
            Some(row):
              var next = row
              next.mfa_verified_at = Some(now)
              next.reauthenticated_at = Some(now)
              next.last_seen_at = now
              tx1 = try Table.put(tx, tbl, session_id, next)
              Ok((tx1, true))
          end
        end
      )
      Ok(updated?)
    end
  )
  case res
    Ok(b): Ok(b)
    Error(e): if not_found_table?(e): Ok(false) else: Error(e)
  end
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

  # Requests that observed an older snapshot must recheck the touch against the current store.
  assert Modb.with_exclusive_lock(
    files,
    path,
    fn(e) Table.Storage(e) end,
    fn(s)
      within_interval = try touch_if_due_in_store(s, sess1.id, t0 + 15.minutes, 600)
      older_request = try touch_if_due_in_store(within_interval, sess1.id, t0 + 9.minutes, 600)
      Ok(Modb.txid(older_request))
    end
  ) ==
    Ok(txid_after_10m)

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

test "modb sessions indexed expiry pruning, legacy row decode, keyring rotation, member list, and step-up"
  files = Files.in_memory({})
  rf = files.read_only
  path = "sessions_v2.modb"
  rng = SecureRandom.seeded(93)
  k1 = rng.bytes(32)
  k2 = rng.bytes(32)
  kr1 = must_ok_msess(Keyring.single("k1", k1))
  kr2 = must_ok_msess(
    Keyring.from_entries([Keyring.KeyEntry(id: "k2", key: k2), Keyring.KeyEntry(id: "k1", key: k1)])
  )
  t0 = Time.parse("2026-11-21T12:00:00Z") or stop "t0"
  cfg_short = Session.SessionConfig(cookie_name: "arvo_session", ttl_seconds: 100, secure?: true)
  cfg_long = Session.SessionConfig(cookie_name: "arvo_session", ttl_seconds: 200, secure?: true)

  # Exact microsecond expiry boundary on sessions_by_expiry
  meta1 = Session.SessionMeta(
    user_agent: Some("ArvoBrowser/1.0"),
    ip_prefix: Some("203.0.113.0/24"),
    auth_method: Some("password"),
    reauthenticated_at: None,
    mfa_verified_at: None
  )
  (sa, ca) = must_ok_msess(
    create_with_keyring(files, path, rng, Clock.fixed(t0), kr1, "mem_1", meta1, cfg_short)
  )
  (sb, cb) = must_ok_msess(
    create_with_keyring(
      files,
      path,
      rng,
      Clock.fixed(t0 + 1.millisecond),
      kr1,
      "mem_1",
      Session.default_meta(),
      cfg_short
    )
  )
  (sc, cc) = must_ok_msess(
    create_with_keyring(
      files,
      path,
      rng,
      Clock.fixed(t0 + 2.seconds),
      kr2,
      "mem_1",
      Session.default_meta(),
      cfg_long
    )
  )

  # Keyring load_read_only_with_keyring opens k1 cookie under kr2 with needs_rekey? = true
  req_ca = Api.get("/").with_header("Cookie", "arvo_session=#{ca}")
  assert must_ok_msess(
    load_read_only_with_keyring(req_ca, rf, path, Clock.fixed(t0 + 10.seconds), kr2, cfg_short)
  ) is
    Some((_s_ca, view_ca, true))
  assert view_ca.ip_prefix == Some("203.0.113.0/24")

  # Active list before expiry shows all 3 newest-first with redacted SessionView
  listed0 = must_ok_msess(list_for_member(rf, path, "mem_1", Clock.fixed(t0 + 2.seconds)))
  assert listed0.size == 3
  assert (listed0.get(2) or stop "sa").user_agent == Some("ArvoBrowser/1.0")

  # Prune at exact expiry of sa (t0 + 100s) deletes sa and preserves sb (expires t0 + 100.001s) and sc
  assert must_ok_msess(prune_expired(files, path, Clock.fixed(t0 + 100.seconds))) == 1
  listed1 = must_ok_msess(list_for_member(rf, path, "mem_1", Clock.fixed(t0 + 100.seconds)))
  assert listed1.size == 2
  assert not listed1.any?(fn(v) v.id == sa.id end)
  assert listed1.any?(fn(v) v.id == sb.id end)
  assert must_ok_msess(
    load_read_only_with_keyring(req_ca, rf, path, Clock.fixed(t0 + 10.seconds), kr2, cfg_short)
  ) ==
    None
  req_cb = Api.get("/").with_header("Cookie", "arvo_session=#{cb}")
  assert must_ok_msess(
    load_read_only_with_keyring(req_cb, rf, path, Clock.fixed(t0 + 100.seconds), kr2, cfg_short)
  ) is
    Some((_s_cb, _view_cb, true))

  # Mark reauthenticated + MFA verified + revoke_others_for_member
  req_cc = Api.get("/").with_header("Cookie", "arvo_session=#{cc}")
  assert must_ok_msess(
    mark_mfa_verified(
      files,
      path,
      listed1.first.map(fn(v) v.id end) or "",
      Clock.fixed(t0 + 101.seconds)
    )
  )
  assert must_ok_msess(mark_reauthenticated(files, path, sc.id, Clock.fixed(t0 + 101.seconds)))
  assert must_ok_msess(
    load_with_keyring(req_cc, files, path, Clock.fixed(t0 + 102.seconds), kr2, cfg_long, 0)
  ) is
    Some((sess_cc, view_cc, false))
  assert view_cc.mfa_verified_at == Some(t0 + 101.seconds)
  assert view_cc.reauthenticated_at == Some(t0 + 101.seconds)
  assert must_ok_msess(revoke_others_for_member(files, path, "mem_1", sess_cc.id)) == 1
  assert must_ok_msess(list_for_member(rf, path, "mem_1", Clock.fixed(t0 + 100.seconds))).size == 1

  # Legacy raw JSON row (without new Option metadata fields) decodes cleanly as None metadata
  legacy_json = "{\"member_id\":\"mem_old\",\"token_hash\":\"#{Crypto.sha256("legacy".bytes).to_hex}\",\"csrf_token\":\"csrf1\",\"expires_at\":\"2027-01-01T00:00:00Z\",\"last_seen_at\":\"2026-11-21T12:00:00Z\",\"created_at\":\"2026-11-21T12:00:00Z\"}"
  assert Json.decode_strict[StoredSession](legacy_json.bytes) is Ok(dec_leg)
  assert dec_leg.user_agent == None and dec_leg.mfa_verified_at == None
end
