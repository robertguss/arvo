## Native authentication core: email normalization, allowlist & signup policy checks,
## scrypt password hashing/timing-safe verification, single-use purpose-bound tokens,
## safe OIDC account-linking rules, dual-cookie login/logout responses, and CSRF guards.
module Arvo.Auth
expose SignupMode(..),
UserStatus(..),
User(..),
AuthIdentity(..),
TokenPurpose(..),
AuthToken(..),
IssuedToken(..),
PasswordPolicy(..),
PasswordValidationError(..),
OidcLinkConfig(..),
OidcLinkDecision(..),
normalize_email,
email_allowed?,
hash_password,
verify_password,
verify_password_timing_safe,
default_password_policy,
validate_password,
hash_raw_token,
issue_auth_token,
token_valid?,
signup_permitted?,
user_active?,
resolve_oidc_link,
status_to_text,
status_from_text,
purpose_to_text,
purpose_from_text,
login_response,
logout_response,
require_csrf
use Api
use Arvo.Csrf
use Arvo.Session
use Crypto

dummy_scrypt_hash = "$scrypt$ln=15,r=8,p=1$YXJ2by10aW1pbmctc2FmZQ$9HxGlzgyhCmq9uFpyfqlcz8eF241d/QsuFAmvYlySAw"

## Controls who may create a brand-new account in the application.
enum SignupMode
  OpenSignup
  InviteOnly
  EmailAllowlist(emails: List(Text))
end

## Account lifecycle state stored on a `User`.
enum UserStatus
  Active
  Suspended
  Deleted
end

## Primary user profile separated from authentication credentials and provider links.
struct User
  id: Text
  email: Text
  email_verified_at: Option(Time)
  display_name: Option(Text)
  avatar_url: Option(Text)
  status: UserStatus
  mfa_enabled?: Bool
  created_at: Time
  updated_at: Time
end

## One linked authentication credential or identity provider (`password`, `google`, `github`, `passkey`, etc.).
struct AuthIdentity
  id: Text
  user_id: Text
  provider: Text
  provider_subject: Text
  email: Text
  password_hash: Option(Text)
  created_at: Time
end

## Domain-separated purpose tag preventing cross-flow token substitution attacks.
enum TokenPurpose
  EmailVerify
  PasswordReset
  MagicLink
  OrgInvite
  EmailChange
end

## Stored single-use SHA-256 token digest record (plaintext `raw_token` never touches disk).
struct AuthToken
  id: Text
  user_id: Option(Text)
  purpose: TokenPurpose
  target_email: Text
  token_hash: Text
  expires_at: Time
  used_at: Option(Time)
  created_at: Time
end

## Newly minted token record paired with the one-time plaintext `raw_token` for delivery.
struct IssuedToken
  token: AuthToken
  raw_token: Text
end

## Minimum character length and maximum UTF-8 byte cap (`scrypt` DoS defense).
struct PasswordPolicy
  min_length: Int
  max_bytes: Int
end

## Structured reasons a candidate password failed `validate_password`.
enum PasswordValidationError
  TooShort(min: Int, got: Int)
  TooLongBytes(max: Int, got: Int)
  Blank
  MatchesEmail
end

## OIDC signup and verified email auto-linking policy.
struct OidcLinkConfig
  signup_mode: SignupMode
  auto_link_verified_oidc?: Bool
end

## Safe resolution outcome returned by `resolve_oidc_link`.
enum OidcLinkDecision
  SignInExisting(user_id: Text)
  LinkAndSignIn(user_id: Text)
  CreateUser(email: Text)
  Reject(reason: Text)
  AccountLinkRequiresLogin(user_id: Text)
end

## Formats a `UserStatus` into canonical lowercase text.
fn status_to_text(st: UserStatus) : Text
  case st
    Active: "active"
    Suspended: "suspended"
    Deleted: "deleted"
  end
end

