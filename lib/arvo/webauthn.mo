## Pure-Mo WebAuthn Level 2 Passkey verifier: bounded CBOR decoder, COSE ES256/Ed25519
## public key parser, Keyring-sealed challenge cookies, registration, and assertion checks.
module Arvo.Webauthn
expose PasskeyAlg(..),
WebAuthnError(..),
WebAuthnConfig(..),
CborVal(..),
ParsedCoseKey(..),
ParsedAuthData(..),
RegisteredPasskey(..),
AssertionOutcome(..),
alg_to_text,
alg_from_text,
to_text,
default_config,
validate_config,
decode_cbor,
parse_cose_public_key,
parse_auth_data,
attach_challenge_cookie,
clear_challenge_cookie,
begin_registration,
finish_registration,
begin_authentication,
finish_authentication
use Api
use Arvo.Cookie
use Arvo.Keyring
use Crypto
use Json

## Asymmetric passkey signature algorithms verified via `Crypto.verify_signature`.
enum PasskeyAlg
  Es256
  Ed25519
end

## Structured failure codes from configuration, CBOR/COSE parsing, or WebAuthn verification.
enum WebAuthnError
  InvalidConfig(reason: Text)
  BadCbor(reason: Text)
  BadCoseKey(reason: Text)
  BadAuthData(reason: Text)
  MissingChallengeCookie
  InvalidChallengeCookie
  ChallengeExpired
  PurposeMismatch
  TypeMismatch(got: Text)
  OriginMismatch(got: Text)
  RpIdMismatch
  ChallengeMismatch
  UserPresenceRequired
  UserVerificationRequired
  MissingAttestedCredential
  UnsupportedCredentialAlg
  InvalidSignature
  ClonedAuthenticator(stored: Int, got: Int)
  CryptoFailed(Crypto.CryptoError)
end

## Relying Party configuration and challenge cookie policy.
struct WebAuthnConfig
  rp_id: Text
  rp_name: Text
  allowed_origins: List(Text)
  cookie_name: Text
  challenge_ttl_seconds: Int
  require_user_verification?: Bool
  secure_cookie?: Bool
end

## Decoded CBOR value produced by the bounded WebAuthn parser.
enum CborVal
  CborInt(Int)
  CborBytes(Bytes)
  CborText(Text)
  CborArray(List(CborVal))
  CborMap(List((CborVal, CborVal)))
  CborBool(Bool)
  CborNull
end

## Parsed COSE public key ready for `Crypto.verify_signature`.
struct ParsedCoseKey
  alg: PasskeyAlg
  public_key: Bytes
end

## Decoded WebAuthn authenticator data flags, counters, and optional attested credential.
struct ParsedAuthData
  rp_id_hash: Bytes
  flags: Int
  user_present?: Bool
  user_verified?: Bool
  backup_eligible?: Bool
  backup_state?: Bool
  attested_credential?: Bool
  sign_count: Int
  aaguid: Option(Bytes)
  credential_id: Option(Bytes)
  cose_key: Option(ParsedCoseKey)
end

## Stored passkey credential returned by `finish_registration`.
struct RegisteredPasskey
  credential_id: Text
  public_key_b64url: Text
  alg: PasskeyAlg
  sign_count: Int
  aaguid_hex: Text
  backed_up?: Bool
end

## Verified login assertion outcome containing updated monotonic `sign_count`.
struct AssertionOutcome
  credential_id: Text
  new_sign_count: Int
  user_verified?: Bool
  backed_up?: Bool
end

struct SealedChallenge
  purpose: Text
  challenge: Text
  user_id: Option(Text)
  issued_at: Time
  expires_at: Time
end

## Serializes `PasskeyAlg` to canonical lowercase text (`"es256"` / `"ed25519"`).
fn alg_to_text(alg: PasskeyAlg) : Text
  case alg
    Es256: "es256"
    Ed25519: "ed25519"
  end
end

## Parses a canonical `PasskeyAlg` string.
fn alg_from_text(raw: Text) : Option(PasskeyAlg)
  norm = raw.trim.ascii_lowercase
  if norm == "es256"
    Some(Es256)
  else if norm == "ed25519"
    Some(Ed25519)
  else
    None
  end
end

## Formats a `WebAuthnError` as a human-readable diagnostic.
fn to_text(err: WebAuthnError) : Text
  case err
    InvalidConfig(reason: r): "invalid WebAuthn config: #{r}"
    BadCbor(reason: r): "invalid WebAuthn CBOR: #{r}"
    BadCoseKey(reason: r): "invalid WebAuthn COSE key: #{r}"
    BadAuthData(reason: r): "invalid WebAuthn authData: #{r}"
    MissingChallengeCookie: "missing WebAuthn challenge cookie"
    InvalidChallengeCookie: "invalid or tampered WebAuthn challenge cookie"
    ChallengeExpired: "WebAuthn challenge expired"
    PurposeMismatch: "WebAuthn challenge purpose mismatch"
    TypeMismatch(got: g): "unexpected clientDataJSON type '#{g}'"
    OriginMismatch(got: g): "origin '#{g}' is not allowed for WebAuthn"
    RpIdMismatch: "WebAuthn rpIdHash mismatch"
    ChallengeMismatch: "WebAuthn challenge mismatch"
    UserPresenceRequired: "WebAuthn authenticator user-presence flag missing"
    UserVerificationRequired: "WebAuthn authenticator user-verification flag missing"
    MissingAttestedCredential: "WebAuthn registration missing attested credential data"
    UnsupportedCredentialAlg: "unsupported WebAuthn credential algorithm"
    InvalidSignature: "WebAuthn assertion signature failed verification"
    ClonedAuthenticator(stored: s, got: g): "possible cloned authenticator (stored signCount=#{s}, got=#{g})"
    CryptoFailed(e): "WebAuthn crypto failure: #{e.to_text}"
  end
