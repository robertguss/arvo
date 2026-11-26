## Revocable `arvo_sessions` SQLite session store paired with `Arvo.Session` AES-256-GCM cookies.
## Raw tokens never touch disk: SQLite stores only `Crypto.sha256(raw_token).to_hex`.
module Arvo.Sqlite.Sessions
expose SessionError(..),
schema_sql,
init_schema,
create,
load,
rotate,
revoke,
revoke_all_for_member,
prune_expired
use Api
use Arvo.Session
use Crypto

## Errors arising from session creation, loading, or rotation (distinct from unauthenticated cookies).
enum SessionError
  InvalidKey
  Database(SqliteError)
  CryptoFailed(Crypto.CryptoError)
  Decode(Sqlite.SqliteDecodeError)
end

struct StoredSessionRow
  id: Text
  member_id: Text
  token_hash: Text
  csrf_token: Text
  expires_at: Time
end

struct RotatePlan
  old_session_id: Text
  new_session_id: Text
  member_id: Text
  token_hash: Text
  csrf_token: Text
  expires_at_iso: Text
  now_iso: Text
end

table_ddl = "CREATE TABLE IF NOT EXISTS arvo_sessions (id TEXT PRIMARY KEY, member_id TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, csrf_token TEXT NOT NULL, expires_at TEXT NOT NULL, last_seen_at TEXT NOT NULL, created_at TEXT NOT NULL) STRICT"
index_ddl = "CREATE INDEX IF NOT EXISTS arvo_sessions_by_member ON arvo_sessions (member_id)"

## DDL creating `arvo_sessions` and its `member_id` index (ready for `Arvo.Sqlite.Migrations`).
fn schema_sql() : Text
  "#{table_ddl}; #{index_ddl};"
end

## Ensures `arvo_sessions` and its index exist on `db`.
fn init_schema(db: Sqlite.Database) : Result(Unit, SqliteError)
  try db.run(table_ddl, [])
  db.run(index_ddl, [])
end

fn map_token_error(err: Session.TokenError) : SessionError
  case err
    Session.InvalidKey: InvalidKey
    Session.CryptoFailed(e): CryptoFailed(e)
  end
end

## Issues a new session in `arvo_sessions` and returns `(Session, sealed_cookie_value)`.
fn create(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  key: Bytes,
  member_id: Text,
  cfg: Session.SessionConfig
) : Result((Session.Session, Text), SessionError)
  mat = try Session.prepare_material(rng, clock, key, member_id, cfg).map_error(map_token_error)
  now_iso = mat.issued_at.to_text
  _ins = try db.execute(
    "INSERT INTO arvo_sessions (id, member_id, token_hash, csrf_token, expires_at, last_seen_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(mat.session.id),
      Sqlite.String(mat.session.member_id),
      Sqlite.String(mat.token_hash),
      Sqlite.String(mat.session.csrf_token),
      Sqlite.String(mat.session.expires_at.to_text),
      Sqlite.String(now_iso),
      Sqlite.String(now_iso)
    ]
  ).map_error(fn(e) Database(e) end)
  Ok((mat.session, mat.cookie_val))
end

## Authenticates the session cookie on `req`, verifies expiry and revocation in SQLite,
## updates `last_seen_at`, and fails closed (`Ok(None)`) on missing/tampered/expired/revoked cookies.
fn load(req: Api.Request, db: Sqlite.Database, clock: Clock, key: Bytes, cfg: Session.SessionConfig) : Result(
  Option(Session.Session),
  SessionError
)
  maybe_hash = try Session.unseal_token_hash(req, key, cfg).map_error(map_token_error)
  token_hash = case maybe_hash
    Some(h): h
    None: return Ok(None)
  end
  rows = try db.query(
    "SELECT id, member_id, token_hash, csrf_token, expires_at FROM arvo_sessions WHERE token_hash = ?",
    [Sqlite.String(token_hash)]
  ).map_error(fn(e) Database(e) end)
  maybe_row = try Sqlite.decode_optional[StoredSessionRow](rows).map_error(fn(e) Decode(e) end)
  row = case maybe_row
    Some(r): r
    None: return Ok(None)
  end
  now = clock.now
  return Ok(None) if not Session.verify_stored(row.token_hash, token_hash, row.expires_at, now)
  _upd = try db.execute(
    "UPDATE arvo_sessions SET last_seen_at = ? WHERE id = ?",
    [Sqlite.String(now.to_text), Sqlite.String(row.id)]
  ).map_error(fn(e) Database(e) end)
  Ok(
    Some(
      Session.Session(
        id: row.id,
        member_id: row.member_id,
        csrf_token: row.csrf_token,
        expires_at: row.expires_at
      )
    )
  )