## Parses a canonical `UserStatus` string.
fn status_from_text(raw: Text) : Option(UserStatus)
  norm = raw.trim.ascii_lowercase
  if norm == "active"
    Some(Active)
  else if norm == "suspended"
    Some(Suspended)
  else if norm == "deleted"
    Some(Deleted)
  else
    None
  end
end

## Formats a `TokenPurpose` into canonical snake_case text.
fn purpose_to_text(p: TokenPurpose) : Text
  case p
    EmailVerify: "email_verify"
    PasswordReset: "password_reset"
    MagicLink: "magic_link"
    OrgInvite: "org_invite"
    EmailChange: "email_change"
  end
end

## Parses a canonical `TokenPurpose` string.
fn purpose_from_text(raw: Text) : Option(TokenPurpose)
  norm = raw.trim.ascii_lowercase
  if norm == "email_verify"
    Some(EmailVerify)
  else if norm == "password_reset"
    Some(PasswordReset)
  else if norm == "magic_link"
    Some(MagicLink)
  else if norm == "org_invite"
    Some(OrgInvite)
  else if norm == "email_change"
    Some(EmailChange)
  else
    None
  end
end

## Trims leading/trailing whitespace and lowercases ASCII letters in `email`.
fn normalize_email(email: Text) : Text
  examples
    normalize_email("  Ada.Lovelace@Example.COM ") == "ada.lovelace@example.com"
  end

  promise "normalize_email is idempotent and trimmed"
    normalize_email(result) == result and result.trim == result
  end

  email.trim.ascii_lowercase
end

## Checks whether `email` matches an entry in `allowlist` (normalized, constant-time per entry).
fn email_allowed?(email: Text, allowlist: List(Text)) : Bool
  examples
    email_allowed?("  ROBERT@example.com ", ["robert@example.com", "wife@example.com"])
    not email_allowed?("intruder@example.com", ["robert@example.com", "wife@example.com"])
    not email_allowed?("", ["robert@example.com"])
  end

  candidate = normalize_email(email)
  return false if candidate.empty?
  cand_bytes = candidate.bytes
  var matched = false
  for entry in allowlist
    norm_entry = normalize_email(entry)
    if not norm_entry.empty? and Crypto.constant_time_eq?(cand_bytes, norm_entry.bytes)
      matched = true
    end
  end
  matched
end

## Draws a fresh 16-byte CSPRNG salt from `rng` and hashes `password` with scrypt (`Crypto.hash_password`).
fn hash_password(rng: SecureRandom, password: Text) : Result(Text, Crypto.CryptoError)
  salt = rng.bytes(16)
  Crypto.hash_password(password, salt)
end

## Verifies `password` against a PHC `$scrypt$...` hash string in constant time.
fn verify_password(password: Text, encoded: Text) : Bool
  Crypto.verify_password(password, encoded)
end

## Verifies `password` against `maybe_hash`, performing a constant-cost dummy scrypt check on `None`
## (and always returning `false` on `None`) to eliminate account-enumeration timing side channels.
fn verify_password_timing_safe(password: Text, maybe_hash: Option(Text)) : Bool
  case maybe_hash
    Some(encoded): Crypto.verify_password(password, encoded)
    None:
      _ = Crypto.verify_password(password, dummy_scrypt_hash)
      false
  end
end

## Default hardened password policy (`min_length: 12`, `max_bytes: 1024`).
fn default_password_policy() : PasswordPolicy
  PasswordPolicy(min_length: 12, max_bytes: 1024)
end