end

## Default localhost-ready WebAuthn configuration requiring user verification and HTTPS cookies when `secure?` is set.
fn default_config(rp_id: Text, rp_name: Text, origins: List(Text), secure?: Bool) : WebAuthnConfig
  WebAuthnConfig(
    rp_id: rp_id,
    rp_name: rp_name,
    allowed_origins: origins,
    cookie_name: "arvo_webauthn_ch",
    challenge_ttl_seconds: 300,
    require_user_verification?: true,
    secure_cookie?: secure?
  )
end

## Validates Relying Party ID, allowed origins, challenge cookie name, and TTL bounds.
fn validate_config(cfg: WebAuthnConfig) : Result(Unit, WebAuthnError)
  return Error(InvalidConfig(reason: "rp_id cannot be empty")) if cfg.rp_id.trim.empty?
  return Error(InvalidConfig(reason: "rp_name cannot be empty")) if cfg.rp_name.trim.empty?
  if cfg.allowed_origins.empty?
    return Error(InvalidConfig(reason: "allowed_origins cannot be empty"))
  end
  for orig in cfg.allowed_origins
    if not (
      orig.starts_with?("https://") or
        orig.starts_with?("http://localhost") or
        orig.starts_with?("http://127.0.0.1")
    )
      return Error(InvalidConfig(reason: "origin '#{orig}' must be https:// or loopback http"))
    end
  end
  if not Cookie.valid_name?(cfg.cookie_name)
    return Error(InvalidConfig(reason: "invalid challenge cookie_name"))
  end
  if cfg.challenge_ttl_seconds < 30 or cfg.challenge_ttl_seconds > 900
    return Error(InvalidConfig(reason: "challenge_ttl_seconds must be between 30 and 900"))
  end
  Ok(Unit)
end

fn byte_at(bs: Bytes, pos: Int) : Int
  bs.get(pos).map(fn(b) b.to_int end) or 0
end

fn read_u16_be(bs: Bytes, pos: Int) : Option(Int)
  return None if pos < 0 or pos + 2 > bs.size
  b0 = byte_at(bs, pos)
  b1 = byte_at(bs, pos + 1)
  Some(b0 * 256 + b1)
end

fn read_u32_be(bs: Bytes, pos: Int) : Option(Int)
  return None if pos < 0 or pos + 4 > bs.size
  b0 = byte_at(bs, pos)
  b1 = byte_at(bs, pos + 1)
  b2 = byte_at(bs, pos + 2)
  b3 = byte_at(bs, pos + 3)
  Some(((b0 * 256 + b1) * 256 + b2) * 256 + b3)
end

fn read_uint_arg(bs: Bytes, pos: Int, ai: Int) : Result((Int, Int), WebAuthnError)
  if ai < 24
    Ok((ai, pos))
  else if ai == 24
    return Error(BadCbor(reason: "truncated 1-byte CBOR integer")) if pos + 1 > bs.size
    v = byte_at(bs, pos)
    Ok((v, pos + 1))
  else if ai == 25
    v = try read_u16_be(bs, pos).or_fail(BadCbor(reason: "truncated 2-byte CBOR integer"))
    Ok((v, pos + 2))
  else if ai == 26
    v = try read_u32_be(bs, pos).or_fail(BadCbor(reason: "truncated 4-byte CBOR integer"))
    Ok((v, pos + 4))
  else if ai == 27
    return Error(BadCbor(reason: "truncated 8-byte CBOR integer")) if pos + 8 > bs.size
    hi = byte_at(bs, pos)
    return Error(BadCbor(reason: "CBOR uint64 overflows signed Int")) if hi >= 128
    var acc = 0
    var i = 0
    while i < 8
      acc = acc * 256 + byte_at(bs, pos + i)
      i += 1
    end
    Ok((acc, pos + 8))
  else
    Error(BadCbor(reason: "unsupported CBOR additional info #{ai}"))
  end
end

