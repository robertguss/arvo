## Storage-agnostic session types and AES-256-GCM cookie sealing/unsealing primitives.
## Raw session tokens never touch disk: storage backends persist only `token_hash`.
module Arvo.Session
expose Session(..),
SessionConfig(..),
SessionMaterial(..),
SessionMeta(..),
SessionPolicy(..),
UnsealedToken(..),
TokenError(..),
default_config,
default_meta,
default_policy,
within_idle?,
needs_step_up?,
prepare_material,
prepare_material_with_keyring,
unseal_token_hash,
unseal_token_hash_with_keyring,
rekey_cookie_if_needed,
verify_stored,
attach_cookie,
clear_cookie
use Api
use Arvo.Cookie
use Arvo.Keyring
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

## Optional security metadata captured when creating or elevating a session.
struct SessionMeta
  user_agent: Option(Text)
  ip_prefix: Option(Text)
  auth_method: Option(Text)
  reauthenticated_at: Option(Time)
  mfa_verified_at: Option(Time)
end

## Configurable absolute, idle, and step-up authentication lifetimes for sessions.
struct SessionPolicy
  absolute_ttl_seconds: Int
  idle_ttl_seconds: Option(Int)
  step_up_window_seconds: Int
end

## Decoded session token hash alongside keyring rotation metadata.
struct UnsealedToken
  token_hash: Text
  key_id: Text
  needs_rekey?: Bool
end

## Empty session metadata with no user-agent, IP prefix, or elevation timestamps.
fn default_meta() : SessionMeta
  SessionMeta(
    user_agent: None,
    ip_prefix: None,
    auth_method: None,
    reauthenticated_at: None,
    mfa_verified_at: None
  )
end

## Default session policy: 14-day absolute TTL, 7-day idle timeout, 15-minute step-up window.
fn default_policy() : SessionPolicy
  SessionPolicy(
    absolute_ttl_seconds: 1209600,
    idle_ttl_seconds: Some(604800),
    step_up_window_seconds: 900
  )
end

## True when `last_seen_at` has not exceeded `policy.idle_ttl_seconds` at `now`.
fn within_idle?(last_seen_at: Time, now: Time, policy: SessionPolicy) : Bool
  case policy.idle_ttl_seconds
    None: true
    Some(idle_secs):
      eff = if idle_secs > 0: idle_secs else: 1
      (last_seen_at + eff.seconds) > now
  end
end

## True when fresh re-authentication is required before performing sensitive actions.
fn needs_step_up?(reauthenticated_at: Option(Time), now: Time, policy: SessionPolicy) : Bool
  case reauthenticated_at
    None: true
    Some(at):
      win = if policy.step_up_window_seconds > 0: policy.step_up_window_seconds else: 0
      (at + win.seconds) <= now
  end
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
    (attach_cookie(Api.no_content(), "v1", default_config(true)).header("Set-Cookie") or "")
      .contains?("HttpOnly")
    (attach_cookie(Api.no_content(), "v1", default_config(true)).header("Set-Cookie") or "")
      .contains?("arvo_session=v1;")
    (attach_cookie(Api.no_content(), "v1", default_config(true)).header("Set-Cookie") or "")
      .contains?("Max-Age=1209600")
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

## Clears/clears cookie helper above, plus Keyring-backed multi-key rotation helpers.
fn map_keyring_error(err: Keyring.KeyringError) : TokenError
  case err
    Keyring.CryptoFailed(e): CryptoFailed(e)
    Keyring.EmptyKeyring | Keyring.InvalidKeyId(id: _) | Keyring.DuplicateKeyId(id: _) | Keyring
      .InvalidKeyLength(id: _, size: _) | Keyring.MissingEnvVar(name: _) | Keyring.InvalidEnvFormat(
        reason: _
      ): InvalidKey
  end
end

## Generates a fresh session sealed under `keyring.primary_id` (`v2.<kid>.<b64>`).
fn prepare_material_with_keyring(
  rng: SecureRandom,
  clock: Clock,
  keyring: Keyring.Keyring,
  member_id: Text,
  cfg: SessionConfig
) : Result(SessionMaterial, TokenError)
  session_id = "sess_#{rng.bytes(16).to_hex}"
  raw_token = rng.bytes(32)
  csrf_token = rng.bytes(32).to_base64url
  token_hash = Crypto.sha256(raw_token).to_hex
  cookie_val = try Keyring.seal(rng, keyring, raw_token, session_aad(cfg.cookie_name)).map_error(
    map_keyring_error
  )
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