## Validates `password` against non-blank, min char length, max byte DoS limit, and email non-equality.
fn validate_password(password: Text, email: Text, policy: PasswordPolicy) : Result(
  Unit,
  PasswordValidationError
)
  examples
    validate_password("   ", "ada@acme.io", default_password_policy()) == Error(Blank)
    validate_password("shortpw", "ada@acme.io", default_password_policy()) ==
      Error(TooShort(min: 12, got: 7))
    validate_password("Ada@ACME.io ", "ada@acme.io", PasswordPolicy(min_length: 8, max_bytes: 1024)) ==
      Error(MatchesEmail)
    validate_password("a".repeat(1025), "ada@acme.io", default_password_policy()) ==
      Error(TooLongBytes(max: 1024, got: 1025))
    validate_password("correct-horse-battery", "ada@acme.io", default_password_policy()) == Ok(Unit)
  end

  promise "short or oversized passwords always fail closed"
    (password.chars.size < policy.min_length or password.byte_count > policy.max_bytes) implies
      result is Error(_)
  end

  return Error(Blank) if password.trim.empty?
  char_len = password.chars.size
  byte_len = password.byte_count
  return Error(TooLongBytes(max: policy.max_bytes, got: byte_len)) if byte_len > policy.max_bytes
  return Error(TooShort(min: policy.min_length, got: char_len)) if char_len < policy.min_length
  norm_pw = normalize_email(password)
  norm_email = normalize_email(email)
  return Error(MatchesEmail) if not norm_email.empty? and norm_pw == norm_email
  Ok(Unit)
end

## Computes the hex-encoded SHA-256 digest of a plaintext auth token.
fn hash_raw_token(raw_token: Text) : Text
  Crypto.sha256(raw_token.bytes).to_hex
end

## Mints a single-use purpose-bound `IssuedToken` (`raw_token` is never stored inside `token`).
fn issue_auth_token(
  rng: SecureRandom,
  clock: Clock,
  user_id: Option(Text),
  purpose: TokenPurpose,
  target_email: Text,
  ttl_seconds: Int
) : IssuedToken
  now = clock.now
  tok_id = "tok_#{rng.bytes(16).to_hex}"
  raw_token = rng.bytes(32).to_base64url
  token_hash = hash_raw_token(raw_token)
  tok = AuthToken(
    id: tok_id,
    user_id: user_id,
    purpose: purpose,
    target_email: normalize_email(target_email),
    token_hash: token_hash,
    expires_at: now + ttl_seconds.seconds,
    used_at: None,
    created_at: now
  )
  IssuedToken(token: tok, raw_token: raw_token)
end

## Validates a stored `AuthToken` against `raw_token`, `expected_purpose`, optional `expected_email`,
## single-use `used_at`, and strict expiry (`now < expires_at`) using constant-time digest compare.
fn token_valid?(
  stored: AuthToken,
  raw_token: Text,
  expected_purpose: TokenPurpose,
  expected_email: Option(Text),
  now: Time
) : Bool
  examples
    case Time.parse("2026-12-01T00:00:00Z")
      Some(t0):
        tok = AuthToken(
          id: "t1",
          user_id: Some("u1"),
          purpose: PasswordReset,
          target_email: "ada@acme.io",
          token_hash: hash_raw_token("secret-tok"),
          expires_at: t0 + 60.seconds,
          used_at: None,
          created_at: t0
        )
        used = AuthToken(
          id: "t1",
          user_id: Some("u1"),
          purpose: PasswordReset,
          target_email: "ada@acme.io",
          token_hash: hash_raw_token("secret-tok"),
          expires_at: t0 + 60.seconds,
          used_at: Some(t0 + 1.second),
          created_at: t0
        )
        token_valid?(tok, "secret-tok", PasswordReset, Some(" Ada@Acme.io "), t0 + 10.seconds) and
          not token_valid?(tok, "secret-tok", EmailVerify, Some("ada@acme.io"), t0 + 10.seconds) and
          not token_valid?(tok, "secret-tok", PasswordReset, Some("other@acme.io"), t0 + 10.seconds) and
          not token_valid?(tok, "secret-tok", PasswordReset, None, t0 + 60.seconds) and
          not token_valid?(used, "secret-tok", PasswordReset, None, t0 + 10.seconds)
      None: false
    end
  end

  promise "mismatched purpose, consumed token, or expired token always returns false"
    (stored.purpose != expected_purpose or not (stored.used_at is None) or now >= stored.expires_at) implies
      not result
  end

  return false if not (stored.used_at is None)
  return false if now >= stored.expires_at
  return false if stored.purpose != expected_purpose
  return false if raw_token.empty?
  if expected_email is Some(em)
    return false if normalize_email(em) != stored.target_email
  end
  cand_hash = hash_raw_token(raw_token)
  Crypto.constant_time_eq?(stored.token_hash.bytes, cand_hash.bytes)
