## Storage-agnostic session types and AES-256-GCM cookie sealing/unsealing primitives.
## Raw session tokens never touch disk: storage backends persist only `token_hash`.
module Arvo.Session
expose Session(..),
SessionConfig(..),
SessionMaterial(..),
TokenError(..),
default_config,
prepare_material,
unseal_token_hash,
verify_stored,
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

## Freshly generated session material including sealed cookie value and SHA-256 token digest.
struct SessionMaterial
  session: Session
  cookie_val: Text
  token_hash: Text
  issued_at: Time
end

## Errors arising from session key validation or AEAD cookie sealing/unsealing.
enum TokenError
  InvalidKey
  CryptoFailed(Crypto.CryptoError)
end

## Default session configuration (`arvo_session`, 14-day TTL).
fn default_config(secure?: Bool) : SessionConfig
  SessionConfig(cookie_name: "arvo_session", ttl_seconds: default_ttl_seconds, secure?: secure?)
end

fn session_aad(cookie_name: Text) : Bytes
  "arvo:session:#{cookie_name}".bytes
end

## Generates a fresh session ID, CSPRNG bearer token, CSRF token, SHA-256 token hash,
## and AAD-bound AES-256-GCM sealed cookie value.
fn prepare_material(
  rng: SecureRandom,
  clock: Clock,
  key: Bytes,
  member_id: Text,
  cfg: SessionConfig
) : Result(SessionMaterial, TokenError)
  return Error(InvalidKey) if key.size != 32
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
  Ok(SessionMaterial(session: sess, cookie_val: cookie_val, token_hash: token_hash, issued_at: now))
end

## Extracts, authenticates, and decrypts the session cookie on `req`, returning `Some(token_hash)`.
## Fails closed (`Ok(None)`) on missing, malformed, wrong-AAD, or tampered cookies.
fn unseal_token_hash(req: Api.Request, key: Bytes, cfg: SessionConfig) : Result(
  Option(Text),
  TokenError
)
  return Error(InvalidKey) if key.size != 32
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
  Ok(Some(Crypto.sha256(raw_token).to_hex))
end

## Verifies a stored session record's `token_hash` in constant time and ensures `expires_at > now`.
fn verify_stored(stored_token_hash: Text, expected_token_hash: Text, expires_at: Time, now: Time) : Bool
  Crypto.constant_time_eq?(stored_token_hash.bytes, expected_token_hash.bytes) and expires_at > now
end

## Attaches the `HttpOnly` session cookie to `res`.
fn attach_cookie(res: Api.Response, cookie_val: Text, cfg: SessionConfig) : Api.Response
  Cookie.set(res, cfg.cookie_name, cookie_val, Cookie.session_options(cfg.secure?, cfg.ttl_seconds))
end

## Appends a cookie-clearing `Set-Cookie` header for `cfg.cookie_name`.
fn clear_cookie(res: Api.Response, cfg: SessionConfig) : Api.Response
  Cookie.clear(res, cfg.cookie_name, "/", cfg.secure?)
end

test "session cookie sealing, AAD binding, tampering rejection, and expiry verification"
  rng = SecureRandom.seeded(77)
  key = rng.bytes(32)
  wrong_key = rng.bytes(32)
  t0 = Time.parse("2026-11-21T12:00:00Z") or stop "t0"
  clock0 = Clock.fixed(t0)
  cfg = SessionConfig(cookie_name: "arvo_session", ttl_seconds: 3600, secure?: true)

  assert prepare_material(rng, clock0, "short".bytes, "mem_1", cfg) == Error(InvalidKey)
  assert unseal_token_hash(Api.get("/"), "short".bytes, cfg) == Error(InvalidKey)

  mat = case prepare_material(rng, clock0, key, "mem_1", cfg)
    Ok(m): m
    Error(_): stop "prepare_material failed"
  end
  assert mat.session.member_id == "mem_1"
  assert not mat.session.csrf_token.empty?
  assert mat.token_hash.byte_count == 64

  req = Api.get("/").with_header("Cookie", "arvo_session=#{mat.cookie_val}")
  assert unseal_token_hash(req, key, cfg) == Ok(Some(mat.token_hash))
  assert unseal_token_hash(Api.get("/"), key, cfg) == Ok(None)
  assert unseal_token_hash(req, wrong_key, cfg) == Ok(None)

  other_cfg = SessionConfig(cookie_name: "other_cookie", ttl_seconds: 3600, secure?: true)
  other_req = Api.get("/").with_header("Cookie", "other_cookie=#{mat.cookie_val}")
  assert unseal_token_hash(other_req, key, other_cfg) == Ok(None)

  tampered = Api.get("/").with_header(
    "Cookie",
    "arvo_session=AAAA#{mat.cookie_val.drop_prefix("AAAA") or mat.cookie_val}"
  )
  assert unseal_token_hash(tampered, key, cfg) == Ok(None)

  assert verify_stored(mat.token_hash, mat.token_hash, mat.session.expires_at, t0 + 3599.seconds)
  assert not verify_stored(
    mat.token_hash,
    mat.token_hash,
    mat.session.expires_at,
    mat.session.expires_at
  )
  assert not verify_stored("bad_hash", mat.token_hash, mat.session.expires_at, t0)

  attached = attach_cookie(Api.no_content(), mat.cookie_val, cfg)
  assert (attached.header("Set-Cookie") or "").starts_with?("arvo_session=#{mat.cookie_val};")
  assert (attached.header("Set-Cookie") or "").contains?("HttpOnly")

  cleared = clear_cookie(Api.no_content(), cfg)
  assert (cleared.header("Set-Cookie") or "").contains?("arvo_session=; Path=/; Max-Age=0")
end