## Unseals either a `v2.<kid>.<b64>` cookie or a legacy raw cookie using `keyring`.
fn unseal_token_hash_with_keyring(req: Api.Request, keyring: Keyring.Keyring, cfg: SessionConfig) : Option(
  UnsealedToken
)
  raw_cookie = case Cookie.get(req, cfg.cookie_name)
    Some(c): c
    None: return None
  end
  opened = case Keyring.open(keyring, raw_cookie, session_aad(cfg.cookie_name))
    Some(o): o
    None: return None
  end
  return None if opened.plaintext.size != 32
  Some(
    UnsealedToken(
      token_hash: Crypto.sha256(opened.plaintext).to_hex,
      key_id: opened.key_id,
      needs_rekey?: opened.needs_rekey?
    )
  )
end

## Re-seals the incoming session cookie under `keyring.primary_id` when decrypted with a non-primary
## or legacy key, returning `Some(new_cookie_val)` for transparent cookie rotation.
fn rekey_cookie_if_needed(
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  req: Api.Request,
  cfg: SessionConfig
) : Option(Text)
  raw_cookie = case Cookie.get(req, cfg.cookie_name)
    Some(c): c
    None: return None
  end
  opened = case Keyring.open(keyring, raw_cookie, session_aad(cfg.cookie_name))
    Some(o): o
    None: return None
  end
  return None if not opened.needs_rekey? or opened.plaintext.size != 32
  case Keyring.seal(rng, keyring, opened.plaintext, session_aad(cfg.cookie_name))
    Ok(new_cookie): Some(new_cookie)
    Error(_): None
  end
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

test "session keyring rotation, transparent rekey, idle window, and step-up checks"
  rng = SecureRandom.seeded(92)
  k1 = rng.bytes(32)
  k2 = rng.bytes(32)
  kr1 = case Keyring.single("k1", k1)
    Ok(k): k
    Error(_): stop "kr1"
  end
  kr2 = case Keyring.from_entries([
    Keyring.KeyEntry(id: "k2", key: k2),
    Keyring.KeyEntry(id: "k1", key: k1)
  ])
    Ok(k): k
    Error(_): stop "kr2"
  end
  t0 = Time.parse("2026-11-21T12:00:00Z") or stop "t0"
  clock0 = Clock.fixed(t0)
  cfg = default_config(true)

  # Policy helpers
  pol = default_policy()
  assert default_meta().user_agent == None
  assert within_idle?(t0, t0 + 6.days, pol)
  assert not within_idle?(t0, t0 + 7.days, pol)
  assert within_idle?(
    t0,
    t0 + 30.days,
    SessionPolicy(absolute_ttl_seconds: 100, idle_ttl_seconds: None, step_up_window_seconds: 60)
  )
  assert needs_step_up?(None, t0, pol)
  assert not needs_step_up?(Some(t0), t0 + 899.seconds, pol)
  assert needs_step_up?(Some(t0), t0 + 900.seconds, pol)

  # Keyring seal + rotation + transparent rekey
  mat1 = case prepare_material_with_keyring(rng, clock0, kr1, "mem_1", cfg)
    Ok(m): m
    Error(_): stop "prepare kr1"
  end
  assert mat1.cookie_val.starts_with?("v2.k1.")
  req1 = Api.get("/").with_header("Cookie", "arvo_session=#{mat1.cookie_val}")
  assert unseal_token_hash_with_keyring(req1, kr1, cfg) ==
    Some(UnsealedToken(token_hash: mat1.token_hash, key_id: "k1", needs_rekey?: false))
  assert rekey_cookie_if_needed(rng, kr1, req1, cfg) == None

  assert unseal_token_hash_with_keyring(req1, kr2, cfg) ==
    Some(UnsealedToken(token_hash: mat1.token_hash, key_id: "k1", needs_rekey?: true))
  rekeyed = rekey_cookie_if_needed(rng, kr2, req1, cfg) or stop "expected rekeyed cookie"
  assert rekeyed.starts_with?("v2.k2.")
  req2 = Api.get("/").with_header("Cookie", "arvo_session=#{rekeyed}")
  assert unseal_token_hash_with_keyring(req2, kr2, cfg) ==
    Some(UnsealedToken(token_hash: mat1.token_hash, key_id: "k2", needs_rekey?: false))

  # Legacy single-key cookie unseals via keyring and requests rekey
  leg_mat = case prepare_material(rng, clock0, k1, "mem_leg", cfg)
    Ok(m): m
    Error(_): stop "prepare legacy"
  end
  leg_req = Api.get("/").with_header("Cookie", "arvo_session=#{leg_mat.cookie_val}")
  assert unseal_token_hash_with_keyring(leg_req, kr2, cfg) ==
    Some(UnsealedToken(token_hash: leg_mat.token_hash, key_id: "k1", needs_rekey?: true))
  leg_rekey = rekey_cookie_if_needed(rng, kr2, leg_req, cfg) or stop "expected legacy rekey"
  assert leg_rekey.starts_with?("v2.k2.")
end