end

## Returns `true` when `SignupMode` permits registering `email` given `has_valid_invite?`.
fn signup_permitted?(mode: SignupMode, email: Text, has_valid_invite?: Bool) : Bool
  case mode
    OpenSignup: not normalize_email(email).empty?
    InviteOnly: has_valid_invite? and not normalize_email(email).empty?
    EmailAllowlist(emails: allowed): email_allowed?(email, allowed)
  end
end

## Returns `true` iff `user.status` is `Active`.
fn user_active?(user: User) : Bool
  user.status is Active
end

## Resolves OIDC sign-in / linking safely without pre-account takeover vulnerabilities.
fn resolve_oidc_link(
  cfg: OidcLinkConfig,
  existing_by_subject: Option(Text),
  existing_by_email: Option(User),
  oidc_email: Text,
  oidc_email_verified?: Bool,
  has_valid_invite?: Bool
) : OidcLinkDecision
  examples
    case Time.parse("2026-12-01T00:00:00Z")
      Some(t0):
        verified_user = User(
          id: "u1",
          email: "ada@acme.io",
          email_verified_at: Some(t0),
          display_name: None,
          avatar_url: None,
          status: Active,
          mfa_enabled?: false,
          created_at: t0,
          updated_at: t0
        )
        unverified_user = User(
          id: "u2",
          email: "bob@acme.io",
          email_verified_at: None,
          display_name: None,
          avatar_url: None,
          status: Active,
          mfa_enabled?: false,
          created_at: t0,
          updated_at: t0
        )
        link_cfg = OidcLinkConfig(signup_mode: OpenSignup, auto_link_verified_oidc?: true)
        resolve_oidc_link(link_cfg, Some("u_sub"), None, "ada@acme.io", false, false) ==
          SignInExisting(user_id: "u_sub") and
          resolve_oidc_link(link_cfg, None, Some(verified_user), "ada@acme.io", true, false) ==
            LinkAndSignIn(user_id: "u1") and
          resolve_oidc_link(link_cfg, None, Some(verified_user), "ada@acme.io", false, false) ==
            AccountLinkRequiresLogin(user_id: "u1") and
          resolve_oidc_link(link_cfg, None, Some(unverified_user), "bob@acme.io", true, false) ==
            AccountLinkRequiresLogin(user_id: "u2")
      None: false
    end
  end

  promise "unverified OIDC email never auto-links an existing user"
    not oidc_email_verified? implies not (result is LinkAndSignIn(user_id: _))
  end

  if existing_by_subject is Some(uid)
    return SignInExisting(user_id: uid)
  end
  if existing_by_email is Some(u)
    if oidc_email_verified? and
      not (u.email_verified_at is None) and
      cfg.auto_link_verified_oidc? and
      user_active?(u)
      return LinkAndSignIn(user_id: u.id)
    end
    return AccountLinkRequiresLogin(user_id: u.id)
  end
  if signup_permitted?(cfg.signup_mode, oidc_email, has_valid_invite?)
    CreateUser(email: normalize_email(oidc_email))
  else
    Reject(reason: "signup_not_permitted")
  end
end