fn decode_cbor_at(bs: Bytes, pos: Int, depth: Int) : Result((CborVal, Int), WebAuthnError)
  return Error(BadCbor(reason: "CBOR nesting depth exceeded")) if depth > 8
  return Error(BadCbor(reason: "unexpected end of CBOR input")) if pos >= bs.size
  ib = byte_at(bs, pos)
  major = ib.floor_div(32)
  ai = ib % 32
  p1 = pos + 1

  if major == 0
    (u, next_pos) = try read_uint_arg(bs, p1, ai)
    Ok((CborInt(u), next_pos))
  else if major == 1
    (u, next_pos) = try read_uint_arg(bs, p1, ai)
    Ok((CborInt(-1 - u), next_pos))
  else if major == 2
    (len, dpos) = try read_uint_arg(bs, p1, ai)
    if len < 0 or dpos + len > bs.size
      return Error(BadCbor(reason: "truncated CBOR byte string"))
    end
    Ok((CborBytes(bs.slice(dpos, dpos + len)), dpos + len))
  else if major == 3
    (len, dpos) = try read_uint_arg(bs, p1, ai)
    if len < 0 or dpos + len > bs.size
      return Error(BadCbor(reason: "truncated CBOR text string"))
    end
    txt = try bs.slice(dpos, dpos + len).decode_utf8.or_fail(
      BadCbor(reason: "CBOR text string is not valid UTF-8")
    )
    Ok((CborText(txt), dpos + len))
  else if major == 4
    (count, mut_pos) = try read_uint_arg(bs, p1, ai)
    return Error(BadCbor(reason: "CBOR array exceeds 64 items")) if count < 0 or count > 64
    var cur = mut_pos
    var items = []
    var i = 0
    while i < count
      (item, np) = try decode_cbor_at(bs, cur, depth + 1)
      items = items.append(item)
      cur = np
      i += 1
    end
    Ok((CborArray(items), cur))
  else if major == 5
    (count, mut_pos) = try read_uint_arg(bs, p1, ai)
    return Error(BadCbor(reason: "CBOR map exceeds 64 entries")) if count < 0 or count > 64
    var cur = mut_pos
    var pairs = []
    var i = 0
    while i < count
      (k, np1) = try decode_cbor_at(bs, cur, depth + 1)
      (v, np2) = try decode_cbor_at(bs, np1, depth + 1)
      pairs = pairs.append((k, v))
      cur = np2
      i += 1
    end
    Ok((CborMap(pairs), cur))
  else if major == 7
    if ai == 20
      Ok((CborBool(false), p1))
    else if ai == 21
      Ok((CborBool(true), p1))
    else if ai == 22 or ai == 23
      Ok((CborNull, p1))
    else
      Error(BadCbor(reason: "unsupported CBOR simple/float value #{ai}"))
    end
  else
    Error(BadCbor(reason: "unsupported CBOR major type #{major}"))
  end
end

## Decodes a complete canonical CBOR payload, rejecting truncated, oversized, or trailing bytes.
fn decode_cbor(data: Bytes) : Result(CborVal, WebAuthnError)
  (val, end_pos) = try decode_cbor_at(data, 0, 0)
  if end_pos != data.size
    return Error(BadCbor(reason: "unexpected trailing bytes after CBOR value"))
  end
  Ok(val)
end

fn cbor_map_get_text(pairs: List((CborVal, CborVal)), key: Text) : Option(CborVal)
  for (k, v) in pairs
    if k == CborText(key)
      return Some(v)
    end
  end
  None
end

fn cbor_map_get_int(pairs: List((CborVal, CborVal)), key: Int) : Option(CborVal)
  for (k, v) in pairs
    if k == CborInt(key)
      return Some(v)
    end
  end
  None
end

fn parse_cose_val(val: CborVal) : Result(ParsedCoseKey, WebAuthnError)
  pairs = case val
    CborMap(ps): ps
    CborInt(_) | CborBytes(_) | CborText(_) | CborArray(_) | CborBool(_) | CborNull: return Error(
      BadCoseKey(reason: "COSE key must be a CBOR map")
    )
  end
  kty = case cbor_map_get_int(pairs, 1)
    Some(CborInt(n)): n
    Some(_) | None: return Error(BadCoseKey(reason: "COSE key missing integer kty (1)"))
  end
  alg = case cbor_map_get_int(pairs, 3)
    Some(CborInt(n)): n
    Some(_) | None: return Error(BadCoseKey(reason: "COSE key missing integer alg (3)"))
  end
  crv = case cbor_map_get_int(pairs, -1)
    Some(CborInt(n)): n
    Some(_) | None: return Error(BadCoseKey(reason: "COSE key missing curve (-1)"))
  end
  x_bytes = case cbor_map_get_int(pairs, -2)
    Some(CborBytes(b)): b
    Some(_) | None: return Error(BadCoseKey(reason: "COSE key missing x coordinate (-2)"))
  end

  if kty == 2 and alg == -7 and crv == 1
    y_bytes = case cbor_map_get_int(pairs, -3)
      Some(CborBytes(b)): b
      Some(_) | None: return Error(BadCoseKey(reason: "EC2 COSE key missing y coordinate (-3)"))
    end
    if x_bytes.size != 32 or y_bytes.size != 32
      return Error(BadCoseKey(reason: "P-256 coordinates must be 32 bytes each"))
    end
    prefix = match_p256_prefix()
    Ok(ParsedCoseKey(alg: Es256, public_key: Bytes.join([prefix, x_bytes, y_bytes])))
  else if kty == 1 and alg == -8 and crv == 6
    if x_bytes.size != 32
      return Error(BadCoseKey(reason: "Ed25519 public key must be 32 bytes"))
    end
    Ok(ParsedCoseKey(alg: Ed25519, public_key: x_bytes))
  else
    Error(UnsupportedCredentialAlg)
  end
end

fn match_p256_prefix() : Bytes
  Bytes.from_hex("04") or Bytes.empty
end

## Parses a CBOR-encoded COSE EC2 P-256 (`-7`) or OKP Ed25519 (`-8`) public key.
fn parse_cose_public_key(cose_bytes: Bytes) : Result(ParsedCoseKey, WebAuthnError)
  val = try decode_cbor(cose_bytes)
  parse_cose_val(val)
end

fn bit_set?(flags: Int, mask: Int) : Bool
  flags.floor_div(mask) % 2 == 1
end

