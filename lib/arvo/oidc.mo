## OpenID Connect / OAuth 2.0 Authorization Code + PKCE (`S256`) client with AEAD-sealed
## state/nonce cookies, domain allowlists, and deterministic `Network.fake` test support.
module Arvo.Oidc
expose OidcError(..),
ProviderEndpoints(..),
OidcConfig(..),
AuthState(..),
TokenResponse(..),
OidcIdentity(..),
Jwk(..),
to_text,
default_scopes,
google_endpoints,
github_oauth_endpoints,
microsoft_endpoints,
okta_endpoints,
validate_config,
pkce_challenge_s256,
safe_return_to,
email_domain_allowed?,
decode_jwt_payload,
build_unsigned_test_jwt,
parse_jwks,
fetch_jwks,
jwk_to_verify_key,
verify_jwt_with_jwks,
github_fetch_verified_primary_email,
discover,
start_login,
start_login_with_keyring,
clear_state_cookie,
token_exchange_request,
userinfo_request,
complete_callback,
complete_callback_verified
use Api
use Arvo.Auth
use Arvo.Cookie
use Arvo.Keyring
use Crypto
use Http
use Json

## Errors returned by OIDC discovery, login initiation, callback verification, and policy checks.
enum OidcError
  InvalidConfig(reason: Text)
  InvalidKey
  CryptoFailed(Crypto.CryptoError)
  MissingStateCookie
  InvalidStateCookie
  StateMismatch
  StateExpired
  MissingCode
  ProviderError(code: Text, description: Option(Text))
  HttpFailed(Http.HttpError)
  UnexpectedStatus(status: Int, body: Text)
  BadPayload(reason: Text)
  IdentityMismatch(reason: Text)
  EmailDomainNotAllowed(email: Text)
  EmailUnverified(email: Text)
  SignatureInvalid(reason: Text)
  UnsupportedJwtAlg(alg: Text)
  KeyNotFound(kid: Option(Text))
end

## Formats an `OidcError` as a readable diagnostic.
fn to_text(err: OidcError) : Text
  case err
    InvalidConfig(reason: r): "invalid OIDC config: #{r}"
    InvalidKey: "OIDC state cookie encryption key must be 32 bytes"
    CryptoFailed(e): "OIDC crypto failure: #{e.to_text}"
    MissingStateCookie: "missing OIDC state cookie"
    InvalidStateCookie: "invalid or tampered OIDC state cookie"
    StateMismatch: "OIDC state parameter mismatch"
    StateExpired: "OIDC login state expired"
    MissingCode: "missing authorization code in OIDC callback"
    ProviderError(code: c, description: d):
      case d
        Some(desc): "OIDC provider error '#{c}': #{desc}"
        None: "OIDC provider error '#{c}'"
      end
    HttpFailed(e): "OIDC HTTP request failed: #{e.to_text}"
    UnexpectedStatus(status: s, body: b): "OIDC endpoint returned HTTP #{s}: #{b}"
    BadPayload(reason: r): "invalid OIDC JSON payload: #{r}"
    IdentityMismatch(reason: r): "OIDC identity claim mismatch: #{r}"
    EmailDomainNotAllowed(email: e): "email '#{e}' is not in an allowed domain"
    EmailUnverified(email: e): "email '#{e}' is not verified by the identity provider"
    SignatureInvalid(reason: r): "OIDC signature verification failed: #{r}"
    UnsupportedJwtAlg(alg: a): "unsupported JWT signing algorithm '#{a}'"
    KeyNotFound(kid: k):
      case k
        Some(id): "matching JWKS key '#{id}' not found"
        None: "no matching JWKS key found for token"
      end
  end
end

## OIDC provider endpoint metadata (from discovery or static preset).
struct ProviderEndpoints
  issuer: Text
  authorization_endpoint: Text
  token_endpoint: Text
  userinfo_endpoint: Option(Text)
  jwks_uri: Option(Text)
end

## Client configuration for an OIDC/SSO login integration.
struct OidcConfig
  provider_id: Text
  client_id: Text
  client_secret: Text
  redirect_uri: Text
  scopes: List(Text)
  endpoints: ProviderEndpoints
  allowed_domains: List(Text)
  require_verified_email?: Bool
  cookie_name: Text
  state_ttl_seconds: Int
  secure_cookie?: Bool
end

## Ephemeral AEAD-sealed browser login state stored across the OIDC redirect round-trip.
struct AuthState
  provider_id: Text
  state: Text
  nonce: Text
  code_verifier: Text
  return_to: Text
  issued_at: Time
  expires_at: Time
end

## Token endpoint JSON payload returned after exchanging an authorization code.
struct TokenResponse
  access_token: Text
  token_type: Text
  id_token: Option(Text)
  refresh_token: Option(Text)
  expires_in: Option(Int)
  scope: Option(Text)
end

## Verified OIDC identity returned by `complete_callback` / `complete_callback_verified`.
struct OidcIdentity
  provider_id: Text
  issuer: Text
  subject: Text
  email: Text
  email_verified?: Bool
  name: Option(Text)
  picture: Option(Text)
  return_to: Text
end

## One public key entry parsed from a JSON Web Key Set (`/.well-known/jwks.json`).
struct Jwk
  kid: Option(Text)
  kty: Text
  alg: Option(Text)
  crv: Option(Text)
  n: Option(Text)
  e: Option(Text)
  x: Option(Text)
  y: Option(Text)
  key_use: Option(Text)
end

## Standard OpenID Connect scopes (`["openid", "email", "profile"]`).
fn default_scopes() : List(Text)
  ["openid", "email", "profile"]
end

## Static OIDC endpoints for Google Workspace / Google Accounts.
fn google_endpoints() : ProviderEndpoints
  ProviderEndpoints(
    issuer: "https://accounts.google.com",
    authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
    token_endpoint: "https://oauth2.googleapis.com/token",
    userinfo_endpoint: Some("https://openidconnect.googleapis.com/v1/userinfo"),
    jwks_uri: Some("https://www.googleapis.com/oauth2/v3/certs")
  )
end

## Static OAuth 2.0 endpoints for GitHub sign-in (pair with `github_fetch_verified_primary_email`).
fn github_oauth_endpoints() : ProviderEndpoints
  ProviderEndpoints(
    issuer: "https://github.com",
    authorization_endpoint: "https://github.com/login/oauth/authorize",
    token_endpoint: "https://github.com/login/oauth/access_token",
    userinfo_endpoint: Some("https://api.github.com/user"),
    jwks_uri: None
  )
end

## Static Microsoft Entra ID / Azure AD v2.0 OIDC endpoints for `tenant` (`common`, `organizations`, or tenant ID).
fn microsoft_endpoints(tenant: Text) : ProviderEndpoints
  t = if tenant.trim.empty?: "common" else: tenant.trim
  ProviderEndpoints(
    issuer: "https://login.microsoftonline.com/#{t}/v2.0",
    authorization_endpoint: "https://login.microsoftonline.com/#{t}/oauth2/v2.0/authorize",
    token_endpoint: "https://login.microsoftonline.com/#{t}/oauth2/v2.0/token",
    userinfo_endpoint: Some("https://graph.microsoft.com/oidc/userinfo"),
    jwks_uri: Some("https://login.microsoftonline.com/#{t}/discovery/v2.0/keys")
  )
end

## Static Okta default authorization server OIDC endpoints for `domain` (e.g. `"acme.okta.com"`).
fn okta_endpoints(domain: Text) : ProviderEndpoints
  clean = domain.trim.drop_prefix("https://") or domain.trim
  host = clean.drop_suffix("/") or clean
  ProviderEndpoints(
    issuer: "https://#{host}/oauth2/default",
    authorization_endpoint: "https://#{host}/oauth2/default/v1/authorize",
    token_endpoint: "https://#{host}/oauth2/default/v1/token",
    userinfo_endpoint: Some("https://#{host}/oauth2/default/v1/userinfo"),
    jwks_uri: Some("https://#{host}/oauth2/default/v1/keys")
  )
end

fn allowed_url?(url: Text) : Bool
  return false if url.trim != url or url.empty?
  for b in url.bytes.to_list
    return false if b.to_int <= 32 or b.to_int == 127
  end
  url.starts_with?("https://") or
    url.starts_with?("http://127.0.0.1:") or
    url.starts_with?("http://127.0.0.1/") or
    url.starts_with?("http://localhost:") or
    url.starts_with?("http://localhost/")
end