## Attaches BOTH the `HttpOnly` encrypted session cookie AND the readable `XSRF-TOKEN` cookie to `res`.
fn login_response(
  res: Api.Response,
  session: Session.Session,
  cookie_val: Text,
  cfg: Session.SessionConfig
) : Api.Response
  with_sess = Session.attach_cookie(res, cookie_val, cfg)
  Csrf.attach_cookie(with_sess, session, cfg.secure?)
end

## Clears BOTH the session cookie and the `XSRF-TOKEN` cookie on `res`.
fn logout_response(res: Api.Response, cfg: Session.SessionConfig) : Api.Response
  cleared_sess = Session.clear_cookie(res, cfg)
  Csrf.clear_cookie(cleared_sess, cfg.secure?)
end

## Returns `true` when `req` uses a safe read method (`GET`/`HEAD`/`OPTIONS`) or carries a valid `X-XSRF-TOKEN`.
fn require_csrf(req: Api.Request, session: Session.Session) : Bool
  examples
    case Time.parse("2026-12-01T00:00:00Z")
      Some(exp): require_csrf(
        Api.get("/budget"),
        Session.Session(id: "s", member_id: "m", csrf_token: "csrf_tok", expires_at: exp)
      )
      None: false
    end
    case Time.parse("2026-12-01T00:00:00Z")
      Some(exp): not require_csrf(
        Api.post("/budget"),
        Session.Session(id: "s", member_id: "m", csrf_token: "csrf_tok", expires_at: exp)
      )
      None: false
    end
    case Time.parse("2026-12-01T00:00:00Z")
      Some(exp): require_csrf(
        Api.post("/budget").with_header("X-XSRF-TOKEN", "csrf_tok"),
        Session.Session(id: "s", member_id: "m", csrf_token: "csrf_tok", expires_at: exp)
      )
      None: false
    end
  end

  Csrf.safe_method?(req) or Csrf.verify(req, session)
end

test "allowlist, password hashing, dual Set-Cookie login/logout, and require_csrf"
  allow = ["Robert@Household.Local", "Partner@Household.Local"]
  assert email_allowed?(" partner@household.local ", allow)
  assert not email_allowed?("other@household.local", allow)

  rng = SecureRandom.seeded(55)
  encoded = case hash_password(rng, "s3cure-passphrase!")
    Ok(h): h
    Error(_): stop "hash_password failed"
  end
  assert verify_password("s3cure-passphrase!", encoded)
  assert not verify_password("wrong-passphrase", encoded)
  assert verify_password_timing_safe("s3cure-passphrase!", Some(encoded))
  assert not verify_password_timing_safe("wrong-passphrase", Some(encoded))
  assert not verify_password_timing_safe("arvo-dummy-secret-never-matches", None)
  assert not verify_password_timing_safe("", None)

  exp = Time.parse("2026-12-01T00:00:00Z") or stop "time"
  sess = Session.Session(
    id: "sess_abc",
    member_id: "mem_1",
    csrf_token: "csrf_tok_xyz",
    expires_at: exp
  )
  cfg = Session.default_config(true)

  login_res = login_response(Api.redirect_see_other("/"), sess, "sealed_val", cfg)
  assert login_res.status == 303
  set_cookies = login_res.headers_named("Set-Cookie")
  assert set_cookies.size == 2
  assert (set_cookies.get(0) or "").starts_with?("arvo_session=sealed_val;")
  assert (set_cookies.get(0) or "").contains?("HttpOnly")
  assert (set_cookies.get(1) or "").starts_with?("XSRF-TOKEN=csrf_tok_xyz;")
  assert not (set_cookies.get(1) or "").contains?("HttpOnly")

  logout_res = logout_response(Api.redirect_see_other("/login"), cfg)
  clear_cookies = logout_res.headers_named("Set-Cookie")
  assert clear_cookies.size == 2
  assert (clear_cookies.get(0) or "").contains?("arvo_session=; Path=/; Max-Age=0")
  assert (clear_cookies.get(1) or "").contains?("XSRF-TOKEN=; Path=/; Max-Age=0")

  assert require_csrf(Api.get("/budget"), sess)
  assert not require_csrf(Api.post("/budget"), sess)
  assert require_csrf(Api.post("/budget").with_header("X-XSRF-TOKEN", "csrf_tok_xyz"), sess)