## Decodes WebAuthn `authData` bytes (and optional attested credential + COSE key when `AT` flag is set).
fn parse_auth_data(auth_data: Bytes) : Result(ParsedAuthData, WebAuthnError)
  if auth_data.size < 37
    return Error(BadAuthData(reason: "authData must be at least 37 bytes"))
  end
  rp_id_hash = auth_data.slice(0, 32)
  flags = byte_at(auth_data, 32)
  sign_count = try read_u32_be(auth_data, 33).or_fail(BadAuthData(reason: "bad signCount"))

  up? = bit_set?(flags, 1)
  uv? = bit_set?(flags, 4)
  be? = bit_set?(flags, 8)
  bs? = bit_set?(flags, 16)
  at? = bit_set?(flags, 64)
  ed? = bit_set?(flags, 128)

  if not at?
    if not ed? and auth_data.size != 37
      return Error(BadAuthData(reason: "unexpected trailing bytes in assertion authData"))
    end
    if ed?
      (_ext, end_pos) = try decode_cbor_at(auth_data, 37, 0)
      if end_pos != auth_data.size
        return Error(BadAuthData(reason: "trailing bytes after WebAuthn extensions"))
      end
    end
    return Ok(
      ParsedAuthData(
        rp_id_hash: rp_id_hash,
        flags: flags,
        user_present?: up?,
        user_verified?: uv?,
        backup_eligible?: be?,
        backup_state?: bs?,
        attested_credential?: false,
        sign_count: sign_count,
        aaguid: None,
        credential_id: None,
        cose_key: None
      )
    )
  end

  if auth_data.size < 55
    return Error(BadAuthData(reason: "attested credential header truncated"))
  end
  aaguid = auth_data.slice(37, 53)
  cred_len = try read_u16_be(auth_data, 53).or_fail(BadAuthData(reason: "bad credentialIdLength"))
  if cred_len < 1 or 55 + cred_len >= auth_data.size
    return Error(BadAuthData(reason: "invalid credentialId length #{cred_len}"))
  end
  cred_id = auth_data.slice(55, 55 + cred_len)
  cose_offset = 55 + cred_len
  (cose_val, cose_end) = try decode_cbor_at(auth_data, cose_offset, 0)
  cose_key = try parse_cose_val(cose_val)

  if ed?
    (_ext, ext_end) = try decode_cbor_at(auth_data, cose_end, 0)
    if ext_end != auth_data.size
      return Error(BadAuthData(reason: "trailing bytes after extensions"))
    end
  else if cose_end != auth_data.size
    return Error(BadAuthData(reason: "trailing bytes after COSE public key"))
  end

  Ok(
    ParsedAuthData(
      rp_id_hash: rp_id_hash,
      flags: flags,
      user_present?: up?,
      user_verified?: uv?,
      backup_eligible?: be?,
      backup_state?: bs?,
      attested_credential?: true,
      sign_count: sign_count,
      aaguid: Some(aaguid),
      credential_id: Some(cred_id),
      cose_key: Some(cose_key)
    )
  )
end

fn challenge_aad(cookie_name: Text) : Bytes
  "arvo:webauthn:#{cookie_name}".bytes
end

## Appends the `HttpOnly; SameSite=Lax` AEAD-sealed WebAuthn challenge cookie onto `res`.
fn attach_challenge_cookie(res: Api.Response, cfg: WebAuthnConfig, sealed_challenge: Text) : Api
  .Response
  opts = Cookie.CookieOptions(
    path: "/",
    max_age: Some(cfg.challenge_ttl_seconds),
    http_only?: true,
    secure?: cfg.secure_cookie?,
    same_site: Cookie.Lax
  )
  Cookie.set(res, cfg.cookie_name, sealed_challenge, opts)
end

## Clears the WebAuthn challenge cookie from `res`.
fn clear_challenge_cookie(res: Api.Response, cfg: WebAuthnConfig) : Api.Response
  Cookie.clear(res, cfg.cookie_name, "/", cfg.secure_cookie?)
end

fn seal_challenge(
  cfg: WebAuthnConfig,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  clock: Clock,
  purpose: Text,
  user_id: Option(Text)
) : Result((Text, Text), WebAuthnError)
  challenge = rng.bytes(32).to_base64url
  now = clock.now
  st = SealedChallenge(
    purpose: purpose,
    challenge: challenge,
    user_id: user_id,
    issued_at: now,
    expires_at: now + cfg.challenge_ttl_seconds.seconds
  )
  sealed = try Keyring.seal(rng, keyring, Json.encode(st).bytes, challenge_aad(cfg.cookie_name))
    .map_error(fn(e) InvalidConfig(reason: "keyring error: #{Keyring.to_text(e)}") end)
  Ok((challenge, sealed))
end

fn verify_challenge_cookie(
  cfg: WebAuthnConfig,
  req: Api.Request,
  keyring: Keyring.Keyring,
  now: Time,
  expected_purpose: Text,
  expected_user_id: Option(Text)
) : Result(SealedChallenge, WebAuthnError)
  raw = case Cookie.get(req, cfg.cookie_name)
    Some(c): c
    None: return Error(MissingChallengeCookie)
  end
  opened = case Keyring.open(keyring, raw, challenge_aad(cfg.cookie_name))
    Some(o): o
    None: return Error(InvalidChallengeCookie)
  end
  st = case Json.decode_strict[SealedChallenge](opened.plaintext)
    Ok(s): s
    Error(_): return Error(InvalidChallengeCookie)
  end
  return Error(PurposeMismatch) if st.purpose != expected_purpose
  return Error(ChallengeExpired) if now >= st.expires_at
  if expected_user_id is Some(uid)
    if st.user_id != Some(uid)
      return Error(InvalidChallengeCookie)
    end
  end
  Ok(st)