## Validates OIDC configuration, requiring HTTPS endpoints (or loopback HTTP for local dev).
fn validate_config(cfg: OidcConfig) : Result(Unit, OidcError)
  if cfg.provider_id.trim.empty?
    return Error(InvalidConfig(reason: "provider_id cannot be empty"))
  end
  if cfg.client_id.trim.empty?
    return Error(InvalidConfig(reason: "client_id cannot be empty"))
  end
  if not allowed_url?(cfg.redirect_uri)
    return Error(InvalidConfig(reason: "redirect_uri must be https:// (or localhost/127.0.0.1)"))
  end
  if not allowed_url?(cfg.endpoints.issuer)
    return Error(InvalidConfig(reason: "issuer must be https:// (or localhost/127.0.0.1)"))
  end
  if not allowed_url?(cfg.endpoints.authorization_endpoint)
    return Error(
      InvalidConfig(reason: "authorization_endpoint must be https:// (or localhost/127.0.0.1)")
    )
  end
  if not allowed_url?(cfg.endpoints.token_endpoint)
    return Error(InvalidConfig(reason: "token_endpoint must be https:// (or localhost/127.0.0.1)"))
  end
  case cfg.endpoints.userinfo_endpoint
    Some(ui):
      if not allowed_url?(ui)
        return Error(
          InvalidConfig(reason: "userinfo_endpoint must be https:// (or localhost/127.0.0.1)")
        )
      end
    None: Unit
  end
  case cfg.endpoints.jwks_uri
    Some(jwks):
      if not allowed_url?(jwks)
        return Error(InvalidConfig(reason: "jwks_uri must be https:// (or localhost/127.0.0.1)"))
      end
    None: Unit
  end
  if not Cookie.valid_name?(cfg.cookie_name)
    return Error(InvalidConfig(reason: "invalid OIDC cookie_name"))
  end
  if not cfg.scopes.contains?("openid")
    return Error(InvalidConfig(reason: "scopes must include 'openid'"))
  end
  if cfg.state_ttl_seconds < 60 or cfg.state_ttl_seconds > 3600
    return Error(InvalidConfig(reason: "state_ttl_seconds must be between 60 and 3600"))
  end
  Ok(Unit)
end

## Computes an RFC 7636 PKCE `S256` challenge: `BASE64URL-ENCODE(SHA256(ASCII(verifier)))`.
fn pkce_challenge_s256(verifier: Text) : Text
  examples
    pkce_challenge_s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
  end

  promise "S256 challenge is always 43 unpadded base64url bytes"
    result.byte_count == 43 and not result.contains?("=")
  end

  Crypto.sha256(verifier.bytes).to_base64url
end

## Sanitizes an optional post-login `return_to` path, rejecting open-redirect schemes and `//host`.
fn safe_return_to(raw: Option(Text)) : Text
  examples
    safe_return_to(None) == "/"
    safe_return_to(Some("/docs/123?tab=comments")) == "/docs/123?tab=comments"
    safe_return_to(Some("https://evil.example/phish")) == "/"
    safe_return_to(Some("//evil.example/phish")) == "/"
    safe_return_to(Some("/\\evil")) == "/"
    safe_return_to(Some("/ok\r\nSet-Cookie: a=b")) == "/"
  end

  promise "safe_return_to always returns an internal path starting with single '/'"
    result.starts_with?("/") and not result.starts_with?("//")
  end

  cand = case raw
    Some(r): r.trim
    None: return "/"
  end
  return "/" if cand.empty? or not cand.starts_with?("/") or cand.starts_with?("//")
  return "/" if cand.contains?("\\")
  for b in cand.bytes.to_list
    n = b.to_int
    return "/" if n < 32 or n == 127
  end
  cand
end

## Checks whether `email`'s domain matches `allowed_domains` (empty allowlist permits all domains).
fn email_domain_allowed?(email: Text, allowed_domains: List(Text)) : Bool
  examples
    email_domain_allowed?("ada@acme.io", [])
    email_domain_allowed?("  Ada@ACME.IO ", ["acme.io"])
    not email_domain_allowed?("ada@evil.io", ["acme.io"])
    not email_domain_allowed?("not-an-email", ["acme.io"])
    not email_domain_allowed?("a@b@acme.io", ["acme.io"])
  end

  return true if allowed_domains.empty?
  norm = Auth.normalize_email(email)
  parts = norm.split("@")
  return false if parts.size != 2
  local_part = parts.first or ""
  domain = parts.get(1) or ""
  return false if local_part.empty? or domain.empty?

  dom_bytes = domain.bytes
  var matched = false
  for entry in allowed_domains
    norm_dom = entry.trim.ascii_lowercase
    if not norm_dom.empty? and Crypto.constant_time_eq?(dom_bytes, norm_dom.bytes)
      matched = true
    end
  end
  matched
end

fn state_aad(cookie_name: Text) : Bytes
  "arvo:oidc:#{cookie_name}".bytes
end

fn parse_json_object(body_text: Text, context: Text) : Result(Json, OidcError)
  case Json.parse(body_text)
    Error(_): Error(BadPayload(reason: "malformed JSON in #{context}"))
    Ok(val):
      case val
        Json.Object(_): Ok(val)
        Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): Error(
          BadPayload(reason: "#{context} must be a JSON object")
        )
      end
  end
end

## Decodes the JSON claims object from a 3-part dot-separated JWT (`header.payload.signature`).
fn decode_jwt_payload(jwt: Text) : Result(Json, OidcError)
  parts = jwt.split(".")
  if parts.size != 3
    return Error(BadPayload(reason: "JWT must have 3 dot-separated parts"))
  end
  payload_b64 = parts.get(1) or ""
  payload_bytes = case Bytes.from_base64url(payload_b64)
    Some(b): b
    None: return Error(BadPayload(reason: "JWT payload is not valid base64url"))
  end
  payload_text = case payload_bytes.decode_utf8
    Some(t): t
    None: return Error(BadPayload(reason: "JWT payload is not valid UTF-8"))
  end
  parse_json_object(payload_text, "JWT payload")
end

## Builds a 3-part unsigned JWT (`alg=none`) for zero-socket `Network.fake` OIDC tests.
fn build_unsigned_test_jwt(claims: Json) : Text
  hdr = "{\"alg\":\"none\",\"typ\":\"JWT\"}".bytes.to_base64url
  payload = claims.to_text.bytes.to_base64url
  "#{hdr}.#{payload}.test_sig"
end

fn trim_trailing_slash(url: Text) : Text
  if url.ends_with?("/"): url.drop_suffix("/") or url else: url
end

## Fetches `<issuer_url>/.well-known/openid-configuration` and validates returned endpoints.
fn discover(issuer_url: Text, network: Network) : Result(ProviderEndpoints, OidcError)
  clean_issuer = trim_trailing_slash(issuer_url.trim)
  if not allowed_url?(clean_issuer)
    return Error(InvalidConfig(reason: "issuer_url must be https:// (or localhost/127.0.0.1)"))
  end
  req = Http.get("#{clean_issuer}/.well-known/openid-configuration").header(
    "Accept",
    "application/json"
  )
  res = case req.send(network)
    Ok(r): r
    Error(e): return Error(HttpFailed(e))
  end
  if res.status != 200
    return Error(UnexpectedStatus(status: res.status, body: res.text or ""))
  end
  doc = try parse_json_object(res.text or "", "discovery document")
  issuer = try doc.text_at("issuer").or_fail(BadPayload(reason: "discovery missing issuer"))
  if trim_trailing_slash(issuer) != clean_issuer
    return Error(
      IdentityMismatch(reason: "discovery issuer '#{issuer}' does not match '#{clean_issuer}'")
    )
  end
  auth_ep = try doc.text_at("authorization_endpoint").or_fail(
    BadPayload(reason: "discovery missing authorization_endpoint")
  )
  tok_ep = try doc.text_at("token_endpoint").or_fail(
    BadPayload(reason: "discovery missing token_endpoint")
  )
  ui_ep = doc.text_at("userinfo_endpoint")
  jwks = doc.text_at("jwks_uri")
  if not allowed_url?(auth_ep) or not allowed_url?(tok_ep)
    return Error(BadPayload(reason: "discovery endpoints must be https:// (or loopback HTTP)"))
  end
  case ui_ep
    Some(u):
      if not allowed_url?(u)
        return Error(BadPayload(reason: "discovery userinfo_endpoint must be https://"))
      end
    None: Unit
  end
  Ok(
    ProviderEndpoints(
      issuer: issuer,
      authorization_endpoint: auth_ep,
      token_endpoint: tok_ep,
      userinfo_endpoint: ui_ep,
      jwks_uri: jwks
    )
  )
end

