## WRONG VERSION (strength/arvo_auth_v2/02_skip_token_purpose_binding.mo): Accepts AuthToken even when purpose mismatches.
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

enum SignupMode
  OpenSignup
  InviteOnly
  EmailAllowlist(emails: List(Text))
end

enum UserStatus
  Active
  Suspended
  Deleted
end

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

struct AuthIdentity
  id: Text
  user_id: Text
  provider: Text
  provider_subject: Text
  email: Text
  password_hash: Option(Text)
  created_at: Time
end

enum TokenPurpose
  EmailVerify
  PasswordReset
  MagicLink
  OrgInvite
  EmailChange
end

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

struct IssuedToken
  token: AuthToken
  raw_token: Text
end

struct PasswordPolicy
  min_length: Int
  max_bytes: Int
end

enum PasswordValidationError
  TooShort(min: Int, got: Int)
  TooLongBytes(max: Int, got: Int)
  Blank
  MatchesEmail
end

struct OidcLinkConfig
  signup_mode: SignupMode
  auto_link_verified_oidc?: Bool
end

enum OidcLinkDecision
  SignInExisting(user_id: Text)
  LinkAndSignIn(user_id: Text)
  CreateUser(email: Text)
  Reject(reason: Text)
  AccountLinkRequiresLogin(user_id: Text)
end

fn status_to_text(st: UserStatus) : Text
  case st
    Active: "active"
    Suspended: "suspended"
    Deleted: "deleted"
  end
end

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

fn purpose_to_text(p: TokenPurpose) : Text
  case p
    EmailVerify: "email_verify"
    PasswordReset: "password_reset"
    MagicLink: "magic_link"
    OrgInvite: "org_invite"
    EmailChange: "email_change"
  end
end

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

fn normalize_email(email: Text) : Text
  email.trim.ascii_lowercase
end

fn email_allowed?(email: Text, allowlist: List(Text)) : Bool
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

fn hash_password(rng: SecureRandom, password: Text) : Result(Text, Crypto.CryptoError)
  salt = rng.bytes(16)
  Crypto.hash_password(password, salt)
end

fn verify_password(password: Text, encoded: Text) : Bool
  Crypto.verify_password(password, encoded)
end

fn verify_password_timing_safe(password: Text, maybe_hash: Option(Text)) : Bool
  case maybe_hash
    Some(encoded): Crypto.verify_password(password, encoded)
    None:
      _ = Crypto.verify_password(password, dummy_scrypt_hash)
      false
  end
end

fn default_password_policy() : PasswordPolicy
  PasswordPolicy(min_length: 12, max_bytes: 1024)
end

fn validate_password(password: Text, email: Text, policy: PasswordPolicy) : Result(
  Unit,
  PasswordValidationError
)
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

fn hash_raw_token(raw_token: Text) : Text
  Crypto.sha256(raw_token.bytes).to_hex
end

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

fn token_valid?(
  stored: AuthToken,
  raw_token: Text,
  expected_purpose: TokenPurpose,
  expected_email: Option(Text),
  now: Time
) : Bool
  _ = expected_purpose
  return false if not (stored.used_at is None)
  return false if now >= stored.expires_at
  return false if raw_token.empty?
  if expected_email is Some(em)
    return false if normalize_email(em) != stored.target_email
  end
  cand_hash = hash_raw_token(raw_token)
  Crypto.constant_time_eq?(stored.token_hash.bytes, cand_hash.bytes)
end

fn signup_permitted?(mode: SignupMode, email: Text, has_valid_invite?: Bool) : Bool
  case mode
    OpenSignup: not normalize_email(email).empty?
    InviteOnly: has_valid_invite? and not normalize_email(email).empty?
    EmailAllowlist(emails: allowed): email_allowed?(email, allowed)
  end
end

fn user_active?(user: User) : Bool
  user.status is Active
end

fn resolve_oidc_link(
  cfg: OidcLinkConfig,
  existing_by_subject: Option(Text),
  existing_by_email: Option(User),
  oidc_email: Text,
  oidc_email_verified?: Bool,
  has_valid_invite?: Bool
) : OidcLinkDecision
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

fn login_response(
  res: Api.Response,
  session: Session.Session,
  cookie_val: Text,
  cfg: Session.SessionConfig
) : Api.Response
  with_sess = Session.attach_cookie(res, cookie_val, cfg)
  Csrf.attach_cookie(with_sess, session, cfg.secure?)
end

fn logout_response(res: Api.Response, cfg: Session.SessionConfig) : Api.Response
  cleared_sess = Session.clear_cookie(res, cfg)
  Csrf.clear_cookie(cleared_sess, cfg.secure?)
end

fn require_csrf(req: Api.Request, session: Session.Session) : Bool
  Csrf.safe_method?(req) or Csrf.verify(req, session)
end
