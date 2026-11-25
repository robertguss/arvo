## WRONG VERSION (strength/arvo_session/02_off_by_one_expiry.mo): Uses strict `<` instead of `<=` so sessions at exact expiry remain active.
## AES-256-GCM encrypted session cookies backed by revocable `arvo_sessions` rows in SQLite.
## Raw tokens never touch disk: SQLite stores only `Crypto.sha256(raw_token).to_hex`.
module Arvo.Session
expose Session(..),
SessionConfig(..),
SessionError(..),
default_config,
schema_sql,
init_schema,
create,
load,
rotate,
revoke,
revoke_all_for_member,
prune_expired,
attach_cookie,
clear_cookie
use Api
use Arvo.Cookie
use Crypto

default_ttl_seconds = 1209600

## Authenticated server-side session loaded for an incoming request.
struct Session
  id: Text
  member_id: Text
  csrf_token: Text
  expires_at: Time
end

## Cookie name, lifetime, and `Secure` policy for `Arvo.Session`.
struct SessionConfig
  cookie_name: Text
  ttl_seconds: Int
  secure?: Bool
end

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

## Default session configuration (`arvo_session`, 14-day TTL).
fn default_config(secure?: Bool) : SessionConfig
  examples
    default_config(true).cookie_name == "arvo_session"
    default_config(true).ttl_seconds == 1209600
    default_config(true).secure?
    not default_config(false).secure?
  end

  SessionConfig(cookie_name: "arvo_session", ttl_seconds: default_ttl_seconds, secure?: secure?)
end

## Returns `true` iff `key` is an exact 32-byte AES-256-GCM key.
fn valid_key?(key: Bytes) : Bool
  examples
    not valid_key?("".bytes)
    not valid_key?("0123456789012345678901234567890".bytes)
    valid_key?("01234567890123456789012345678901".bytes)
    not valid_key?("012345678901234567890123456789012".bytes)
  end

  key.size == 32
end

## Returns `true` when a session's `expires_at` timestamp is at or before `now`.
fn token_expired?(expires_at: Time, now: Time) : Bool
  examples
    case (Time.parse("2026-11-21T12:00:00Z"), Time.parse("2026-11-21T12:00:00Z"))
      (Some(exp), Some(now)): token_expired?(exp, now)
      (_, _): false
    end
    case (Time.parse("2026-11-21T11:59:59Z"), Time.parse("2026-11-21T12:00:00Z"))
      (Some(exp), Some(now)): token_expired?(exp, now)
      (_, _): false
    end
    case (Time.parse("2026-11-21T12:00:01Z"), Time.parse("2026-11-21T12:00:00Z"))
      (Some(exp), Some(now)): not token_expired?(exp, now)
      (_, _): false
    end
  end

  expires_at < now
end

table_ddl = "CREATE TABLE IF NOT EXISTS arvo_sessions (id TEXT PRIMARY KEY, member_id TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, csrf_token TEXT NOT NULL, expires_at TEXT NOT NULL, last_seen_at TEXT NOT NULL, created_at TEXT NOT NULL) STRICT"
index_ddl = "CREATE INDEX IF NOT EXISTS arvo_sessions_by_member ON arvo_sessions (member_id)"

## DDL creating `arvo_sessions` and its `member_id` index (ready for `Arvo.Migrations`).
fn schema_sql() : Text
  "#{table_ddl}; #{index_ddl};"
end

## Ensures `arvo_sessions` and its index exist on `db`.
fn init_schema(db: Sqlite.Database) : Result(Unit, SqliteError)
  try db.run(table_ddl, [])
  db.run(index_ddl, [])
end

fn session_aad(cookie_name: Text) : Bytes
  "arvo:session:#{cookie_name}".bytes
end

fn prepare_material(
  rng: SecureRandom,
  clock: Clock,
  key: Bytes,
  member_id: Text,
  cfg: SessionConfig
) : Result((Session, Text, Text, Time), SessionError)
  return Error(InvalidKey) if not valid_key?(key)
  session_id = "sess_#{rng.bytes(16).to_hex}"
  raw_token = rng.bytes(32)
  csrf_token = rng.bytes(32).to_base64url
  nonce = rng.bytes(12)
  token_hash = Crypto.sha256(raw_token).to_hex
  ciphertext = try Crypto.seal(key, nonce, raw_token, session_aad(cfg.cookie_name)).map_error(
    fn(e) CryptoFailed(e) end
  )
  cookie_val = Bytes.join([nonce, ciphertext]).to_base64url
  now = clock.now
  ttl = if cfg.ttl_seconds > 0: cfg.ttl_seconds else: 1
  expires_at = now + ttl.seconds
  sess = Session(
    id: session_id,
    member_id: member_id,
    csrf_token: csrf_token,
    expires_at: expires_at
  )
  Ok((sess, cookie_val, token_hash, now))