fn encode_auth_state(cfg: OidcConfig, rng: SecureRandom, clock: Clock, return_to: Option(Text)) : (
  AuthState,
  Text
)
  state = rng.bytes(32).to_base64url
  nonce = rng.bytes(32).to_base64url
  code_verifier = rng.bytes(32).to_base64url
  ret = safe_return_to(return_to)
  now = clock.now
  st = AuthState(
    provider_id: cfg.provider_id,
    state: state,
    nonce: nonce,
    code_verifier: code_verifier,
    return_to: ret,
    issued_at: now,
    expires_at: now + cfg.state_ttl_seconds.seconds
  )
  auth_req = Http.get(cfg.endpoints.authorization_endpoint).query("response_type", "code").query(
    "client_id",
    cfg.client_id
  ).query("redirect_uri", cfg.redirect_uri).query("scope", cfg.scopes.join(" ")).query(
    "state",
    state
  ).query("nonce", nonce).query("code_challenge", pkce_challenge_s256(code_verifier)).query(
    "code_challenge_method",
    "S256"
  )
  (st, auth_req.url)
end

fn decode_b64u_trimmed(raw: Text) : Option(Bytes)
  var clean = raw.trim
  while clean.ends_with?("=")
    clean = clean.drop_suffix("=") or clean
  end
  Bytes.from_base64url(clean)
end

fn byte_at_oidc(bs: Bytes, pos: Int) : Int
  bs.get(pos).map(fn(b) b.to_int end) or 0
end

fn zero_byte_oidc() : Byte
  case (0).to_byte
    Some(z): z
    None: stop "zero byte"
  end
end

fn der_len_bytes(len: Int) : List(Byte)
  var z = zero_byte_oidc()
  if len < 128
    [(len.to_byte) or z]
  else if len < 256
    [(129.to_byte) or z, (len.to_byte) or z]
  else
    hi = len.floor_div(256)
    lo = len % 256
    [(130.to_byte) or z, (hi.to_byte) or z, (lo.to_byte) or z]
  end
end

fn der_positive_int(raw: Bytes) : List(Byte)
  z = zero_byte_oidc()
  var start = 0
  while start + 1 < raw.size and byte_at_oidc(raw, start) == 0
    start += 1
  end
  trimmed = raw.slice(start, raw.size)
  var mag = trimmed.to_list
  if byte_at_oidc(trimmed, 0) >= 128
    mag = [z].concat(mag)
  end
  [(2.to_byte) or z].concat(der_len_bytes(mag.size)).concat(mag)
end

fn rsa_pkcs1_der(n_bytes: Bytes, e_bytes: Bytes) : Bytes
  z = zero_byte_oidc()
  body = der_positive_int(n_bytes).concat(der_positive_int(e_bytes))
  Bytes.from_list([(48.to_byte) or z].concat(der_len_bytes(body.size)).concat(body))
end

fn left_pad_32(bs: Bytes) : Option(Bytes)
  return None if bs.size == 0 or bs.size > 32
  return Some(bs) if bs.size == 32
  z = zero_byte_oidc()
  var pad = []
  var i = 0
  while i < 32 - bs.size
    pad = pad.append(z)
    i += 1
  end
  Some(Bytes.join([Bytes.from_list(pad), bs]))
end

## Parses a JSON Web Key Set (`{"keys": [...]}`) into typed `Jwk` entries.
fn parse_jwks(jwks_json: Text) : Result(List(Jwk), OidcError)
  doc = try parse_json_object(jwks_json, "JWKS document")
  arr = case doc.get("keys")
    Some(Json.Array(items)): items
    Some(_) | None: return Error(BadPayload(reason: "JWKS missing 'keys' array"))
  end
  var out = []
  for item in arr
    obj = case item
      Json.Object(_): item
      Json.Null | Json.Boolean(_) | Json.Number(_) | Json.String(_) | Json.Array(_): return Error(
        BadPayload(reason: "JWKS entry must be a JSON object")
      )
    end
    kty = try obj.text_at("kty").or_fail(BadPayload(reason: "JWK missing kty"))
    out = out.append(
      Jwk(
        kid: obj.text_at("kid"),
        kty: kty,
        alg: obj.text_at("alg"),
        crv: obj.text_at("crv"),
        n: obj.text_at("n"),
        e: obj.text_at("e"),
        x: obj.text_at("x"),
        y: obj.text_at("y"),
        key_use: obj.text_at("use")
      )
    )
  end
  Ok(out)
end

## Fetches and parses a provider's JWKS endpoint over `network`.
fn fetch_jwks(jwks_uri: Text, network: Network) : Result(List(Jwk), OidcError)
  if not allowed_url?(jwks_uri)
    return Error(InvalidConfig(reason: "jwks_uri must be https:// (or localhost/127.0.0.1)"))
  end
  req = Http.get(jwks_uri).header("Accept", "application/json")
  res = case req.send(network)
    Ok(r): r
    Error(e): return Error(HttpFailed(e))
  end
  if res.status != 200
    return Error(UnexpectedStatus(status: res.status, body: res.text or ""))
  end
  parse_jwks(res.text or "")
end

## Converts a `Jwk` into a verified `Crypto.SignatureAlg` and public key byte sequence for `jwt_alg`.
fn jwk_to_verify_key(jwk: Jwk, jwt_alg: Text) : Result((Crypto.SignatureAlg, Bytes), OidcError)
  if jwk.key_use is Some(u) and u != "sig"
    return Error(SignatureInvalid(reason: "JWK use '#{u}' is not 'sig'"))
  end
  if jwk.alg is Some(ja) and ja != jwt_alg
    return Error(SignatureInvalid(reason: "JWK alg '#{ja}' != JWT alg '#{jwt_alg}'"))
  end

  if jwt_alg == "RS256" and jwk.kty == "RSA"
    n_b64 = try jwk.n.or_fail(BadPayload(reason: "RSA JWK missing 'n'"))
    e_b64 = try jwk.e.or_fail(BadPayload(reason: "RSA JWK missing 'e'"))
    n_bytes = try decode_b64u_trimmed(n_b64).or_fail(BadPayload(reason: "RSA JWK invalid 'n'"))
    e_bytes = try decode_b64u_trimmed(e_b64).or_fail(BadPayload(reason: "RSA JWK invalid 'e'"))
    if n_bytes.size < 256 or e_bytes.size == 0
      return Error(BadPayload(reason: "RSA JWK key size must be >= 2048 bits"))
    end
    Ok((Crypto.Rs256, rsa_pkcs1_der(n_bytes, e_bytes)))
  else if jwt_alg == "ES256" and jwk.kty == "EC" and jwk.crv == Some("P-256")
    x_b64 = try jwk.x.or_fail(BadPayload(reason: "EC JWK missing 'x'"))
    y_b64 = try jwk.y.or_fail(BadPayload(reason: "EC JWK missing 'y'"))
    x_raw = try decode_b64u_trimmed(x_b64).or_fail(BadPayload(reason: "EC JWK invalid 'x'"))
    y_raw = try decode_b64u_trimmed(y_b64).or_fail(BadPayload(reason: "EC JWK invalid 'y'"))
    x32 = try left_pad_32(x_raw).or_fail(BadPayload(reason: "EC JWK invalid P-256 x length"))
    y32 = try left_pad_32(y_raw).or_fail(BadPayload(reason: "EC JWK invalid P-256 y length"))
    prefix = Bytes.from_hex("04") or Bytes.empty
    Ok((Crypto.Es256Fixed, Bytes.join([prefix, x32, y32])))
  else if jwt_alg == "EdDSA" and jwk.kty == "OKP" and jwk.crv == Some("Ed25519")
    x_b64 = try jwk.x.or_fail(BadPayload(reason: "OKP JWK missing 'x'"))
    x_raw = try decode_b64u_trimmed(x_b64).or_fail(BadPayload(reason: "OKP JWK invalid 'x'"))
    if x_raw.size != 32
      return Error(BadPayload(reason: "Ed25519 JWK 'x' must be 32 bytes"))
    end
    Ok((Crypto.Ed25519, x_raw))
  else
    Error(UnsupportedJwtAlg(alg: jwt_alg))
  end
end

fn decode_jwt_header(hdr_b64: Text) : Result(Json, OidcError)
  hdr_bytes = try Bytes.from_base64url(hdr_b64).or_fail(
    BadPayload(reason: "JWT header is not valid base64url")
  )
  hdr_txt = try hdr_bytes.decode_utf8.or_fail(BadPayload(reason: "JWT header is not valid UTF-8"))
  parse_json_object(hdr_txt, "JWT header")
end

