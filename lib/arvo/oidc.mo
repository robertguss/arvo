## OpenID Connect / OAuth 2.0 Authorization Code + PKCE (`S256`) client with AEAD-sealed
## state/nonce cookies, domain allowlists, and deterministic `Network.fake` test support.
module Arvo.Oidc
expose OidcError(..),
ProviderEndpoints(..),
OidcConfig(..),
AuthState(..),
TokenResponse(..),
OidcIdentity(..),
to_text,
default_scopes,
google_endpoints,
validate_config,
pkce_challenge_s256,
safe_return_to,
email_domain_allowed?,
decode_jwt_payload,
build_unsigned_test_jwt,
discover,
start_login,
clear_state_cookie,
token_exchange_request,
userinfo_request,
complete_callback
use Api
use Arvo.Auth
use Arvo.Cookie
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

## Verified OIDC identity returned by `complete_callback`.
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