end

## Issues a new session in `arvo_sessions` and returns `(Session, sealed_cookie_value)`.
fn create(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  key: Bytes,
  member_id: Text,
  cfg: SessionConfig
) : Result((Session, Text), SessionError)
  (sess, cookie_val, token_hash, now) = try prepare_material(rng, clock, key, member_id, cfg)
  now_iso = now.to_text
  _ins = try db.execute(
    "INSERT INTO arvo_sessions (id, member_id, token_hash, csrf_token, expires_at, last_seen_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(sess.id),
      Sqlite.String(sess.member_id),
      Sqlite.String(token_hash),
      Sqlite.String(sess.csrf_token),
      Sqlite.String(sess.expires_at.to_text),
      Sqlite.String(now_iso),
      Sqlite.String(now_iso)
    ]
  ).map_error(fn(e) Database(e) end)
  Ok((sess, cookie_val))
end

## Authenticates the session cookie on `req`, verifies expiry and revocation in SQLite,
## updates `last_seen_at`, and fails closed (`Ok(None)`) on missing/tampered/expired/revoked cookies.
fn load(req: Api.Request, db: Sqlite.Database, clock: Clock, key: Bytes, cfg: SessionConfig) : Result(
  Option(Session),
  SessionError
)
  return Error(InvalidKey) if not valid_key?(key)
  raw_cookie = case Cookie.get(req, cfg.cookie_name)
    Some(c): c
    None: return Ok(None)
  end
  decoded = case Bytes.from_base64url(raw_cookie)
    Some(b): b
    None: return Ok(None)
  end
  return Ok(None) if decoded.size != 60
  nonce = decoded.slice(0, 12)
  ciphertext = decoded.slice(12, 60)
  raw_token = case Crypto.open(key, nonce, ciphertext, session_aad(cfg.cookie_name))
    Ok(pt): pt
    Error(_): return Ok(None)
  end
  return Ok(None) if raw_token.size != 32
  token_hash = Crypto.sha256(raw_token).to_hex
  rows = try db.query(
    "SELECT id, member_id, token_hash, csrf_token, expires_at FROM arvo_sessions WHERE token_hash = ?",
    [Sqlite.String(token_hash)]
  ).map_error(fn(e) Database(e) end)
  maybe_row = try Sqlite.decode_optional[StoredSessionRow](rows).map_error(fn(e) Decode(e) end)
  row = case maybe_row
    Some(r): r
    None: return Ok(None)
  end
  return Ok(None) if not Crypto.constant_time_eq?(row.token_hash.bytes, token_hash.bytes)
  now = clock.now
  return Ok(None) if token_expired?(row.expires_at, now)
  _upd = try db.execute(
    "UPDATE arvo_sessions SET last_seen_at = ? WHERE id = ?",
    [Sqlite.String(now.to_text), Sqlite.String(row.id)]
  ).map_error(fn(e) Database(e) end)
  Ok(
    Some(
      Session(
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
  cfg: SessionConfig
) : Result((Session, Text), SessionError)
  (sess, cookie_val, token_hash, now) = try prepare_material(rng, clock, key, member_id, cfg)
  plan = RotatePlan(
    old_session_id: old_session_id,
    new_session_id: sess.id,
    member_id: member_id,
    token_hash: token_hash,
    csrf_token: sess.csrf_token,
    expires_at_iso: sess.expires_at.to_text,
    now_iso: now.to_text
  )
  _tx = try Sqlite.transaction(db, plan, run_rotate_tx, fn(e) Database(e) end)
  Ok((sess, cookie_val))
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

## Attaches the `HttpOnly` session cookie to `res`.
fn attach_cookie(res: Api.Response, cookie_val: Text, cfg: SessionConfig) : Api.Response
  examples
    (attach_cookie(Api.no_content(), "v1", default_config(true)).header("Set-Cookie") or "").contains?(
      "HttpOnly"
    )
    (attach_cookie(Api.no_content(), "v1", default_config(true)).header("Set-Cookie") or "").contains?(
      "arvo_session=v1;"
    )
    (attach_cookie(Api.no_content(), "v1", default_config(true)).header("Set-Cookie") or "").contains?(
      "Max-Age=1209600"
    )
  end

  Cookie.set(res, cfg.cookie_name, cookie_val, Cookie.session_options(cfg.secure?, cfg.ttl_seconds))
end

## Appends a cookie-clearing `Set-Cookie` header for `cfg.cookie_name`.
fn clear_cookie(res: Api.Response, cfg: SessionConfig) : Api.Response
  examples
    (clear_cookie(Api.no_content(), default_config(true)).header("Set-Cookie") or "").starts_with?(
      "arvo_session=; Path=/; Max-Age=0"
    )
  end

  Cookie.clear(res, cfg.cookie_name, "/", cfg.secure?)
end