## Cryptographically verifies a JWT against `jwks` (`RS256`, `ES256`, `EdDSA`), strictly
## rejecting `alg: "none"`, verifying `kid`, signature bytes, and `exp`/`nbf`/`iat` claims.
fn verify_jwt_with_jwks(jwt: Text, jwks: List(Jwk), now: Time, clock_skew_seconds: Int) : Result(
  Json,
  OidcError
)
  parts = jwt.split(".")
  if parts.size != 3
    return Error(BadPayload(reason: "JWT must have 3 dot-separated parts"))
  end
  hdr_b64 = parts.get(0) or ""
  payload_b64 = parts.get(1) or ""
  sig_b64 = parts.get(2) or ""
  hdr = try decode_jwt_header(hdr_b64)
  alg = try hdr.text_at("alg").or_fail(BadPayload(reason: "JWT header missing alg"))
  if alg != "RS256" and alg != "ES256" and alg != "EdDSA"
    return Error(UnsupportedJwtAlg(alg: alg))
  end

  hdr_kid = hdr.text_at("kid")
  var matched_keys = []
  for jwk in jwks
    case hdr_kid
      Some(want_kid):
        if jwk.kid == Some(want_kid)
          if jwk_to_verify_key(jwk, alg) is Ok(kv)
            matched_keys = matched_keys.append(kv)
          end
        end
      None:
        if jwk_to_verify_key(jwk, alg) is Ok(kv)
          matched_keys = matched_keys.append(kv)
        end
    end
  end

  (verify_alg, verify_pub) = case hdr_kid
    Some(want_kid):
      case matched_keys.first
        Some(kv) if matched_keys.size == 1: kv
        Some(_): return Error(BadPayload(reason: "ambiguous JWKS key id '#{want_kid}'"))
        None: return Error(KeyNotFound(kid: Some(want_kid)))
      end
    None:
      case matched_keys.first
        Some(kv) if matched_keys.size == 1: kv
        Some(_) | None: return Error(KeyNotFound(kid: None))
      end
  end

  sig_bytes = try decode_b64u_trimmed(sig_b64).or_fail(
    SignatureInvalid(reason: "JWT signature is not valid base64url")
  )
  signing_input = "#{hdr_b64}.#{payload_b64}".bytes
  sig_ok? = case Crypto.verify_signature(verify_alg, verify_pub, signing_input, sig_bytes)
    Ok(b): b
    Error(e): return Error(CryptoFailed(e))
  end
  if not sig_ok?
    return Error(SignatureInvalid(reason: "JWT signature failed verification"))
  end

  claims = try decode_jwt_payload(jwt)
  epoch = Time.parse("1970-01-01T00:00:00Z") or now
  now_sec = (now - epoch).in_milliseconds.floor_div(1000)
  skew = if clock_skew_seconds < 0: 0 else: clock_skew_seconds

  exp_sec = try claims.int_at("exp").or_fail(BadPayload(reason: "JWT missing exp claim"))
  if exp_sec + skew <= now_sec
    return Error(IdentityMismatch(reason: "JWT is expired"))
  end
  if claims.int_at("nbf") is Some(nbf_sec)
    if nbf_sec - skew > now_sec
      return Error(IdentityMismatch(reason: "JWT is not valid yet (nbf)"))
    end
  end
  if claims.int_at("iat") is Some(iat_sec)
    if iat_sec - skew > now_sec
      return Error(IdentityMismatch(reason: "JWT issued in the future (iat)"))
    end
  end
  Ok(claims)
end

## Queries GitHub's `/user/emails` endpoint and returns the normalized verified primary email.
fn github_fetch_verified_primary_email(access_token: Text, network: Network) : Result(
  Text,
  OidcError
)
  req = Http.get("https://api.github.com/user/emails").header(
    "Authorization",
    "Bearer #{access_token}"
  ).header("Accept", "application/vnd.github+json").header("User-Agent", "Arvo-OAuth")
  res = case req.send(network)
    Ok(r): r
    Error(e): return Error(HttpFailed(e))
  end
  if res.status != 200
    return Error(UnexpectedStatus(status: res.status, body: res.text or ""))
  end
  arr = case Json.parse(res.text or "")
    Ok(Json.Array(items)): items
    Ok(_) | Error(_): return Error(BadPayload(reason: "GitHub /user/emails must be a JSON array"))
  end
  var primary_unverified = None
  for item in arr
    em = item.text_at("email") or ""
    primary? = item.bool_at("primary") or false
    verified? = item.bool_at("verified") or false
    if primary? and verified? and not Auth.normalize_email(em).empty?
      return Ok(Auth.normalize_email(em))
    else if primary?
      primary_unverified = Some(Auth.normalize_email(em))
    end
  end
  case primary_unverified
    Some(em) if not em.empty?: Error(EmailUnverified(email: em))
    Some(_) | None: Error(BadPayload(reason: "GitHub /user/emails has no primary verified address"))
  end
end

## Keyring-backed OIDC login initiation sealing state under the active primary keyring key.
fn start_login_with_keyring(
  cfg: OidcConfig,
  keyring: Keyring.Keyring,
  rng: SecureRandom,
  clock: Clock,
  return_to: Option(Text)
) : Result(Api.Response, OidcError)
  _ = try validate_config(cfg)
  (auth_state, auth_url) = encode_auth_state(cfg, rng, clock, return_to)
  cookie_val = try Keyring.seal(
    rng,
    keyring,
    Json.encode(auth_state).bytes,
    state_aad(cfg.cookie_name)
  ).map_error(fn(_e) InvalidKey end)
  opts = Cookie.CookieOptions(
    path: "/",
    max_age: Some(cfg.state_ttl_seconds),
    http_only?: true,
    secure?: cfg.secure_cookie?,
    same_site: Cookie.Lax
  )
  Ok(Cookie.set(Api.redirect(auth_url), cfg.cookie_name, cookie_val, opts))
end

fn unseal_auth_state_with_keyring(req: Api.Request, cfg: OidcConfig, keyring: Keyring.Keyring) : Result(
  AuthState,
  OidcError
)
  raw_cookie = case Cookie.get(req, cfg.cookie_name)
    Some(c): c
    None: return Error(MissingStateCookie)
  end
  opened = case Keyring.open(keyring, raw_cookie, state_aad(cfg.cookie_name))
    Some(o): o
    None: return Error(InvalidStateCookie)
  end
  case Json.decode_strict[AuthState](opened.plaintext)
    Ok(st) if st.provider_id == cfg.provider_id: Ok(st)
    Ok(_) | Error(_): Error(InvalidStateCookie)
  end
end

## Keyring-backed OIDC callback requiring full JWKS cryptographic signature verification when `id_token` is present.
fn complete_callback_verified(
  cfg: OidcConfig,
  req: Api.Request,
  keyring: Keyring.Keyring,
  clock: Clock,
  network: Network
) : Result(OidcIdentity, OidcError)
  _ = try validate_config(cfg)
  case Api.query_param(req, "error")
    Some(err_code): return Error(
      ProviderError(code: err_code, description: Api.query_param(req, "error_description"))
    )
    None: Unit
  end

  auth_state = try unseal_auth_state_with_keyring(req, cfg, keyring)
  now = clock.now
  return Error(StateExpired) if now >= auth_state.expires_at

  got_state = Api.query_param(req, "state") or ""
  if got_state.empty? or not Crypto.constant_time_eq?(got_state.bytes, auth_state.state.bytes)
    return Error(StateMismatch)
  end
  code = Api.query_param(req, "code") or ""
  return Error(MissingCode) if code.empty?

  tok_res = case token_exchange_request(cfg, code, auth_state.code_verifier).send(network)
    Ok(r): r
    Error(e): return Error(HttpFailed(e))
  end
  if tok_res.status != 200
    return Error(UnexpectedStatus(status: tok_res.status, body: tok_res.text or ""))
  end
  tok_bytes = (tok_res.text or "").bytes
  tok = case Json.decode[TokenResponse](tok_bytes)
    Ok(t) if not t.access_token.empty?: t
    Ok(_) | Error(_): return Error(BadPayload(reason: "token response missing valid access_token"))
  end

  var id_claims_opt = None
  var id_sub_opt = None
  if tok.id_token is Some(jwt)
    jwks_uri = try cfg.endpoints.jwks_uri.or_fail(
      InvalidConfig(reason: "jwks_uri is required for cryptographically verified OIDC callbacks")
    )
    jwks = try fetch_jwks(jwks_uri, network)
    claims = try verify_jwt_with_jwks(jwt, jwks, now, 60)
    sub = try validate_id_token_claims(cfg, claims, auth_state.nonce, now)
    id_claims_opt = Some(claims)
    id_sub_opt = Some(sub)
  end

  finish_identity_from_claims(cfg, tok.access_token, auth_state, id_claims_opt, id_sub_opt, network)
end

