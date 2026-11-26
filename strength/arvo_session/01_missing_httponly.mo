## WRONG VERSION (strength/arvo_session/01_missing_httponly.mo): Omits HttpOnly flag on session cookie.
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

  expires_at <= now
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
  Ok(SessionMaterial(session: sess, cookie_val: cookie_val, token_hash: token_hash, issued_at: now))
end

## Extracts, authenticates, and decrypts the session cookie on `req`, returning `Some(token_hash)`.
## Fails closed (`Ok(None)`) on missing, malformed, wrong-AAD, or tampered cookies.
fn unseal_token_hash(req: Api.Request, key: Bytes, cfg: SessionConfig) : Result(
  Option(Text),
  TokenError
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
  Ok(Some(Crypto.sha256(raw_token).to_hex))
end

## Verifies a stored session record's `token_hash` in constant time and ensures `expires_at > now`.
fn verify_stored(stored_token_hash: Text, expected_token_hash: Text, expires_at: Time, now: Time) : Bool
  Crypto.constant_time_eq?(stored_token_hash.bytes, expected_token_hash.bytes) and
    not token_expired?(expires_at, now)
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

  Cookie.set(
    res,
    cfg.cookie_name,
    cookie_val,
    Cookie.CookieOptions(path: "/", max_age: Some(cfg.ttl_seconds), http_only?: false, secure?: cfg.secure?, same_site: Cookie.Lax)
  )
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