end

test "Auth v2 password policy, timing-safe checks, tokens, and safe OIDC linking"
  t0 = Time.parse("2026-12-01T00:00:00Z") or stop "t0"
  rng = SecureRandom.seeded(101)
  clk = Clock.fixed(t0)

  # Password policy boundaries
  pol = default_password_policy()
  assert validate_password("correct-horse", "ada@acme.io", pol) == Ok(Unit)
  assert validate_password("short1", "ada@acme.io", pol) == Error(TooShort(min: 12, got: 6))
  assert validate_password("a".repeat(1024), "ada@acme.io", pol) == Ok(Unit)
  assert validate_password("a".repeat(1025), "ada@acme.io", pol) ==
    Error(TooLongBytes(max: 1024, got: 1025))
  assert validate_password("ada.lovelace@acme.io", "ADA.Lovelace@Acme.IO", pol) ==
    Error(MatchesEmail)

  # Single-use purpose-bound tokens
  issued = issue_auth_token(rng, clk, Some("usr_1"), MagicLink, " Ada@Acme.IO ", 300)
  assert issued.token.target_email == "ada@acme.io"
  assert issued.token.token_hash != issued.raw_token
  assert token_valid?(
    issued.token,
    issued.raw_token,
    MagicLink,
    Some("ada@acme.io"),
    t0 + 10.seconds
  )
  assert not token_valid?(
    issued.token,
    issued.raw_token,
    PasswordReset,
    Some("ada@acme.io"),
    t0 + 10.seconds
  )
  assert not token_valid?(
    issued.token,
    issued.raw_token,
    MagicLink,
    Some("eve@acme.io"),
    t0 + 10.seconds
  )
  assert not token_valid?(issued.token, issued.raw_token, MagicLink, None, t0 + 300.seconds)
  assert not token_valid?(issued.token, "wrong", MagicLink, None, t0 + 10.seconds)

  # OIDC account linking vs InviteOnly / EmailAllowlist / Suspended
  susp_user = User(
    id: "u_susp",
    email: "susp@acme.io",
    email_verified_at: Some(t0),
    display_name: None,
    avatar_url: None,
    status: Suspended,
    mfa_enabled?: false,
    created_at: t0,
    updated_at: t0
  )
  assert status_to_text(Suspended) == "suspended" and status_from_text("active") == Some(Active)
  assert purpose_to_text(MagicLink) == "magic_link" and
    purpose_from_text("email_change") == Some(EmailChange)

  assert resolve_oidc_link(
    OidcLinkConfig(signup_mode: OpenSignup, auto_link_verified_oidc?: true),
    None,
    Some(susp_user),
    "susp@acme.io",
    true,
    false
  ) ==
    AccountLinkRequiresLogin(user_id: "u_susp")
  assert resolve_oidc_link(
    OidcLinkConfig(signup_mode: InviteOnly, auto_link_verified_oidc?: false),
    None,
    None,
    "new@acme.io",
    true,
    false
  ) ==
    Reject(reason: "signup_not_permitted")
  assert resolve_oidc_link(
    OidcLinkConfig(signup_mode: InviteOnly, auto_link_verified_oidc?: false),
    None,
    None,
    " New@Acme.io ",
    true,
    true
  ) ==
    CreateUser(email: "new@acme.io")
  assert resolve_oidc_link(
    OidcLinkConfig(
      signup_mode: EmailAllowlist(emails: ["ada@acme.io"]),
      auto_link_verified_oidc?: true
    ),
    None,
    None,
    "intruder@acme.io",
    true,
    true
  ) ==
    Reject(reason: "signup_not_permitted")
end