fn finish_identity_from_claims(
  cfg: OidcConfig,
  access_token: Text,
  auth_state: AuthState,
  id_claims_opt: Option(Json),
  id_sub_opt: Option(Text),
  network: Network
) : Result(OidcIdentity, OidcError)
  var ui_claims_opt = None
  if cfg.endpoints.userinfo_endpoint is Some(ui_url)
    ui_res = case userinfo_request(ui_url, access_token).send(network)
      Ok(r): r
      Error(e): return Error(HttpFailed(e))
    end
    if ui_res.status != 200
      return Error(UnexpectedStatus(status: ui_res.status, body: ui_res.text or ""))
    end
    ui_doc = try parse_json_object(ui_res.text or "", "userinfo response")
    ui_sub = try ui_doc.text_at("sub").or_fail(BadPayload(reason: "userinfo missing sub"))
    return Error(BadPayload(reason: "userinfo sub cannot be empty")) if ui_sub.empty?
    if id_sub_opt is Some(id_sub) and ui_sub != id_sub
      return Error(IdentityMismatch(reason: "userinfo sub '#{ui_sub}' != id_token sub '#{id_sub}'"))
    end
    ui_claims_opt = Some(ui_doc)
  end

  if id_claims_opt is None and ui_claims_opt is None
    return Error(BadPayload(reason: "neither id_token nor userinfo_endpoint supplied claims"))
  end

  subject = case ui_claims_opt
    Some(u): u.text_at("sub") or (id_sub_opt or "")
    None: id_sub_opt or ""
  end
  raw_email = case ui_claims_opt
    Some(u): u.text_at("email") or
      case id_claims_opt
        Some(c): c.text_at("email") or ""
        None: ""
      end
    None:
      case id_claims_opt
        Some(c): c.text_at("email") or ""
        None: ""
      end
  end
  if subject.empty? or raw_email.empty?
    return Error(BadPayload(reason: "OIDC claims missing required sub or email"))
  end

  verified? = case ui_claims_opt
    Some(u):
      case u.bool_at("email_verified")
        Some(b): b
        None:
          case id_claims_opt
            Some(c): c.bool_at("email_verified") or false
            None: false
          end
      end
    None:
      case id_claims_opt
        Some(c): c.bool_at("email_verified") or false
        None: false
      end
  end

  norm_email = Auth.normalize_email(raw_email)
  if cfg.require_verified_email? and not verified?
    return Error(EmailUnverified(email: norm_email))
  end
  if not email_domain_allowed?(norm_email, cfg.allowed_domains)
    return Error(EmailDomainNotAllowed(email: norm_email))
  end

  name = case ui_claims_opt
    Some(u):
      case u.text_at("name")
        Some(n): Some(n)
        None:
          case id_claims_opt
            Some(c): c.text_at("name")
            None: None
          end
      end
    None:
      case id_claims_opt
        Some(c): c.text_at("name")
        None: None
      end
  end
  picture = case ui_claims_opt
    Some(u):
      case u.text_at("picture")
        Some(p): Some(p)
        None:
          case id_claims_opt
            Some(c): c.text_at("picture")
            None: None
          end
      end
    None:
      case id_claims_opt
        Some(c): c.text_at("picture")
        None: None
      end
  end

  Ok(
    OidcIdentity(
      provider_id: cfg.provider_id,
      issuer: cfg.endpoints.issuer,
      subject: subject,
      email: norm_email,
      email_verified?: verified?,
      name: name,
      picture: picture,
      return_to: auth_state.return_to
    )
  )
end

## Initiates an OIDC Authorization Code + PKCE (`S256`) login, returning a `302` redirect
## response carrying an `HttpOnly; SameSite=Lax` AES-256-GCM state/nonce/verifier cookie.
fn start_login(
  cfg: OidcConfig,
  key: Bytes,
  rng: SecureRandom,
  clock: Clock,
  return_to: Option(Text)
) : Result(Api.Response, OidcError)
  _ = try validate_config(cfg)
  return Error(InvalidKey) if key.size != 32

  state = rng.bytes(32).to_base64url
  nonce = rng.bytes(32).to_base64url
  code_verifier = rng.bytes(32).to_base64url
  ret = safe_return_to(return_to)
  now = clock.now
  auth_state = AuthState(
    provider_id: cfg.provider_id,
    state: state,
    nonce: nonce,
    code_verifier: code_verifier,
    return_to: ret,
    issued_at: now,
    expires_at: now + cfg.state_ttl_seconds.seconds
  )

  seal_nonce = rng.bytes(12)
  ciphertext = case Crypto.seal(
    key,
    seal_nonce,
    Json.encode(auth_state).bytes,
    state_aad(cfg.cookie_name)
  )
    Ok(ct): ct
    Error(e): return Error(CryptoFailed(e))
  end
  cookie_val = Bytes.join([seal_nonce, ciphertext]).to_base64url

  auth_req = Http.get(cfg.endpoints.authorization_endpoint).query("response_type", "code").query(
    "client_id",
    cfg.client_id
  ).query("redirect_uri", cfg.redirect_uri).query("scope", cfg.scopes.join(" ")).query(
    "state",
    state
  ).query("nonce", nonce).query("code_challenge", pkce_challenge_s256(code_verifier)).query(
    "code_challenge_method",
    "S256"
  )

  opts = Cookie.CookieOptions(
    path: "/",
    max_age: Some(cfg.state_ttl_seconds),
    http_only?: true,
    secure?: cfg.secure_cookie?,
    same_site: Cookie.Lax
  )
  Ok(Cookie.set(Api.redirect(auth_req.url), cfg.cookie_name, cookie_val, opts))
end

## Appends a `Set-Cookie` clearing `cfg.cookie_name` after callback completion.
fn clear_state_cookie(res: Api.Response, cfg: OidcConfig) : Api.Response
  Cookie.clear(res, cfg.cookie_name, "/", cfg.secure_cookie?)
end

## Builds the exact OAuth2 `authorization_code` token exchange `Http.Request`.
fn token_exchange_request(cfg: OidcConfig, code: Text, code_verifier: Text) : Http.Request
  var pairs = [
    ("grant_type", "authorization_code"),
    ("code", code),
    ("redirect_uri", cfg.redirect_uri),
    ("client_id", cfg.client_id),
    ("code_verifier", code_verifier)
  ]
  if not cfg.client_secret.empty?
    pairs = pairs.append(("client_secret", cfg.client_secret))
  end
  Http.post(cfg.endpoints.token_endpoint).header("Accept", "application/json").form(pairs)
end

## Builds the OIDC UserInfo `GET` request carrying the Bearer `access_token`.
fn userinfo_request(userinfo_url: Text, access_token: Text) : Http.Request
  Http.get(userinfo_url).header("Authorization", "Bearer #{access_token}").header(
    "Accept",
    "application/json"
  )
end

fn unseal_auth_state(req: Api.Request, cfg: OidcConfig, key: Bytes) : Result(AuthState, OidcError)
  raw_cookie = case Cookie.get(req, cfg.cookie_name)
    Some(c): c
    None: return Error(MissingStateCookie)
  end
  decoded = case Bytes.from_base64url(raw_cookie)
    Some(b) if b.size >= 28: b
    Some(_) | None: return Error(InvalidStateCookie)
  end
  seal_nonce = decoded.slice(0, 12)
  ciphertext = decoded.slice(12, decoded.size)
  plaintext = case Crypto.open(key, seal_nonce, ciphertext, state_aad(cfg.cookie_name))
    Ok(pt): pt
    Error(_): return Error(InvalidStateCookie)
  end
  case Json.decode_strict[AuthState](plaintext)
    Ok(st) if st.provider_id == cfg.provider_id: Ok(st)
    Ok(_) | Error(_): Error(InvalidStateCookie)
  end
end

fn aud_matches?(claims: Json, client_id: Text) : Bool
  case claims.get("aud")
    Some(Json.String(s)): s == client_id
    Some(Json.Array(items)): items.any?(fn(item) item == Json.String(client_id) end)
    Some(_) | None: false
  end
end

fn validate_id_token_claims(cfg: OidcConfig, claims: Json, expected_nonce: Text, now: Time) : Result(
  Text,
  OidcError
)
  iss = try claims.text_at("iss").or_fail(BadPayload(reason: "id_token missing iss"))
  if trim_trailing_slash(iss) != trim_trailing_slash(cfg.endpoints.issuer)
    return Error(IdentityMismatch(reason: "id_token iss '#{iss}' mismatch"))
  end
  if not aud_matches?(claims, cfg.client_id)
    return Error(IdentityMismatch(reason: "id_token aud does not include client_id"))
  end

  exp_sec = try claims.int_at("exp").or_fail(BadPayload(reason: "id_token missing exp"))
  epoch = Time.parse("1970-01-01T00:00:00Z") or now
  now_sec = (now - epoch).in_milliseconds.floor_div(1000)
  if exp_sec <= now_sec
    return Error(IdentityMismatch(reason: "id_token is expired"))
  end

  got_nonce = try claims.text_at("nonce").or_fail(BadPayload(reason: "id_token missing nonce"))
  if not Crypto.constant_time_eq?(got_nonce.bytes, expected_nonce.bytes)
    return Error(IdentityMismatch(reason: "id_token nonce mismatch"))
  end

  sub = try claims.text_at("sub").or_fail(BadPayload(reason: "id_token missing sub"))
  if sub.empty?
    return Error(BadPayload(reason: "id_token sub cannot be empty"))
  end
  Ok(sub)