end

fn run_rotate_tx(tx_db: Sqlite.Database, plan: RotatePlan) : Result(Unit, SessionError)
  _del = try tx_db.execute(
    "DELETE FROM arvo_sessions WHERE id = ?",
    [Sqlite.String(plan.old_session_id)]
  ).map_error(fn(e) Database(e) end)
  _ins = try tx_db.execute(
    "INSERT INTO arvo_sessions (id, member_id, token_hash, csrf_token, expires_at, last_seen_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(plan.new_session_id),
      Sqlite.String(plan.member_id),
      Sqlite.String(plan.token_hash),
      Sqlite.String(plan.csrf_token),
      Sqlite.String(plan.expires_at_iso),
      Sqlite.String(plan.now_iso),
      Sqlite.String(plan.now_iso)
    ]
  ).map_error(fn(e) Database(e) end)
  Ok(Unit)
end

## Atomically revokes `old_session_id` and creates a fresh session + sealed cookie for `member_id`.
fn rotate(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  key: Bytes,
  old_session_id: Text,
  member_id: Text,
  cfg: Session.SessionConfig
) : Result((Session.Session, Text), SessionError)
  mat = try Session.prepare_material(rng, clock, key, member_id, cfg).map_error(map_token_error)
  plan = RotatePlan(
    old_session_id: old_session_id,
    new_session_id: mat.session.id,
    member_id: member_id,
    token_hash: mat.token_hash,
    csrf_token: mat.session.csrf_token,
    expires_at_iso: mat.session.expires_at.to_text,
    now_iso: mat.issued_at.to_text
  )
  _tx = try Sqlite.transaction(db, plan, run_rotate_tx, fn(e) Database(e) end)
  Ok((mat.session, mat.cookie_val))
end

## Revokes a single session by `session_id`.
fn revoke(db: Sqlite.Database, session_id: Text) : Result(Unit, SqliteError)
  _exec = try db.execute("DELETE FROM arvo_sessions WHERE id = ?", [Sqlite.String(session_id)])
  Ok(Unit)
end

## Revokes every active session belonging to `member_id`, returning the count deleted.
fn revoke_all_for_member(db: Sqlite.Database, member_id: Text) : Result(Int, SqliteError)
  exec = try db.execute("DELETE FROM arvo_sessions WHERE member_id = ?", [Sqlite.String(member_id)])
  Ok(exec.changes)
end

## Deletes sessions whose `expires_at <= clock.now`, returning the count deleted.
fn prune_expired(db: Sqlite.Database, clock: Clock) : Result(Int, SqliteError)
  exec = try db.execute(
    "DELETE FROM arvo_sessions WHERE expires_at <= ?",
    [Sqlite.String(clock.now.to_text)]
  )
  Ok(exec.changes)
end

fn must_ok_session(res: Result(A, B)) : A
  case res
    Ok(v): v
    Error(_): stop "unexpected session test error"
  end
end