end

## Begins Passkey registration, returning `(PublicKeyCredentialCreationOptions JSON, sealed_cookie)`.
fn begin_registration(
  cfg: WebAuthnConfig,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  clock: Clock,
  user_id: Text,
  user_name: Text,
  display_name: Text,
  existing_credential_ids: List(Text)
) : Result((Json, Text), WebAuthnError)
  _ = try validate_config(cfg)
  if user_id.trim.empty?
    return Error(InvalidConfig(reason: "user_id cannot be empty for registration"))
  end
  (challenge, sealed) = try seal_challenge(cfg, rng, keyring, clock, "register", Some(user_id))
  user_handle = user_id.bytes.to_base64url
  uv_req = if cfg.require_user_verification?
    "required"
  else
    "preferred"
  end
  excludes = existing_credential_ids.map(fn(cid)
    Json.Object({"type": Json.String("public-key"), "id": Json.String(cid)})
  end)
  opts = Json.Object({
    "challenge": Json.String(challenge),
    "rp": Json.Object({"id": Json.String(cfg.rp_id), "name": Json.String(cfg.rp_name)}),
    "user": Json.Object({
      "id": Json.String(user_handle),
      "name": Json.String(user_name),
      "displayName": Json.String(display_name)
    }),
    "pubKeyCredParams": Json.Array([
      Json.Object({"type": Json.String("public-key"), "alg": Json.int(-7)}),
      Json.Object({"type": Json.String("public-key"), "alg": Json.int(-8)})
    ]),
    "timeout": Json.int(cfg.challenge_ttl_seconds * 1000),
    "attestation": Json.String("none"),
    "excludeCredentials": Json.Array(excludes),
    "authenticatorSelection": Json.Object({
      "residentKey": Json.String("preferred"),
      "userVerification": Json.String(uv_req)
    })
  })
  Ok((opts, sealed))
end

fn verify_client_data(
  cfg: WebAuthnConfig,
  client_data_b64url: Text,
  expected_type: Text,
  expected_challenge: Text
) : Result(Bytes, WebAuthnError)
  client_bytes = try Bytes.from_base64url(client_data_b64url).or_fail(
    BadCbor(reason: "clientDataJSON is not valid base64url")
  )
  client_txt = try client_bytes.decode_utf8.or_fail(
    BadCbor(reason: "clientDataJSON is not valid UTF-8")
  )
  doc = case Json.parse(client_txt)
    Ok(Json.Object(m)): Json.Object(m)
    Ok(_) | Error(_): return Error(BadCbor(reason: "clientDataJSON must be a JSON object"))
  end
  got_type = try doc.text_at("type").or_fail(TypeMismatch(got: ""))
  return Error(TypeMismatch(got: got_type)) if got_type != expected_type
  got_ch = try doc.text_at("challenge").or_fail(ChallengeMismatch)
  if not Crypto.constant_time_eq?(got_ch.bytes, expected_challenge.bytes)
    return Error(ChallengeMismatch)
  end
  got_orig = try doc.text_at("origin").or_fail(OriginMismatch(got: ""))
  return Error(OriginMismatch(got: got_orig)) if not cfg.allowed_origins.contains?(got_orig)
  Ok(client_bytes)
end

fn check_auth_flags(cfg: WebAuthnConfig, ad: ParsedAuthData) : Result(Unit, WebAuthnError)
  expected_rp_hash = Crypto.sha256(cfg.rp_id.bytes)
  if not Crypto.constant_time_eq?(ad.rp_id_hash, expected_rp_hash)
    return Error(RpIdMismatch)
  end
  return Error(UserPresenceRequired) if not ad.user_present?
  if cfg.require_user_verification? and not ad.user_verified?
    return Error(UserVerificationRequired)
  end
  Ok(Unit)
end

## Verifies registration challenge, clientDataJSON, attestationObject `authData`, and extracts the COSE passkey.
fn finish_registration(
  cfg: WebAuthnConfig,
  req: Api.Request,
  keyring: Keyring.Keyring,
  clock: Clock,
  expected_user_id: Text,
  response_json: Json
) : Result(RegisteredPasskey, WebAuthnError)
  _ = try validate_config(cfg)
  st = try verify_challenge_cookie(cfg, req, keyring, clock.now, "register", Some(expected_user_id))
  resp = case response_json.get("response")
    Some(r): r
    None: response_json
  end
  cd_b64 = try resp.text_at("clientDataJSON").or_fail(BadCbor(reason: "missing clientDataJSON"))
  att_b64 = try resp.text_at("attestationObject").or_fail(
    BadCbor(reason: "missing attestationObject")
  )
  _client_bytes = try verify_client_data(cfg, cd_b64, "webauthn.create", st.challenge)
  att_bytes = try Bytes.from_base64url(att_b64).or_fail(
    BadCbor(reason: "attestationObject is not valid base64url")
  )
  att_pairs = case try decode_cbor(att_bytes)
    CborMap(ps): ps
    CborInt(_) | CborBytes(_) | CborText(_) | CborArray(_) | CborBool(_) | CborNull: return Error(
      BadCbor(reason: "attestationObject must be a CBOR map")
    )
  end
  auth_data = case cbor_map_get_text(att_pairs, "authData")
    Some(CborBytes(b)): b
    Some(_) | None: return Error(BadCbor(reason: "attestationObject missing authData bytes"))
  end
  ad = try parse_auth_data(auth_data)
  _ = try check_auth_flags(cfg, ad)
  cred_id = try ad.credential_id.or_fail(MissingAttestedCredential)
  cose = try ad.cose_key.or_fail(MissingAttestedCredential)
  aaguid_hex = case ad.aaguid
    Some(a): a.to_hex
    None: ""
  end
  Ok(
    RegisteredPasskey(
      credential_id: cred_id.to_base64url,
      public_key_b64url: cose.public_key.to_base64url,
      alg: cose.alg,
      sign_count: ad.sign_count,
      aaguid_hex: aaguid_hex,
      backed_up?: ad.backup_state?
    )
  )