end

## Verifies state cookie, exchanges authorization code with PKCE, checks `id_token`/`userinfo`
## consistency, and enforces email verification and domain allowlists.
fn complete_callback(cfg: OidcConfig, req: Api.Request, key: Bytes, clock: Clock, network: Network) : Result(
  OidcIdentity,
  OidcError
)
  _ = try validate_config(cfg)
  return Error(InvalidKey) if key.size != 32

  case Api.query_param(req, "error")
    Some(err_code): return Error(
      ProviderError(code: err_code, description: Api.query_param(req, "error_description"))
    )
    None: Unit
  end

  auth_state = try unseal_auth_state(req, cfg, key)
  now = clock.now
  if now >= auth_state.expires_at
    return Error(StateExpired)
  end

  got_state = Api.query_param(req, "state") or ""
  if got_state.empty? or not Crypto.constant_time_eq?(got_state.bytes, auth_state.state.bytes)
    return Error(StateMismatch)
  end

  code = Api.query_param(req, "code") or ""
  if code.empty?
    return Error(MissingCode)
  end

  tok_res = case token_exchange_request(cfg, code, auth_state.code_verifier).send(network)
    Ok(r): r
    Error(e): return Error(HttpFailed(e))
  end
  if tok_res.status != 200
    return Error(UnexpectedStatus(status: tok_res.status, body: tok_res.text or ""))
  end
  tok_bytes = (tok_res.text or "").bytes
  tok = case Json.decode[TokenResponse](tok_bytes)
    Ok(t) if not t.access_token.empty?: t
    Ok(_) | Error(_): return Error(BadPayload(reason: "token response missing valid access_token"))
  end

  var id_claims_opt = None
  var id_sub_opt = None
  case tok.id_token
    Some(jwt):
      claims = try decode_jwt_payload(jwt)
      sub = try validate_id_token_claims(cfg, claims, auth_state.nonce, now)
      id_claims_opt = Some(claims)
      id_sub_opt = Some(sub)
    None: Unit
  end

  var ui_claims_opt = None
  case cfg.endpoints.userinfo_endpoint
    Some(ui_url):
      ui_res = case userinfo_request(ui_url, tok.access_token).send(network)
        Ok(r): r
        Error(e): return Error(HttpFailed(e))
      end
      if ui_res.status != 200
        return Error(UnexpectedStatus(status: ui_res.status, body: ui_res.text or ""))
      end
      ui_doc = try parse_json_object(ui_res.text or "", "userinfo response")
      ui_sub = try ui_doc.text_at("sub").or_fail(BadPayload(reason: "userinfo missing sub"))
      if ui_sub.empty?
        return Error(BadPayload(reason: "userinfo sub cannot be empty"))
      end
      case id_sub_opt
        Some(id_sub):
          if ui_sub != id_sub
            return Error(
              IdentityMismatch(reason: "userinfo sub '#{ui_sub}' != id_token sub '#{id_sub}'")
            )
          end
        None: Unit
      end
      ui_claims_opt = Some(ui_doc)
    None: Unit
  end

  if id_claims_opt is None and ui_claims_opt is None
    return Error(BadPayload(reason: "neither id_token nor userinfo_endpoint supplied claims"))
  end

  subject = case ui_claims_opt
    Some(u): u.text_at("sub") or (id_sub_opt or "")
    None: id_sub_opt or ""
  end
  raw_email = case ui_claims_opt
    Some(u): u.text_at("email") or
      case id_claims_opt
        Some(c): c.text_at("email") or ""
        None: ""
      end
    None:
      case id_claims_opt
        Some(c): c.text_at("email") or ""
        None: ""
      end
  end
  if subject.empty? or raw_email.empty?
    return Error(BadPayload(reason: "OIDC claims missing required sub or email"))
  end

  verified? = case ui_claims_opt
    Some(u):
      case u.bool_at("email_verified")
        Some(b): b
        None:
          case id_claims_opt
            Some(c): c.bool_at("email_verified") or false
            None: false
          end
      end
    None:
      case id_claims_opt
        Some(c): c.bool_at("email_verified") or false
        None: false
      end
  end

  norm_email = Auth.normalize_email(raw_email)
  if cfg.require_verified_email? and not verified?
    return Error(EmailUnverified(email: norm_email))
  end
  if not email_domain_allowed?(norm_email, cfg.allowed_domains)
    return Error(EmailDomainNotAllowed(email: norm_email))
  end

  name = case ui_claims_opt
    Some(u):
      case u.text_at("name")
        Some(n): Some(n)
        None:
          case id_claims_opt
            Some(c): c.text_at("name")
            None: None
          end
      end
    None:
      case id_claims_opt
        Some(c): c.text_at("name")
        None: None
      end
  end
  picture = case ui_claims_opt
    Some(u):
      case u.text_at("picture")
        Some(p): Some(p)
        None:
          case id_claims_opt
            Some(c): c.text_at("picture")
            None: None
          end
      end
    None:
      case id_claims_opt
        Some(c): c.text_at("picture")
        None: None
      end
  end

  Ok(
    OidcIdentity(
      provider_id: cfg.provider_id,
      issuer: cfg.endpoints.issuer,
      subject: subject,
      email: norm_email,
      email_verified?: verified?,
      name: name,
      picture: picture,
      return_to: auth_state.return_to
    )
  )
end

fn test_oidc_config(allowed_domains: List(Text)) : OidcConfig
  OidcConfig(
    provider_id: "dex",
    client_id: "vellum-web",
    client_secret: "secret-123",
    redirect_uri: "https://vellum.example.com/auth/oidc/callback",
    scopes: default_scopes(),
    endpoints: ProviderEndpoints(
      issuer: "https://auth.example.com",
      authorization_endpoint: "https://auth.example.com/authorize",
      token_endpoint: "https://auth.example.com/token",
      userinfo_endpoint: Some("https://auth.example.com/userinfo"),
      jwks_uri: Some("https://auth.example.com/keys")
    ),
    allowed_domains: allowed_domains,
    require_verified_email?: true,
    cookie_name: "vellum_oidc_state",
    state_ttl_seconds: 600,
    secure_cookie?: true
  )
end

fn cookie_pair_from_response(res: Api.Response) : Text
  set_hdr = res.header("Set-Cookie") or ""
  (set_hdr.split(";").first or "").trim
end

test "OIDC discovery happy path and issuer mismatch rejection"
  good_doc = Json.Object({
    "issuer": Json.String("https://auth.example.com"),
    "authorization_endpoint": Json.String("https://auth.example.com/authorize"),
    "token_endpoint": Json.String("https://auth.example.com/token"),
    "userinfo_endpoint": Json.String("https://auth.example.com/userinfo"),
    "jwks_uri": Json.String("https://auth.example.com/keys")
  })
  disc_req = Http.get("https://auth.example.com/.well-known/openid-configuration").header(
    "Accept",
    "application/json"
  )
  net_ok = Network.fake(Http.replies([(disc_req, Http.reply(200, good_doc.to_text))]))
  assert discover("https://auth.example.com/", net_ok) is Ok(ep)
  assert ep.token_endpoint == "https://auth.example.com/token"
  assert ep.userinfo_endpoint == Some("https://auth.example.com/userinfo")

  bad_doc = Json.Object({
    "issuer": Json.String("https://evil.example.com"),
    "authorization_endpoint": Json.String("https://auth.example.com/authorize"),
    "token_endpoint": Json.String("https://auth.example.com/token")
  })
  net_bad = Network.fake(Http.replies([(disc_req, Http.reply(200, bad_doc.to_text))]))
  assert discover("https://auth.example.com", net_bad) is Error(IdentityMismatch(reason: _))
end