test "sqlite session create, load, AAD binding, rotation, expiry, and revocation"
  sql = Sqlite.in_memory()
  db = must_ok_session(sql.open("sessions.db"))
  _init = must_ok_session(init_schema(db))

  rng = SecureRandom.seeded(77)
  key = rng.bytes(32)
  wrong_key = rng.bytes(32)
  t0 = Time.parse("2026-11-21T12:00:00Z") or stop "t0"
  clock0 = Clock.fixed(t0)
  cfg = Session.SessionConfig(cookie_name: "arvo_session", ttl_seconds: 3600, secure?: true)

  assert create(db, rng, clock0, "short".bytes, "mem_1", cfg) == Error(InvalidKey)
  assert load(Api.get("/"), db, clock0, "short".bytes, cfg) == Error(InvalidKey)

  (sess1, cval1) = must_ok_session(create(db, rng, clock0, key, "mem_1", cfg))
  assert sess1.member_id == "mem_1"
  assert not sess1.csrf_token.empty?

  raw_rows = must_ok_session(
    db.query("SELECT token_hash FROM arvo_sessions WHERE id = ?", [Sqlite.String(sess1.id)])
  )
  assert raw_rows.rows.size == 1

  req1 = Api.get("/").with_header("Cookie", "arvo_session=#{cval1}")
  clock_later = Clock.fixed(t0 + 10.minutes)
  assert must_ok_session(load(req1, db, clock_later, key, cfg)) == Some(sess1)

  seen_rows = must_ok_session(
    db.query("SELECT last_seen_at FROM arvo_sessions WHERE id = ?", [Sqlite.String(sess1.id)])
  )
  assert seen_rows.rows == [[Sqlite.String((t0 + 10.minutes).to_text)]]

  assert must_ok_session(load(req1, db, clock_later, wrong_key, cfg)) == None
  other_cfg = Session.SessionConfig(cookie_name: "other_cookie", ttl_seconds: 3600, secure?: true)
  other_req = Api.get("/").with_header("Cookie", "other_cookie=#{cval1}")
  assert must_ok_session(load(other_req, db, clock_later, key, other_cfg)) == None
  tampered = Api.get("/").with_header(
    "Cookie",
    "arvo_session=AAAA#{cval1.drop_prefix("AAAA") or cval1}"
  )
  assert must_ok_session(load(tampered, db, clock_later, key, cfg)) == None

  clock_expired = Clock.fixed(t0 + 2.hours)
  assert must_ok_session(load(req1, db, clock_expired, key, cfg)) == None
  assert must_ok_session(prune_expired(db, clock_expired)) == 1

  (sess2, cval2) = must_ok_session(create(db, rng, clock0, key, "mem_1", cfg))
  (sess3, cval3) = must_ok_session(rotate(db, rng, clock0, key, sess2.id, "mem_1", cfg))
  assert sess3.id != sess2.id
  assert must_ok_session(
    load(Api.get("/").with_header("Cookie", "arvo_session=#{cval2}"), db, clock0, key, cfg)
  ) ==
    None
  assert must_ok_session(
    load(Api.get("/").with_header("Cookie", "arvo_session=#{cval3}"), db, clock0, key, cfg)
  ) ==
    Some(sess3)

  _s4 = must_ok_session(create(db, rng, clock0, key, "mem_1", cfg))
  assert must_ok_session(revoke_all_for_member(db, "mem_1")) == 2
  assert must_ok_session(
    load(Api.get("/").with_header("Cookie", "arvo_session=#{cval3}"), db, clock0, key, cfg)
  ) ==
    None

  (sess5, cval5) = must_ok_session(create(db, rng, clock0, key, "mem_2", cfg))
  res_attached = Session.attach_cookie(Api.no_content(), cval5, cfg)
  assert (res_attached.header("Set-Cookie") or "").starts_with?("arvo_session=")
  _rev = must_ok_session(revoke(db, sess5.id))
  assert must_ok_session(
    load(Api.get("/").with_header("Cookie", "arvo_session=#{cval5}"), db, clock0, key, cfg)
  ) ==
    None
  res_cleared = Session.clear_cookie(Api.no_content(), cfg)
  assert (res_cleared.header("Set-Cookie") or "").contains?("Max-Age=0")
end