end

## Begins Passkey authentication, returning `(PublicKeyCredentialRequestOptions JSON, sealed_cookie)`.
fn begin_authentication(
  cfg: WebAuthnConfig,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  clock: Clock,
  user_id: Option(Text),
  allowed_credential_ids: List(Text)
) : Result((Json, Text), WebAuthnError)
  _ = try validate_config(cfg)
  (challenge, sealed) = try seal_challenge(cfg, rng, keyring, clock, "authenticate", user_id)
  uv_req = if cfg.require_user_verification?
    "required"
  else
    "preferred"
  end
  allow_list = allowed_credential_ids.map(fn(cid)
    Json.Object({"type": Json.String("public-key"), "id": Json.String(cid)})
  end)
  opts = Json.Object({
    "challenge": Json.String(challenge),
    "rpId": Json.String(cfg.rp_id),
    "timeout": Json.int(cfg.challenge_ttl_seconds * 1000),
    "allowCredentials": Json.Array(allow_list),
    "userVerification": Json.String(uv_req)
  })
  Ok((opts, sealed))
end

## Verifies a WebAuthn login assertion signature (`ES256` ASN.1 or `Ed25519`), flags, origin, RP ID, and monotonic signCount.
fn finish_authentication(
  cfg: WebAuthnConfig,
  req: Api.Request,
  keyring: Keyring.Keyring,
  clock: Clock,
  expected_user_id: Option(Text),
  credential: RegisteredPasskey,
  assertion_json: Json
) : Result(AssertionOutcome, WebAuthnError)
  _ = try validate_config(cfg)
  st = try verify_challenge_cookie(cfg, req, keyring, clock.now, "authenticate", expected_user_id)
  got_cid = assertion_json.text_at("rawId") or (assertion_json.text_at("id") or "")
  if not got_cid.empty? and got_cid != credential.credential_id
    return Error(InvalidSignature)
  end

  resp = case assertion_json.get("response")
    Some(r): r
    None: assertion_json
  end
  cd_b64 = try resp.text_at("clientDataJSON").or_fail(BadCbor(reason: "missing clientDataJSON"))
  ad_b64 = try resp.text_at("authenticatorData").or_fail(
    BadCbor(reason: "missing authenticatorData")
  )
  sig_b64 = try resp.text_at("signature").or_fail(BadCbor(reason: "missing signature"))

  client_bytes = try verify_client_data(cfg, cd_b64, "webauthn.get", st.challenge)
  auth_data = try Bytes.from_base64url(ad_b64).or_fail(
    BadAuthData(reason: "authenticatorData is not valid base64url")
  )
  sig_bytes = try Bytes.from_base64url(sig_b64).or_fail(
    BadCbor(reason: "signature is not valid base64url")
  )
  pub_bytes = try Bytes.from_base64url(credential.public_key_b64url).or_fail(
    BadCoseKey(reason: "stored credential public key is invalid base64url")
  )

  ad = try parse_auth_data(auth_data)
  _ = try check_auth_flags(cfg, ad)

  signed_payload = Bytes.join([auth_data, Crypto.sha256(client_bytes)])
  crypto_alg = case credential.alg
    Es256: Crypto.Es256Asn1
    Ed25519: Crypto.Ed25519
  end
  valid? = try Crypto.verify_signature(crypto_alg, pub_bytes, signed_payload, sig_bytes).map_error(
    fn(e) CryptoFailed(e) end
  )
  return Error(InvalidSignature) if not valid?

  if credential.sign_count > 0 and ad.sign_count <= credential.sign_count
    return Error(ClonedAuthenticator(stored: credential.sign_count, got: ad.sign_count))
  end

  Ok(
    AssertionOutcome(
      credential_id: credential.credential_id,
      new_sign_count: ad.sign_count,
      user_verified?: ad.user_verified?,
      backed_up?: ad.backup_state?
    )
  )
end