test "OIDC full start_login -> complete_callback flow and fail-closed security matrix"
  cfg = test_oidc_config(["acme.io"])
  rng = SecureRandom.seeded(20261126)
  key = rng.bytes(32)
  wrong_key = SecureRandom.seeded(999).bytes(32)
  t0 = Time.parse("2026-11-26T12:00:00Z") or stop "t0"
  clock0 = Clock.fixed(t0)

  ## 1. Initiate login with open-redirect attempt -> neutralized to "/" and encrypted state cookie set.
  assert start_login(cfg, key, rng, clock0, Some("https://evil.com")) is Ok(redir)
  assert redir.status == 302
  loc = redir.header("Location") or ""
  assert loc.starts_with?("https://auth.example.com/authorize?")
  assert loc.contains?("code_challenge_method=S256")
  cookie_pair = cookie_pair_from_response(redir)
  assert cookie_pair.starts_with?("vellum_oidc_state=")

  ## Extract generated state, nonce, and code_verifier from sealed state by calling start_login
  ## redirect URL + verifying deterministic PKCE challenge matches callback verifier.
  q_params = Api.request("GET", loc).query
  state = q_params.find(fn(p) p.0 == "state" end).map(fn(p) p.1 end) or stop "state"
  nonce = q_params.find(fn(p) p.0 == "nonce" end).map(fn(p) p.1 end) or stop "nonce"

  ## Read back AuthState via unseal helper in same module so test network stubs exact code_verifier.
  fake_req = Api.get("/auth/oidc/callback").with_header("Cookie", cookie_pair)
  assert unseal_auth_state(fake_req, cfg, key) is Ok(sealed_state)
  assert sealed_state.return_to == "/"
  assert sealed_state.state == state
  assert sealed_state.nonce == nonce

  id_claims = Json.Object({
    "iss": Json.String("https://auth.example.com"),
    "aud": Json.String("vellum-web"),
    "sub": Json.String("sub_ada"),
    "nonce": Json.String(nonce),
    "exp": Json.int(1800000000),
    "email": Json.String("Ada@ACME.IO"),
    "email_verified": Json.Boolean(true)
  })
  id_jwt = build_unsigned_test_jwt(id_claims)
  tok_body = Json.Object({
    "access_token": Json.String("at_live_1"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(id_jwt)
  }).to_text
  ui_body = Json.Object({
    "sub": Json.String("sub_ada"),
    "email": Json.String("Ada@ACME.IO"),
    "email_verified": Json.Boolean(true),
    "name": Json.String("Ada Lovelace"),
    "picture": Json.String("https://cdn.acme.io/ada.png")
  }).to_text

  tok_req = token_exchange_request(cfg, "code_ok", sealed_state.code_verifier)
  ui_req = userinfo_request("https://auth.example.com/userinfo", "at_live_1")
  net_ok = Network.fake(
    Http.replies([(tok_req, Http.reply(200, tok_body)), (ui_req, Http.reply(200, ui_body))])
  )

  cb_ok = Api.get("/auth/oidc/callback?code=code_ok&state=#{state}").with_header(
    "Cookie",
    cookie_pair
  )
  assert complete_callback(cfg, cb_ok, key, clock0, net_ok) is Ok(ident)
  assert ident ==
    OidcIdentity(
      provider_id: "dex",
      issuer: "https://auth.example.com",
      subject: "sub_ada",
      email: "ada@acme.io",
      email_verified?: true,
      name: Some("Ada Lovelace"),
      picture: Some("https://cdn.acme.io/ada.png"),
      return_to: "/"
    )

  cleared = clear_state_cookie(Api.redirect_see_other(ident.return_to), cfg)
  assert (cleared.header("Set-Cookie") or "").contains?("vellum_oidc_state=; Path=/; Max-Age=0")

  ## 2. Fail-closed checks: missing/tampered/wrong-key/expired/state-mismatch/provider-error.
  assert complete_callback(cfg, Api.get("/auth/oidc/callback?code=c&state=s"), key, clock0, net_ok) ==
    Error(MissingStateCookie)
  tampered = Api.get("/auth/oidc/callback?code=c&state=#{state}").with_header(
    "Cookie",
    "vellum_oidc_state=badciphertext"
  )
  assert complete_callback(cfg, tampered, key, clock0, net_ok) == Error(InvalidStateCookie)
  assert complete_callback(cfg, cb_ok, wrong_key, clock0, net_ok) == Error(InvalidStateCookie)

  bad_state = Api.get("/auth/oidc/callback?code=code_ok&state=wrong").with_header(
    "Cookie",
    cookie_pair
  )
  assert complete_callback(cfg, bad_state, key, clock0, net_ok) == Error(StateMismatch)

  expired_clock = Clock.fixed(t0 + 601.seconds)
  assert complete_callback(cfg, cb_ok, key, expired_clock, net_ok) == Error(StateExpired)

  err_cb = Api.get("/auth/oidc/callback?error=access_denied&error_description=User%20denied")
  assert complete_callback(cfg, err_cb, key, clock0, net_ok) ==
    Error(ProviderError(code: "access_denied", description: Some("User denied")))

  ## 3. Fail-closed claim checks: nonce mismatch, userinfo sub mismatch, unverified email, wrong domain.
  bad_nonce_jwt = build_unsigned_test_jwt(
    Json.Object({
      "iss": Json.String("https://auth.example.com"),
      "aud": Json.String("vellum-web"),
      "sub": Json.String("sub_ada"),
      "nonce": Json.String("wrong_nonce"),
      "exp": Json.int(1800000000),
      "email": Json.String("ada@acme.io"),
      "email_verified": Json.Boolean(true)
    })
  )
  bad_nonce_tok = Json.Object({
    "access_token": Json.String("at_live_1"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(bad_nonce_jwt)
  }).to_text
  net_bad_nonce = Network.fake(Http.replies([(tok_req, Http.reply(200, bad_nonce_tok))]))
  assert complete_callback(cfg, cb_ok, key, clock0, net_bad_nonce) is
    Error(IdentityMismatch(reason: _))

  mismatch_ui = Json.Object({
    "sub": Json.String("sub_other"),
    "email": Json.String("ada@acme.io"),
    "email_verified": Json.Boolean(true)
  }).to_text
  net_sub_mismatch = Network.fake(
    Http.replies([(tok_req, Http.reply(200, tok_body)), (ui_req, Http.reply(200, mismatch_ui))])
  )
  assert complete_callback(cfg, cb_ok, key, clock0, net_sub_mismatch) is
    Error(IdentityMismatch(reason: _))

  unverified_ui = Json.Object({
    "sub": Json.String("sub_ada"),
    "email": Json.String("ada@acme.io"),
    "email_verified": Json.Boolean(false)
  }).to_text
  net_unverified = Network.fake(
    Http.replies([(tok_req, Http.reply(200, tok_body)), (ui_req, Http.reply(200, unverified_ui))])
  )
  assert complete_callback(cfg, cb_ok, key, clock0, net_unverified) ==
    Error(EmailUnverified(email: "ada@acme.io"))

  wrong_dom_ui = Json.Object({
    "sub": Json.String("sub_ada"),
    "email": Json.String("ada@outsider.io"),
    "email_verified": Json.Boolean(true)
  }).to_text
  net_wrong_dom = Network.fake(
    Http.replies([(tok_req, Http.reply(200, tok_body)), (ui_req, Http.reply(200, wrong_dom_ui))])
  )
  assert complete_callback(cfg, cb_ok, key, clock0, net_wrong_dom) ==
    Error(EmailDomainNotAllowed(email: "ada@outsider.io"))
end

test "OIDC JWKS RS256/ES256/EdDSA verification, Keyring rotation, GitHub/Microsoft/Okta presets"
  jwks_json = "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"rsa-1\",\"alg\":\"RS256\",\"use\":\"sig\",\"n\":\"ngUiQhsJLxBLpmcl3WftJ05w5GMOSmlg95UxVSLtdxltnRvvj7BCcTBUijBGlcHKClWUf3lvpVkQu4b4Glayl2yQmbN_tgngVgBxlx4jj2tLurhhDpMvuBQYna_BAhEaCdFGQ3CX4-hGRrxBmHd3LBxDpcKE57RKRpnFjtRlWhuXZ7wgR_PP84H46lJiHwnAyicoldfGpBjFLwS0vEWXsiq0avfWLYHz7OMTA4Jh7HkVHC6moRYT4uvMQJAbP1A15_Jx2g6-D6D3EsxIWXRv1J41ZH6Zv26278tb7ssQF9abX4HGuEXOAAahkkANBq-GeTZieWNgYZb0FB1kLXWRHQ\",\"e\":\"AQAB\"},{\"kty\":\"EC\",\"crv\":\"P-256\",\"kid\":\"ec-1\",\"alg\":\"ES256\",\"use\":\"sig\",\"x\":\"Q8T0gVCmRhLsGoLgNc5_x6WD4EtaUvo381iAWAoB6n8\",\"y\":\"-bkEaUU00kZA9zsblB_86pCgozPMMTh8Xd7-FbQW44Y\"},{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"kid\":\"ed-1\",\"alg\":\"EdDSA\",\"use\":\"sig\",\"x\":\"Fi-D1425tS1OjiAYeC7TUYhjErLzRiSETuEePNBAwxo\"}]}"

  jwks = case parse_jwks(jwks_json)
    Ok(ks): ks
    Error(_): stop "parse_jwks"
  end
  assert jwks.size == 3

  t_valid = Time.parse("2026-11-28T00:00:00Z") or stop "t_valid"
  rs_jwt = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InJzYS0xIn0.eyJpc3MiOiJodHRwczovL2F1dGguZXhhbXBsZS5jb20iLCJhdWQiOiJ2ZWxsdW0td2ViIiwic3ViIjoic3ViX2FkYSIsIm5vbmNlIjoibm9uY2UtZml4ZWQiLCJleHAiOjE5MDAwMDAwMDAsImlhdCI6MTcwMDAwMDAwMCwiZW1haWwiOiJBZGFAQUNNRS5JTyIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJuYW1lIjoiQWRhIn0.RabPLQamBqxMkq3euIhanRBnnLg4zFeMO5qXxEauu5aeHr5NYaJzeLhMvzLCl1WRyY4PYBbwpBuKLIzQI8FxRwpidhRDkGZgktA08kYL_0yY4sb5yllG94D8yZ0hjr6xvJH0xtMrcvfZzDKn4tsUac50UTyx1huxR0w81Xvf3-k30wwBsKg35VLgiOO6QnJXY8tTNfWKgT_-30RvWlpNYElWn4o3Swt_k0Qa3u-RVyM64M19SLR_jTrRHeN6EaHi5-AC5xAn-J5VBnvKbUm-BTAwjlzZeo9cmlg-JhP3OE1xn4hcLLWQ7Y6BGq82OdOn55Ut8hu_bUSnii_h5HgAaw"
  es_jwt = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImVjLTEifQ.eyJpc3MiOiJodHRwczovL2F1dGguZXhhbXBsZS5jb20iLCJhdWQiOiJ2ZWxsdW0td2ViIiwic3ViIjoic3ViX2FkYSIsIm5vbmNlIjoibm9uY2UtZml4ZWQiLCJleHAiOjE5MDAwMDAwMDAsImlhdCI6MTcwMDAwMDAwMCwiZW1haWwiOiJBZGFAQUNNRS5JTyIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJuYW1lIjoiQWRhIn0.LYiMM6GhFHE4edKkXoYENYh1z6z8kC7hZANc9mni5zuTTYDjlrXBIscv--xDlWDzEWKogCynKzEjTgd-YGjNNw"
  ed_jwt = "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCIsImtpZCI6ImVkLTEifQ.eyJpc3MiOiJodHRwczovL2F1dGguZXhhbXBsZS5jb20iLCJhdWQiOiJ2ZWxsdW0td2ViIiwic3ViIjoic3ViX2FkYSIsIm5vbmNlIjoibm9uY2UtZml4ZWQiLCJleHAiOjE5MDAwMDAwMDAsImlhdCI6MTcwMDAwMDAwMCwiZW1haWwiOiJBZGFAQUNNRS5JTyIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJuYW1lIjoiQWRhIn0.RoJ5F-6RHt32dtCQRXtsjHmOZ-L_slvHf2ccUKSwOXCRy8EGcBPFbXftB5Hd0KDEBMWt-tPFfNmRpQI1qQviAA"

  assert verify_jwt_with_jwks(rs_jwt, jwks, t_valid, 60) is Ok(c_rs)
  assert c_rs.text_at("sub") == Some("sub_ada")
  assert verify_jwt_with_jwks(es_jwt, jwks, t_valid, 60) is Ok(_)
  assert verify_jwt_with_jwks(ed_jwt, jwks, t_valid, 60) is Ok(_)

  # Tampered signature, alg=none, unknown kid, and expired time are all rejected
  assert verify_jwt_with_jwks("#{ed_jwt.drop_suffix("AA") or ed_jwt}AB", jwks, t_valid, 60) is
    Error(SignatureInvalid(reason: _))
  alg_none = build_unsigned_test_jwt(c_rs)
  assert verify_jwt_with_jwks(alg_none, jwks, t_valid, 60) == Error(UnsupportedJwtAlg(alg: "none"))
  bad_hdr_jwt = "#{"{\"alg\":\"RS256\",\"kid\":\"missing\"}".bytes.to_base64url}.#{(
    ed_jwt.split(".").get(1) or ""
  )}.sig"
  assert verify_jwt_with_jwks(bad_hdr_jwt, jwks, t_valid, 60) ==
    Error(KeyNotFound(kid: Some("missing")))
  t_future = Time.parse("2035-01-01T00:00:00Z") or stop "t_future"
  assert verify_jwt_with_jwks(ed_jwt, jwks, t_future, 0) is Error(IdentityMismatch(reason: _))

  # Keyring rotation across start_login_with_keyring -> complete_callback_verified
  cfg = test_oidc_config(["acme.io"])
  rng = SecureRandom.seeded(9876)
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
  redir = case start_login_with_keyring(cfg, kr1, rng, Clock.fixed(t_valid), Some("/dashboard"))
    Ok(r): r
    Error(_): stop "start_login_with_keyring"
  end
  cpair = cookie_pair_from_response(redir)
  loc = redir.header("Location") or ""
  st_val = Api.request("GET", loc).query.find(fn(p) p.0 == "state" end).map(fn(p) p.1 end) or
    stop "st"
  st_req = Api.get("/auth/oidc/callback").with_header("Cookie", cpair)
  auth_st = case unseal_auth_state_with_keyring(st_req, cfg, kr2)
    Ok(s): s
    Error(_): stop "unseal kr2"
  end
  tok_req = token_exchange_request(cfg, "code_kr", auth_st.code_verifier)
  ui_req = userinfo_request("https://auth.example.com/userinfo", "at_kr")
  jwks_req = Http.get("https://auth.example.com/keys").header("Accept", "application/json")

  # Reject unsigned id_token when complete_callback_verified is used
  tok_none = Json.Object({
    "access_token": Json.String("at_kr"),
    "token_type": Json.String("Bearer"),
    "id_token": Json.String(alg_none)
  }).to_text
  net_reject_none = Network.fake(
    Http.replies([
      (tok_req, Http.reply(200, tok_none)),
      (jwks_req, Http.reply(200, jwks_json)),
      (ui_req, Http.reply(200, "{}"))
    ])
  )
  cb_req = Api.get("/auth/oidc/callback?code=code_kr&state=#{st_val}").with_header("Cookie", cpair)
  assert complete_callback_verified(cfg, cb_req, kr2, Clock.fixed(t_valid), net_reject_none) ==
    Error(UnsupportedJwtAlg(alg: "none"))

  # UserInfo-only verified flow works across keyring rotation
  tok_ui_only = Json.Object({
    "access_token": Json.String("at_kr"),
    "token_type": Json.String("Bearer")
  }).to_text
  ui_ok = Json.Object({
    "sub": Json.String("sub_ada"),
    "email": Json.String("Ada@ACME.IO"),
    "email_verified": Json.Boolean(true)
  }).to_text
  net_ui_ok = Network.fake(
    Http.replies([(tok_req, Http.reply(200, tok_ui_only)), (ui_req, Http.reply(200, ui_ok))])
  )
  assert complete_callback_verified(cfg, cb_req, kr2, Clock.fixed(t_valid), net_ui_ok) is Ok(id_kr)
  assert id_kr.return_to == "/dashboard" and id_kr.email == "ada@acme.io"

  # Provider presets & GitHub verified primary email lookup
  assert microsoft_endpoints("common").jwks_uri ==
    Some("https://login.microsoftonline.com/common/discovery/v2.0/keys")
  assert okta_endpoints("https://acme.okta.com/").issuer == "https://acme.okta.com/oauth2/default"
  gh_ep = github_oauth_endpoints()
  assert gh_ep.authorization_endpoint == "https://github.com/login/oauth/authorize"

  gh_req = Http.get("https://api.github.com/user/emails").header("Authorization", "Bearer gh_tok")
    .header("Accept", "application/vnd.github+json").header("User-Agent", "Arvo-OAuth")
  gh_body = "[{\"email\":\"alt@example.com\",\"primary\":false,\"verified\":true},{\"email\":\"Ada@GitHub.IO\",\"primary\":true,\"verified\":true}]"
  net_gh = Network.fake(Http.replies([(gh_req, Http.reply(200, gh_body))]))
  assert github_fetch_verified_primary_email("gh_tok", net_gh) == Ok("ada@github.io")
end