test "WebAuthn CBOR/COSE parsing, ES256 & Ed25519 registration/assertion, and fail-closed security"
  # 1. Malformed CBOR bounds & trailing bytes fail closed
  assert decode_cbor(Bytes.empty) is Error(BadCbor(reason: _))
  assert decode_cbor(Bytes.from_hex("9f") or Bytes.empty) is Error(BadCbor(reason: _))
  assert decode_cbor(Bytes.from_hex("0102") or Bytes.empty) is Error(BadCbor(reason: _))

  rng = SecureRandom.seeded(5150)
  k = rng.bytes(32)
  kr = case Keyring.single("k1", k)
    Ok(x): x
    Error(_): stop "kr"
  end
  cfg = default_config("example.com", "Arvo Demo", ["https://example.com"], true)
  t0 = Time.parse("2026-11-28T00:00:00Z") or stop "t0"
  clk = Clock.fixed(t0)

  # 2. ES256 Passkey registration & assertion (signCount 5 -> 6)
  (reg_ec_opts, rs_ec) = case begin_registration(
    cfg,
    rng,
    kr,
    clk,
    "usr_1",
    "ada@example.com",
    "Ada",
    []
  )
    Ok(v): v
    Error(_): stop "reg_ec_opts"
  end
  assert reg_ec_opts.text_at("challenge") == Some("XJEQI2cJ4SM57QKT7q9e3_5gxUW5ZeqzX7A4QNdBEn4")

  req_reg_ec = Api.post("/webauthn/register").with_header("Cookie", "#{cfg.cookie_name}=#{rs_ec}")
  reg_ec_json = Json.Object({
    "id": Json.String("Y3JlZC1lYy0xMjM0NTY3OA"),
    "response": Json.Object({
      "clientDataJSON": Json.String(
        "eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIiwiY2hhbGxlbmdlIjoiWEpFUUkyY0o0U001N1FLVDdxOWUzXzVneFVXNVplcXpYN0E0UU5kQkVuNCIsIm9yaWdpbiI6Imh0dHBzOi8vZXhhbXBsZS5jb20ifQ"
      ),
      "attestationObject": Json.String(
        "o2NmbXRkbm9uZWdhdHRTdG10oGhhdXRoRGF0YViUo3mm9u6vuaVeN4wRgDTidR5oL6ufLTCrE9ISVYbOGUdFAAAABQABAgMEBQYHCAkKCwwNDg8AEGNyZWQtZWMtMTIzNDU2NzilAQIDJiABIVggQ8T0gVCmRhLsGoLgNc5_x6WD4EtaUvo381iAWAoB6n8iWCD5uQRpRTTSRkD3OxuUH_zqkKCjM8wxOHxd3v4VtBbjhg"
      )
    })
  })
  pk_ec = case finish_registration(cfg, req_reg_ec, kr, clk, "usr_1", reg_ec_json)
    Ok(pk): pk
    Error(_): stop "finish_reg_ec failed"
  end
  assert pk_ec.credential_id == "Y3JlZC1lYy0xMjM0NTY3OA"
  assert pk_ec.alg == Es256 and pk_ec.sign_count == 5
  assert pk_ec.aaguid_hex == "000102030405060708090a0b0c0d0e0f"

  (_auth_ec_opts, as_ec) = case begin_authentication(
    cfg,
    rng,
    kr,
    clk,
    Some("usr_1"),
    [pk_ec.credential_id]
  )
    Ok(v): v
    Error(_): stop "auth_ec_opts"
  end
  req_auth_ec = Api.post("/webauthn/login").with_header("Cookie", "#{cfg.cookie_name}=#{as_ec}")
  auth_ec_json = Json.Object({
    "rawId": Json.String("Y3JlZC1lYy0xMjM0NTY3OA"),
    "response": Json.Object({
      "clientDataJSON": Json.String(
        "eyJ0eXBlIjoid2ViYXV0aG4uZ2V0IiwiY2hhbGxlbmdlIjoicHlXbHhTRnpOZkRuU2hXZENtTTlYckI3Y19GWTlWd3JLT2lPZ3NvUXJoVSIsIm9yaWdpbiI6Imh0dHBzOi8vZXhhbXBsZS5jb20ifQ"
      ),
      "authenticatorData": Json.String("o3mm9u6vuaVeN4wRgDTidR5oL6ufLTCrE9ISVYbOGUcFAAAABg"),
      "signature": Json.String(
        "MEUCIQDhiYJ-W3Tiy_jXsWtqmrSKY8yK-D9H5lNW7973BbhqxAIgSnwHutpHLmz5MdvAO0M4WUBiiFGQCHnrch4hLq-YJYI"
      )
    })
  })
  assert finish_authentication(cfg, req_auth_ec, kr, clk, Some("usr_1"), pk_ec, auth_ec_json) ==
    Ok(
      AssertionOutcome(
        credential_id: "Y3JlZC1lYy0xMjM0NTY3OA",
        new_sign_count: 6,
        user_verified?: true,
        backed_up?: false
      )
    )

  # 3. Ed25519 Passkey registration & assertion (backed_up? = true, signCount 0 -> 0 allowed)
  (_reg_ed_opts, rs_ed) = case begin_registration(
    cfg,
    rng,
    kr,
    clk,
    "usr_2",
    "grace@example.com",
    "Grace",
    []
  )
    Ok(v): v
    Error(_): stop "reg_ed_opts"
  end
  req_reg_ed = Api.post("/webauthn/register").with_header("Cookie", "#{cfg.cookie_name}=#{rs_ed}")
  reg_ed_json = Json.Object({
    "id": Json.String("Y3JlZC1lZC0xMjM0NTY3OA"),
    "response": Json.Object({
      "clientDataJSON": Json.String(
        "eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIiwiY2hhbGxlbmdlIjoidzZkOEFUSUFnc2ZzRExqbTcwRkNEN1dybzVVNFFBRllMU29JcEI4Tk5FRSIsIm9yaWdpbiI6Imh0dHBzOi8vZXhhbXBsZS5jb20ifQ"
      ),
      "attestationObject": Json.String(
        "o2NmbXRkbm9uZWdhdHRTdG10oGhhdXRoRGF0YVhxo3mm9u6vuaVeN4wRgDTidR5oL6ufLTCrE9ISVYbOGUddAAAAAAABAgMEBQYHCAkKCwwNDg8AEGNyZWQtZWQtMTIzNDU2NzikAQEDJyAGIVggFi-D1425tS1OjiAYeC7TUYhjErLzRiSETuEePNBAwxo"
      )
    })
  })
  pk_ed = case finish_registration(cfg, req_reg_ed, kr, clk, "usr_2", reg_ed_json)
    Ok(pk): pk
    Error(_): stop "finish_reg_ed failed"
  end
  assert pk_ed.alg == Ed25519 and pk_ed.backed_up? and pk_ed.sign_count == 0

  (_auth_ed_opts, as_ed) = case begin_authentication(
    cfg,
    rng,
    kr,
    clk,
    Some("usr_2"),
    [pk_ed.credential_id]
  )
    Ok(v): v
    Error(_): stop "auth_ed_opts"
  end
  req_auth_ed = Api.post("/webauthn/login").with_header("Cookie", "#{cfg.cookie_name}=#{as_ed}")
  auth_ed_json = Json.Object({
    "rawId": Json.String("Y3JlZC1lZC0xMjM0NTY3OA"),
    "response": Json.Object({
      "clientDataJSON": Json.String(
        "eyJ0eXBlIjoid2ViYXV0aG4uZ2V0IiwiY2hhbGxlbmdlIjoibjNpWnp4dlNZWWFrRlVfWnVzZm9pZXRVQ21VZDZuaHFIMko2RnhrWEFxUSIsIm9yaWdpbiI6Imh0dHBzOi8vZXhhbXBsZS5jb20ifQ"
      ),
      "authenticatorData": Json.String("o3mm9u6vuaVeN4wRgDTidR5oL6ufLTCrE9ISVYbOGUcFAAAAAA"),
      "signature": Json.String(
        "XVGv7xBq--LeWF3gXcvn7LBQtfjpx-ArhSjvHEYDfqUNRGRlItZG8gQxGWYNhw__p2uKe0gOBIZG4RzWr7LGDA"
      )
    })
  })
  assert finish_authentication(cfg, req_auth_ed, kr, clk, Some("usr_2"), pk_ed, auth_ed_json) ==
    Ok(
      AssertionOutcome(
        credential_id: "Y3JlZC1lZC0xMjM0NTY3OA",
        new_sign_count: 0,
        user_verified?: true,
        backed_up?: false
      )
    )

  # 4. Fail-closed checks: cloned sign_count, wrong purpose, expired cookie, tampered sig, wrong origin
  var pk_ec_higher = pk_ec
  pk_ec_higher.sign_count = 6
  assert finish_authentication(cfg, req_auth_ec, kr, clk, Some("usr_1"), pk_ec_higher, auth_ec_json) ==
    Error(ClonedAuthenticator(stored: 6, got: 6))

  assert finish_authentication(cfg, req_reg_ec, kr, clk, Some("usr_1"), pk_ec, auth_ec_json) ==
    Error(PurposeMismatch)
  assert finish_authentication(
    cfg,
    req_auth_ec,
    kr,
    Clock.fixed(t0 + 300.seconds),
    Some("usr_1"),
    pk_ec,
    auth_ec_json
  ) ==
    Error(ChallengeExpired)
  assert finish_authentication(
    default_config("example.com", "Arvo Demo", ["https://other.example"], true),
    req_auth_ec,
    kr,
    clk,
    Some("usr_1"),
    pk_ec,
    auth_ec_json
  ) ==
    Error(OriginMismatch(got: "https://example.com"))

  bad_sig_json = Json.Object({
    "rawId": Json.String("Y3JlZC1lZC0xMjM0NTY3OA"),
    "response": Json.Object({
      "clientDataJSON": Json.String(
        "eyJ0eXBlIjoid2ViYXV0aG4uZ2V0IiwiY2hhbGxlbmdlIjoibjNpWnp4dlNZWWFrRlVfWnVzZm9pZXRVQ21VZDZuaHFIMko2RnhrWEFxUSIsIm9yaWdpbiI6Imh0dHBzOi8vZXhhbXBsZS5jb20ifQ"
      ),
      "authenticatorData": Json.String("o3mm9u6vuaVeN4wRgDTidR5oL6ufLTCrE9ISVYbOGUcFAAAAAA"),
      "signature": Json.String(
        "YVGv7xBq--LeWF3gXcvn7LBQtfjpx-ArhSjvHEYDfqUNRGRlItZG8gQxGWYNhw__p2uKe0gOBIZG4RzWr7LGDA"
      )
    })
  })
  assert finish_authentication(cfg, req_auth_ed, kr, clk, Some("usr_2"), pk_ed, bad_sig_json) ==
    Error(InvalidSignature)

  res_set = attach_challenge_cookie(Api.no_content(), cfg, as_ed)
  assert (res_set.header("Set-Cookie") or "").contains?("#{cfg.cookie_name}=")
  res_clr = clear_challenge_cookie(Api.no_content(), cfg)
  assert (res_clr.header("Set-Cookie") or "").contains?("Max-Age=0")
end
