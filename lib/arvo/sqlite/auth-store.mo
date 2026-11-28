## Durable SQLite Auth v2 store (`arvo_auth_*` STRICT tables) with atomic single-use tokens,
## monotonic TOTP step & passkey signCount enforcement, session revocation on password change,
## last-owner organization protection, and timing-safe password verification.
module Arvo.Sqlite.AuthStore
expose AuthStoreError(..),
TotpRecord(..),
PasskeyRecord(..),
Principal(..),
schema_sql,
init_schema,
create_user_with_password,
create_user_with_identity,
get_user,
find_user_by_email,
find_user_by_identity,
link_identity,
authenticate_password,
change_password,
change_email,
verify_user_email,
issue_and_store_token,
consume_auth_token,
enroll_totp,
get_totp,
verify_totp_for_user,
consume_recovery_code_for_user,
register_passkey,
get_passkey,
list_passkeys_for_user,
record_passkey_use,
mint_api_token,
revoke_api_token,
list_api_tokens_for_user,
authenticate_request,
create_org,
get_org_by_slug,
add_membership,
list_org_memberships,
update_membership_role,
remove_membership,
delete_account
use Api
use Arvo.ApiTokens
use Arvo.Auth
use Arvo.Keyring
use Arvo.Orgs
use Arvo.Session
use Arvo.Sqlite.Sessions
use Arvo.Totp
use Arvo.Webauthn
use Json

## Errors raised by SQLite Auth v2 storage operations.
enum AuthStoreError
  Sql(SqliteError)
  Decode(Sqlite.SqliteDecodeError)
  Validation(Text)
  Conflict(Text)
  RecordNotFound(Text)
  InvalidOrExpiredToken
  LastOwnerProtected
  CryptoFailed(Text)
end

## Stored TOTP credential row per `user_id` (`last_used_step` prevents replay within the same step).
struct TotpRecord
  user_id: Text
  sealed_secret: Text
  enabled?: Bool
  last_used_step: Option(Int)
  recovery_digests: List(Text)
  created_at: Time
  updated_at: Time
end

## Stored WebAuthn passkey row per `credential_id`.
struct PasskeyRecord
  credential_id: Text
  user_id: Text
  name: Text
  public_key_b64url: Text
  alg: Webauthn.PasskeyAlg
  sign_count: Int
  aaguid_hex: Text
  backed_up?: Bool
  created_at: Time
  last_used_at: Option(Time)
end

## Authenticated HTTP principal loaded from either `Authorization: Bearer ...` or session cookie.
enum Principal
  SessionPrincipal(user: Auth.User, session: Session.Session)
  ApiTokenPrincipal(user: Auth.User, token: ApiTokens.ApiTokenRecord)
end

struct UserRow
  id: Text
  email: Text
  email_verified_at: Option(Text)
  display_name: Option(Text)
  avatar_url: Option(Text)
  status: Text
  mfa_enabled: Int
  created_at: Text
  updated_at: Text
end

struct IdentityRow
  id: Text
  user_id: Text
  provider: Text
  provider_subject: Text
  email: Text
  password_hash: Option(Text)
  created_at: Text
end

struct TokenRow
  id: Text
  user_id: Option(Text)
  purpose: Text
  target_email: Text
  token_hash: Text
  expires_at: Text
  used_at: Option(Text)
  created_at: Text
end

struct TotpSqlRow
  user_id: Text
  sealed_secret: Text
  enabled: Int
  last_used_step: Option(Int)
  recovery_digests_json: Text
  created_at: Text
  updated_at: Text
end

struct PasskeySqlRow
  credential_id: Text
  user_id: Text
  name: Text
  public_key_b64url: Text
  alg: Text
  sign_count: Int
  aaguid_hex: Text
  backed_up: Int
  created_at: Text
  last_used_at: Option(Text)
end

struct ApiTokenSqlRow
  id: Text
  user_id: Text
  org_id: Option(Text)
  name: Text
  prefix: Text
  secret_hash: Text
  scopes_json: Text
  grant_id: Option(Text)
  taint_policy_id: Option(Text)
  expires_at: Option(Text)
  last_used_at: Option(Text)
  revoked_at: Option(Text)
  created_at: Text
end

struct OrgSqlRow
  id: Text
  slug: Text
  name: Text
  created_at: Text
end

struct MembershipSqlRow
  org_id: Text
  user_id: Text
  role: Text
  joined_at: Text
end

users_ddl = "CREATE TABLE IF NOT EXISTS arvo_auth_users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, email_verified_at TEXT, display_name TEXT, avatar_url TEXT, status TEXT NOT NULL, mfa_enabled INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL) STRICT"
identities_ddl = "CREATE TABLE IF NOT EXISTS arvo_auth_identities (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, provider TEXT NOT NULL, provider_subject TEXT NOT NULL, email TEXT NOT NULL, password_hash TEXT, created_at TEXT NOT NULL, UNIQUE(provider, provider_subject)) STRICT"
identities_user_idx = "CREATE INDEX IF NOT EXISTS arvo_auth_ident_by_user ON arvo_auth_identities (user_id)"
tokens_ddl = "CREATE TABLE IF NOT EXISTS arvo_auth_tokens (id TEXT PRIMARY KEY, user_id TEXT, purpose TEXT NOT NULL, target_email TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, expires_at TEXT NOT NULL, used_at TEXT, created_at TEXT NOT NULL) STRICT"
tokens_user_idx = "CREATE INDEX IF NOT EXISTS arvo_auth_tokens_by_user ON arvo_auth_tokens (user_id)"
totp_ddl = "CREATE TABLE IF NOT EXISTS arvo_auth_totp (user_id TEXT PRIMARY KEY, sealed_secret TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, last_used_step INTEGER, recovery_digests_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL) STRICT"
passkeys_ddl = "CREATE TABLE IF NOT EXISTS arvo_auth_passkeys (credential_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, name TEXT NOT NULL, public_key_b64url TEXT NOT NULL, alg TEXT NOT NULL, sign_count INTEGER NOT NULL DEFAULT 0, aaguid_hex TEXT NOT NULL, backed_up INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, last_used_at TEXT) STRICT"
passkeys_user_idx = "CREATE INDEX IF NOT EXISTS arvo_auth_passkeys_by_user ON arvo_auth_passkeys (user_id)"
api_tokens_ddl = "CREATE TABLE IF NOT EXISTS arvo_auth_api_tokens (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, org_id TEXT, name TEXT NOT NULL, prefix TEXT NOT NULL, secret_hash TEXT NOT NULL, scopes_json TEXT NOT NULL, grant_id TEXT, taint_policy_id TEXT, expires_at TEXT, last_used_at TEXT, revoked_at TEXT, created_at TEXT NOT NULL) STRICT"
api_tokens_user_idx = "CREATE INDEX IF NOT EXISTS arvo_auth_api_tokens_by_user ON arvo_auth_api_tokens (user_id)"
orgs_ddl = "CREATE TABLE IF NOT EXISTS arvo_auth_orgs (id TEXT PRIMARY KEY, slug TEXT NOT NULL UNIQUE, name TEXT NOT NULL, created_at TEXT NOT NULL) STRICT"
memberships_ddl = "CREATE TABLE IF NOT EXISTS arvo_auth_memberships (org_id TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT NOT NULL, joined_at TEXT NOT NULL, PRIMARY KEY(org_id, user_id)) STRICT"
memberships_user_idx = "CREATE INDEX IF NOT EXISTS arvo_auth_memberships_by_user ON arvo_auth_memberships (user_id)"
invites_ddl = "CREATE TABLE IF NOT EXISTS arvo_auth_org_invites (id TEXT PRIMARY KEY, org_id TEXT NOT NULL, email TEXT NOT NULL, role TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, invited_by TEXT NOT NULL, expires_at TEXT NOT NULL, accepted_at TEXT, created_at TEXT NOT NULL) STRICT"

## Combined SQL DDL for all `arvo_auth_*` STRICT tables and indexes (ready for `Arvo.Sqlite.Migrations`).
fn schema_sql() : Text
  [
    users_ddl,
    identities_ddl,
    identities_user_idx,
    tokens_ddl,
    tokens_user_idx,
    totp_ddl,
    passkeys_ddl,
    passkeys_user_idx,
    api_tokens_ddl,
    api_tokens_user_idx,
    orgs_ddl,
    memberships_ddl,
    memberships_user_idx,
    invites_ddl
  ].join(";\n")
end

## Ensures all `arvo_auth_*` tables and indexes exist on `db`.
fn init_schema(db: Sqlite.Database) : Result(Unit, SqliteError)
  for stmt in [
    users_ddl,
    identities_ddl,
    identities_user_idx,
    tokens_ddl,
    tokens_user_idx,
    totp_ddl,
    passkeys_ddl,
    passkeys_user_idx,
    api_tokens_ddl,
    api_tokens_user_idx,
    orgs_ddl,
    memberships_ddl,
    memberships_user_idx,
    invites_ddl
  ]
    try db.run(stmt, [])
  end
  Ok(Unit)
end

fn text_opt_sql(v: Option(Text)) : Sqlite.Value
  case v
    Some(s): Sqlite.String(s)
    None: Sqlite.Null
  end
end

fn time_opt_sql(v: Option(Time)) : Sqlite.Value
  case v
    Some(t): Sqlite.String(t.to_text)
    None: Sqlite.Null
  end
end

fn int_opt_sql(v: Option(Int)) : Sqlite.Value
  case v
    Some(n): Sqlite.Integer(n)
    None: Sqlite.Null
  end
end

fn parse_time_req(s: Text) : Result(Time, AuthStoreError)
  Time.parse(s).or_fail(CryptoFailed("invalid ISO timestamp '#{s}'"))
end

fn parse_time_opt(opt: Option(Text)) : Result(Option(Time), AuthStoreError)
  case opt
    None: Ok(None)
    Some(s): Ok(Some(try parse_time_req(s)))
  end
end

fn row_to_user(r: UserRow) : Result(Auth.User, AuthStoreError)
  st = try Auth.status_from_text(r.status).or_fail(CryptoFailed("bad user status '#{r.status}'"))
  Ok(
    Auth.User(
      id: r.id,
      email: r.email,
      email_verified_at: try parse_time_opt(r.email_verified_at),
      display_name: r.display_name,
      avatar_url: r.avatar_url,
      status: st,
      mfa_enabled?: r.mfa_enabled != 0,
      created_at: try parse_time_req(r.created_at),
      updated_at: try parse_time_req(r.updated_at)
    )
  )
end

fn row_to_identity(r: IdentityRow) : Result(Auth.AuthIdentity, AuthStoreError)
  Ok(
    Auth.AuthIdentity(
      id: r.id,
      user_id: r.user_id,
      provider: r.provider,
      provider_subject: r.provider_subject,
      email: r.email,
      password_hash: r.password_hash,
      created_at: try parse_time_req(r.created_at)
    )
  )
end

fn row_to_token(r: TokenRow) : Result(Auth.AuthToken, AuthStoreError)
  p = try Auth.purpose_from_text(r.purpose).or_fail(
    CryptoFailed("bad token purpose '#{r.purpose}'")
  )
  Ok(
    Auth.AuthToken(
      id: r.id,
      user_id: r.user_id,
      purpose: p,
      target_email: r.target_email,
      token_hash: r.token_hash,
      expires_at: try parse_time_req(r.expires_at),
      used_at: try parse_time_opt(r.used_at),
      created_at: try parse_time_req(r.created_at)
    )
  )
end

fn row_to_totp(r: TotpSqlRow) : Result(TotpRecord, AuthStoreError)
  digs = case Json.decode_strict[List(Text)](r.recovery_digests_json.bytes)
    Ok(d): d
    Error(_): return Error(CryptoFailed("bad recovery digests JSON"))
  end
  Ok(
    TotpRecord(
      user_id: r.user_id,
      sealed_secret: r.sealed_secret,
      enabled?: r.enabled != 0,
      last_used_step: r.last_used_step,
      recovery_digests: digs,
      created_at: try parse_time_req(r.created_at),
      updated_at: try parse_time_req(r.updated_at)
    )
  )
end

fn row_to_passkey(r: PasskeySqlRow) : Result(PasskeyRecord, AuthStoreError)
  alg = try Webauthn.alg_from_text(r.alg).or_fail(CryptoFailed("bad passkey alg '#{r.alg}'"))
  Ok(
    PasskeyRecord(
      credential_id: r.credential_id,
      user_id: r.user_id,
      name: r.name,
      public_key_b64url: r.public_key_b64url,
      alg: alg,
      sign_count: r.sign_count,
      aaguid_hex: r.aaguid_hex,
      backed_up?: r.backed_up != 0,
      created_at: try parse_time_req(r.created_at),
      last_used_at: try parse_time_opt(r.last_used_at)
    )
  )
end

fn row_to_api_token(r: ApiTokenSqlRow) : Result(ApiTokens.ApiTokenRecord, AuthStoreError)
  scopes = case Json.decode_strict[List(Text)](r.scopes_json.bytes)
    Ok(s): s
    Error(_): return Error(CryptoFailed("bad scopes JSON"))
  end
  Ok(
    ApiTokens.ApiTokenRecord(
      id: r.id,
      user_id: r.user_id,
      org_id: r.org_id,
      name: r.name,
      prefix: r.prefix,
      secret_hash: r.secret_hash,
      scopes: scopes,
      grant_id: r.grant_id,
      taint_policy_id: r.taint_policy_id,
      expires_at: try parse_time_opt(r.expires_at),
      last_used_at: try parse_time_opt(r.last_used_at),
      revoked_at: try parse_time_opt(r.revoked_at),
      created_at: try parse_time_req(r.created_at)
    )
  )
end

fn row_to_membership(r: MembershipSqlRow) : Result(Orgs.Membership, AuthStoreError)
  role = try Orgs.role_from_text(r.role).or_fail(CryptoFailed("bad org role '#{r.role}'"))
  Ok(
    Orgs.Membership(
      org_id: r.org_id,
      user_id: r.user_id,
      role: role,
      joined_at: try parse_time_req(r.joined_at)
    )
  )
end

struct CreateUserPlan
  user: Auth.User
  identity: Auth.AuthIdentity
end

fn run_create_user_tx(tx_db: Sqlite.Database, plan: CreateUserPlan) : Result(
  Auth.User,
  AuthStoreError
)
  u = plan.user
  ident = plan.identity
  existing = try tx_db.query(
    "SELECT id FROM arvo_auth_users WHERE email = ?",
    [Sqlite.String(u.email)]
  ).map_error(fn(e) Sql(e) end)
  if not existing.rows.empty?
    return Error(Conflict("email '#{u.email}' already registered"))
  end
  existing_ident = try tx_db.query(
    "SELECT id FROM arvo_auth_identities WHERE provider = ? AND provider_subject = ?",
    [Sqlite.String(ident.provider), Sqlite.String(ident.provider_subject)]
  ).map_error(fn(e) Sql(e) end)
  if not existing_ident.rows.empty?
    return Error(Conflict("identity '#{ident.provider}:#{ident.provider_subject}' already exists"))
  end
  _iu = try tx_db.execute(
    "INSERT INTO arvo_auth_users (id, email, email_verified_at, display_name, avatar_url, status, mfa_enabled, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(u.id),
      Sqlite.String(u.email),
      time_opt_sql(u.email_verified_at),
      text_opt_sql(u.display_name),
      text_opt_sql(u.avatar_url),
      Sqlite.String(Auth.status_to_text(u.status)),
      Sqlite.Integer(if u.mfa_enabled?: 1 else: 0),
      Sqlite.String(u.created_at.to_text),
      Sqlite.String(u.updated_at.to_text)
    ]
  ).map_error(fn(e) Sql(e) end)
  _ii = try tx_db.execute(
    "INSERT INTO arvo_auth_identities (id, user_id, provider, provider_subject, email, password_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [
      Sqlite.String(ident.id),
      Sqlite.String(ident.user_id),
      Sqlite.String(ident.provider),
      Sqlite.String(ident.provider_subject),
      Sqlite.String(ident.email),
      text_opt_sql(ident.password_hash),
      Sqlite.String(ident.created_at.to_text)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(u)
end

## Creates a user + `"password"` identity after enforcing `PasswordPolicy` and email uniqueness.
fn create_user_with_password(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  email: Text,
  password: Text,
  policy: Auth.PasswordPolicy,
  display_name: Option(Text),
  verify_immediately?: Bool
) : Result(Auth.User, AuthStoreError)
  norm = Auth.normalize_email(email)
  return Error(Validation("email cannot be empty")) if norm.empty?
  case Auth.validate_password(password, norm, policy)
    Ok(_): Unit
    Error(Auth.Blank): return Error(Validation("password cannot be blank"))
    Error(Auth.TooShort(min: m, got: g)): return Error(
      Validation("password too short (#{g} < #{m})")
    )
    Error(Auth.TooLongBytes(max: m, got: g)): return Error(
      Validation("password exceeds max #{m} bytes (#{g})")
    )
    Error(Auth.MatchesEmail): return Error(Validation("password cannot match email"))
  end
  pw_hash = try Auth.hash_password(rng, password).map_error(
    fn(e) CryptoFailed("hash failed: #{e}") end
  )
  now = clock.now
  uid = "usr_#{rng.bytes(16).to_hex}"
  iid = "idn_#{rng.bytes(16).to_hex}"
  user = Auth.User(
    id: uid,
    email: norm,
    email_verified_at: if verify_immediately?: Some(now) else: None,
    display_name: display_name,
    avatar_url: None,
    status: Auth.Active,
    mfa_enabled?: false,
    created_at: now,
    updated_at: now
  )
  ident = Auth.AuthIdentity(
    id: iid,
    user_id: uid,
    provider: "password",
    provider_subject: norm,
    email: norm,
    password_hash: Some(pw_hash),
    created_at: now
  )
  Sqlite.transaction(
    db,
    CreateUserPlan(user: user, identity: ident),
    run_create_user_tx,
    fn(e)
      Sql(e)
    end
  )
end

## Creates a passwordless user + external `AuthIdentity` (e.g. OIDC/SSO).
fn create_user_with_identity(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  email: Text,
  provider: Text,
  provider_subject: Text,
  email_verified_at: Option(Time),
  display_name: Option(Text),
  avatar_url: Option(Text)
) : Result(Auth.User, AuthStoreError)
  norm = Auth.normalize_email(email)
  return Error(Validation("email cannot be empty")) if norm.empty?
  return Error(Validation("provider/subject cannot be empty")) if provider.trim.empty? or
    provider_subject.trim.empty?
  now = clock.now
  uid = "usr_#{rng.bytes(16).to_hex}"
  iid = "idn_#{rng.bytes(16).to_hex}"
  user = Auth.User(
    id: uid,
    email: norm,
    email_verified_at: email_verified_at,
    display_name: display_name,
    avatar_url: avatar_url,
    status: Auth.Active,
    mfa_enabled?: false,
    created_at: now,
    updated_at: now
  )
  ident = Auth.AuthIdentity(
    id: iid,
    user_id: uid,
    provider: provider.trim,
    provider_subject: provider_subject.trim,
    email: norm,
    password_hash: None,
    created_at: now
  )
  Sqlite.transaction(
    db,
    CreateUserPlan(user: user, identity: ident),
    run_create_user_tx,
    fn(e)
      Sql(e)
    end
  )
end

## Looks up a user by `user_id`.
fn get_user(db: Sqlite.Database, user_id: Text) : Result(Option(Auth.User), AuthStoreError)
  res = try db.query(
    "SELECT id, email, email_verified_at, display_name, avatar_url, status, mfa_enabled, created_at, updated_at FROM arvo_auth_users WHERE id = ?",
    [Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  opt = try Sqlite.decode_optional[UserRow](res).map_error(fn(e) Decode(e) end)
  case opt
    Some(r): Ok(Some(try row_to_user(r)))
    None: Ok(None)
  end
end

## Looks up a user by normalized email.
fn find_user_by_email(db: Sqlite.Database, email: Text) : Result(Option(Auth.User), AuthStoreError)
  norm = Auth.normalize_email(email)
  return Ok(None) if norm.empty?
  res = try db.query(
    "SELECT id, email, email_verified_at, display_name, avatar_url, status, mfa_enabled, created_at, updated_at FROM arvo_auth_users WHERE email = ?",
    [Sqlite.String(norm)]
  ).map_error(fn(e) Sql(e) end)
  opt = try Sqlite.decode_optional[UserRow](res).map_error(fn(e) Decode(e) end)
  case opt
    Some(r): Ok(Some(try row_to_user(r)))
    None: Ok(None)
  end
end

## Looks up a user via external `(provider, provider_subject)`.
fn find_user_by_identity(db: Sqlite.Database, provider: Text, provider_subject: Text) : Result(
  Option(Auth.User),
  AuthStoreError
)
  res = try db.query(
    "SELECT id, user_id, provider, provider_subject, email, password_hash, created_at FROM arvo_auth_identities WHERE provider = ? AND provider_subject = ?",
    [Sqlite.String(provider.trim), Sqlite.String(provider_subject.trim)]
  ).map_error(fn(e) Sql(e) end)
  opt = try Sqlite.decode_optional[IdentityRow](res).map_error(fn(e) Decode(e) end)
  case opt
    None: Ok(None)
    Some(ir): get_user(db, ir.user_id)
  end
end

## Links an external identity (`provider`, `provider_subject`) onto an existing user.
fn link_identity(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  user_id: Text,
  provider: Text,
  provider_subject: Text,
  email: Text
) : Result(Auth.AuthIdentity, AuthStoreError)
  u = try (try get_user(db, user_id)).or_fail(RecordNotFound("user '#{user_id}' not found"))
  _ = u
  ident = Auth.AuthIdentity(
    id: "idn_#{rng.bytes(16).to_hex}",
    user_id: user_id,
    provider: provider.trim,
    provider_subject: provider_subject.trim,
    email: Auth.normalize_email(email),
    password_hash: None,
    created_at: clock.now
  )
  _ins = try db.execute(
    "INSERT INTO arvo_auth_identities (id, user_id, provider, provider_subject, email, password_hash, created_at) VALUES (?, ?, ?, ?, ?, NULL, ?)",
    [
      Sqlite.String(ident.id),
      Sqlite.String(ident.user_id),
      Sqlite.String(ident.provider),
      Sqlite.String(ident.provider_subject),
      Sqlite.String(ident.email),
      Sqlite.String(ident.created_at.to_text)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(ident)
end

## Verifies `email` + `password` using `verify_password_timing_safe`, rejecting suspended/deleted accounts.
fn authenticate_password(db: Sqlite.Database, email: Text, password: Text) : Result(
  Option(Auth.User),
  AuthStoreError
)
  maybe_user = try find_user_by_email(db, email)
  (user, maybe_hash) = case maybe_user
    None: (None, None)
    Some(u):
      res = try db.query(
        "SELECT id, user_id, provider, provider_subject, email, password_hash, created_at FROM arvo_auth_identities WHERE user_id = ? AND provider = 'password'",
        [Sqlite.String(u.id)]
      ).map_error(fn(e) Sql(e) end)
      ident = try Sqlite.decode_optional[IdentityRow](res).map_error(fn(e) Decode(e) end)
      pw_hash_opt = case ident
        Some(i): i.password_hash
        None: None
      end
      (Some(u), pw_hash_opt)
  end
  ok? = Auth.verify_password_timing_safe(password, maybe_hash)
  return Ok(None) if not ok?
  case user
    Some(u) if Auth.user_active?(u): Ok(Some(u))
    Some(_) | None: Ok(None)
  end
end

struct ChangePasswordPlan
  user_id: Text
  new_hash: Text
  new_ident_id: Text
  now_iso: Text
end

fn run_change_password_tx(tx_db: Sqlite.Database, plan: ChangePasswordPlan) : Result(
  Int,
  AuthStoreError
)
  u = try (try get_user(tx_db, plan.user_id)).or_fail(
    RecordNotFound("user '#{plan.user_id}' not found")
  )
  upd = try tx_db.execute(
    "UPDATE arvo_auth_identities SET password_hash = ? WHERE user_id = ? AND provider = 'password'",
    [Sqlite.String(plan.new_hash), Sqlite.String(plan.user_id)]
  ).map_error(fn(e) Sql(e) end)
  if upd.changes == 0
    _ins = try tx_db.execute(
      "INSERT INTO arvo_auth_identities (id, user_id, provider, provider_subject, email, password_hash, created_at) VALUES (?, ?, 'password', ?, ?, ?, ?)",
      [
        Sqlite.String(plan.new_ident_id),
        Sqlite.String(plan.user_id),
        Sqlite.String(u.email),
        Sqlite.String(u.email),
        Sqlite.String(plan.new_hash),
        Sqlite.String(plan.now_iso)
      ]
    ).map_error(fn(e) Sql(e) end)
  end
  _up_u = try tx_db.execute(
    "UPDATE arvo_auth_users SET updated_at = ? WHERE id = ?",
    [Sqlite.String(plan.now_iso), Sqlite.String(plan.user_id)]
  ).map_error(fn(e) Sql(e) end)
  _del_toks = try tx_db.execute(
    "DELETE FROM arvo_auth_tokens WHERE user_id = ?",
    [Sqlite.String(plan.user_id)]
  ).map_error(fn(e) Sql(e) end)
  revoked = try Sessions.revoke_all_for_member(tx_db, plan.user_id).map_error(fn(e) Sql(e) end)
  Ok(revoked)
end

## Updates `user_id`'s password hash, invalidates all pending auth tokens, and revokes all active sessions.
fn change_password(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  user_id: Text,
  new_password: Text,
  policy: Auth.PasswordPolicy
) : Result(Int, AuthStoreError)
  u = try (try get_user(db, user_id)).or_fail(RecordNotFound("user '#{user_id}' not found"))
  case Auth.validate_password(new_password, u.email, policy)
    Ok(_): Unit
    Error(Auth.Blank): return Error(Validation("password cannot be blank"))
    Error(Auth.TooShort(min: m, got: g)): return Error(
      Validation("password too short (#{g} < #{m})")
    )
    Error(Auth.TooLongBytes(max: m, got: g)): return Error(
      Validation("password exceeds max #{m} bytes (#{g})")
    )
    Error(Auth.MatchesEmail): return Error(Validation("password cannot match email"))
  end
  new_hash = try Auth.hash_password(rng, new_password).map_error(
    fn(e) CryptoFailed("hash failed: #{e}") end
  )
  plan = ChangePasswordPlan(
    user_id: user_id,
    new_hash: new_hash,
    new_ident_id: "idn_#{rng.bytes(16).to_hex}",
    now_iso: clock.now.to_text
  )
  Sqlite.transaction(db, plan, run_change_password_tx, fn(e) Sql(e) end)
end

struct ChangeEmailPlan
  user_id: Text
  new_email: Text
  verified_at_iso: Option(Text)
  now_iso: Text
end

fn run_change_email_tx(tx_db: Sqlite.Database, plan: ChangeEmailPlan) : Result(Unit, AuthStoreError)
  dup = try tx_db.query(
    "SELECT id FROM arvo_auth_users WHERE email = ? AND id != ?",
    [Sqlite.String(plan.new_email), Sqlite.String(plan.user_id)]
  ).map_error(fn(e) Sql(e) end)
  return Error(Conflict("email '#{plan.new_email}' already in use")) if not dup.rows.empty?
  upd = try tx_db.execute(
    "UPDATE arvo_auth_users SET email = ?, email_verified_at = ?, updated_at = ? WHERE id = ?",
    [
      Sqlite.String(plan.new_email),
      text_opt_sql(plan.verified_at_iso),
      Sqlite.String(plan.now_iso),
      Sqlite.String(plan.user_id)
    ]
  ).map_error(fn(e) Sql(e) end)
  return Error(RecordNotFound("user '#{plan.user_id}' not found")) if upd.changes == 0
  _ui = try tx_db.execute(
    "UPDATE arvo_auth_identities SET email = ?, provider_subject = ? WHERE user_id = ? AND provider = 'password'",
    [Sqlite.String(plan.new_email), Sqlite.String(plan.new_email), Sqlite.String(plan.user_id)]
  ).map_error(fn(e) Sql(e) end)
  _del = try tx_db.execute(
    "DELETE FROM arvo_auth_tokens WHERE user_id = ?",
    [Sqlite.String(plan.user_id)]
  ).map_error(fn(e) Sql(e) end)
  Ok(Unit)
end

## Changes `user_id`'s email and invalidates all outstanding `AuthToken`s for that user.
fn change_email(
  db: Sqlite.Database,
  clock: Clock,
  user_id: Text,
  new_email: Text,
  verified_now?: Bool
) : Result(Unit, AuthStoreError)
  norm = Auth.normalize_email(new_email)
  return Error(Validation("email cannot be empty")) if norm.empty?
  now_iso = clock.now.to_text
  plan = ChangeEmailPlan(
    user_id: user_id,
    new_email: norm,
    verified_at_iso: if verified_now?: Some(now_iso) else: None,
    now_iso: now_iso
  )
  Sqlite.transaction(db, plan, run_change_email_tx, fn(e) Sql(e) end)
end

## Marks `user_id`'s email address verified at `clock.now`.
fn verify_user_email(db: Sqlite.Database, clock: Clock, user_id: Text) : Result(
  Unit,
  AuthStoreError
)
  now_iso = clock.now.to_text
  upd = try db.execute(
    "UPDATE arvo_auth_users SET email_verified_at = ?, updated_at = ? WHERE id = ?",
    [Sqlite.String(now_iso), Sqlite.String(now_iso), Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  return Error(RecordNotFound("user '#{user_id}' not found")) if upd.changes == 0
  Ok(Unit)
end

## Issues and stores a single-use SHA-256 `AuthToken`, returning `(AuthToken, raw_token)`.
fn issue_and_store_token(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  user_id: Option(Text),
  purpose: Auth.TokenPurpose,
  target_email: Text,
  ttl_seconds: Int
) : Result(Auth.IssuedToken, AuthStoreError)
  issued = Auth.issue_auth_token(rng, clock, user_id, purpose, target_email, ttl_seconds)
  tok = issued.token
  _ins = try db.execute(
    "INSERT INTO arvo_auth_tokens (id, user_id, purpose, target_email, token_hash, expires_at, used_at, created_at) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
    [
      Sqlite.String(tok.id),
      text_opt_sql(tok.user_id),
      Sqlite.String(Auth.purpose_to_text(tok.purpose)),
      Sqlite.String(tok.target_email),
      Sqlite.String(tok.token_hash),
      Sqlite.String(tok.expires_at.to_text),
      Sqlite.String(tok.created_at.to_text)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(issued)
end

struct ConsumeTokenPlan
  raw_token: Text
  tok_hash: Text
  expected_purpose: Auth.TokenPurpose
  expected_email: Option(Text)
  now: Time
end

fn run_consume_token_tx(tx_db: Sqlite.Database, plan: ConsumeTokenPlan) : Result(
  Auth.AuthToken,
  AuthStoreError
)
  res = try tx_db.query(
    "SELECT id, user_id, purpose, target_email, token_hash, expires_at, used_at, created_at FROM arvo_auth_tokens WHERE token_hash = ?",
    [Sqlite.String(plan.tok_hash)]
  ).map_error(fn(e) Sql(e) end)
  opt = try Sqlite.decode_optional[TokenRow](res).map_error(fn(e) Decode(e) end)
  row = case opt
    Some(r): r
    None: return Error(InvalidOrExpiredToken)
  end
  stored = try row_to_token(row)
  if not Auth.token_valid?(
    stored,
    plan.raw_token,
    plan.expected_purpose,
    plan.expected_email,
    plan.now
  )
    return Error(InvalidOrExpiredToken)
  end
  upd = try tx_db.execute(
    "UPDATE arvo_auth_tokens SET used_at = ? WHERE id = ? AND used_at IS NULL",
    [Sqlite.String(plan.now.to_text), Sqlite.String(stored.id)]
  ).map_error(fn(e) Sql(e) end)
  return Error(InvalidOrExpiredToken) if upd.changes != 1
  var out = stored
  out.used_at = Some(plan.now)
  Ok(out)
end

## Atomically verifies and consumes a single-use token inside `Sqlite.transaction`.
fn consume_auth_token(
  db: Sqlite.Database,
  clock: Clock,
  raw_token: Text,
  expected_purpose: Auth.TokenPurpose,
  expected_email: Option(Text)
) : Result(Auth.AuthToken, AuthStoreError)
  return Error(InvalidOrExpiredToken) if raw_token.empty?
  plan = ConsumeTokenPlan(
    raw_token: raw_token,
    tok_hash: Auth.hash_raw_token(raw_token),
    expected_purpose: expected_purpose,
    expected_email: expected_email,
    now: clock.now
  )
  Sqlite.transaction(db, plan, run_consume_token_tx, fn(e) Sql(e) end)
end

## Stores a Keyring-sealed TOTP secret + SHA-256 recovery digests and marks `mfa_enabled = 1`.
fn enroll_totp(
  db: Sqlite.Database,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  clock: Clock,
  user_id: Text,
  secret: Bytes,
  recovery_digests: List(Text)
) : Result(TotpRecord, AuthStoreError)
  sealed = try Totp.seal_secret(rng, keyring, user_id, secret).map_error(
    fn(e) CryptoFailed(Totp.to_text(e)) end
  )
  now = clock.now
  now_iso = now.to_text
  dig_json = Json.encode(recovery_digests).to_text
  _up = try db.execute(
    "INSERT INTO arvo_auth_totp (user_id, sealed_secret, enabled, last_used_step, recovery_digests_json, created_at, updated_at) VALUES (?, ?, 1, NULL, ?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET sealed_secret = excluded.sealed_secret, enabled = 1, last_used_step = NULL, recovery_digests_json = excluded.recovery_digests_json, updated_at = excluded.updated_at",
    [
      Sqlite.String(user_id),
      Sqlite.String(sealed),
      Sqlite.String(dig_json),
      Sqlite.String(now_iso),
      Sqlite.String(now_iso)
    ]
  ).map_error(fn(e) Sql(e) end)
  _mu = try db.execute(
    "UPDATE arvo_auth_users SET mfa_enabled = 1, updated_at = ? WHERE id = ?",
    [Sqlite.String(now_iso), Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  Ok(
    TotpRecord(
      user_id: user_id,
      sealed_secret: sealed,
      enabled?: true,
      last_used_step: None,
      recovery_digests: recovery_digests,
      created_at: now,
      updated_at: now
    )
  )
end

## Loads the TOTP credential for `user_id`.
fn get_totp(db: Sqlite.Database, user_id: Text) : Result(Option(TotpRecord), AuthStoreError)
  res = try db.query(
    "SELECT user_id, sealed_secret, enabled, last_used_step, recovery_digests_json, created_at, updated_at FROM arvo_auth_totp WHERE user_id = ?",
    [Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  opt = try Sqlite.decode_optional[TotpSqlRow](res).map_error(fn(e) Decode(e) end)
  case opt
    Some(r): Ok(Some(try row_to_totp(r)))
    None: Ok(None)
  end
end

struct VerifyTotpPlan
  user_id: Text
  code: Text
  keyring: Keyring.Keyring
  cfg: Totp.TotpConfig
  now: Time
end

fn run_verify_totp_tx(tx_db: Sqlite.Database, plan: VerifyTotpPlan) : Result(
  Totp.TotpVerifyResult,
  AuthStoreError
)
  rec = case try get_totp(tx_db, plan.user_id)
    Some(r) if r.enabled?: r
    Some(_) | None: return Ok(Totp.InvalidCode)
  end
  (secret, _rekey?) = case Totp.open_secret(plan.keyring, plan.user_id, rec.sealed_secret)
    Ok(v): v
    Error(e): return Error(CryptoFailed(Totp.to_text(e)))
  end
  vres = Totp.verify(secret, plan.code, plan.now, plan.cfg, rec.last_used_step)
  case vres
    Totp.Accepted(matched_step: step):
      upd = try tx_db.execute(
        "UPDATE arvo_auth_totp SET last_used_step = ?, updated_at = ? WHERE user_id = ? AND (last_used_step IS NULL OR last_used_step < ?)",
        [
          Sqlite.Integer(step),
          Sqlite.String(plan.now.to_text),
          Sqlite.String(plan.user_id),
          Sqlite.Integer(step)
        ]
      ).map_error(fn(e) Sql(e) end)
      if upd.changes != 1
        return Ok(Totp.ReplayedStep(step: step))
      end
      Ok(Totp.Accepted(matched_step: step))
    Totp.ReplayedStep(step: _) | Totp.InvalidCode: Ok(vres)
  end
end

## Atomically verifies a TOTP code and persists monotonic `last_used_step` to block replays.
fn verify_totp_for_user(
  db: Sqlite.Database,
  keyring: Keyring.Keyring,
  clock: Clock,
  user_id: Text,
  code: Text,
  cfg: Totp.TotpConfig
) : Result(Totp.TotpVerifyResult, AuthStoreError)
  plan = VerifyTotpPlan(user_id: user_id, code: code, keyring: keyring, cfg: cfg, now: clock.now)
  Sqlite.transaction(db, plan, run_verify_totp_tx, fn(e) Sql(e) end)
end

struct ConsumeRecPlan
  user_id: Text
  candidate: Text
  now: Time
end

fn run_consume_rec_tx(tx_db: Sqlite.Database, plan: ConsumeRecPlan) : Result(Bool, AuthStoreError)
  rec = case try get_totp(tx_db, plan.user_id)
    Some(r) if r.enabled?: r
    Some(_) | None: return Ok(false)
  end
  rem = case Totp.verify_and_consume_recovery_code(plan.candidate, rec.recovery_digests)
    Some(r): r
    None: return Ok(false)
  end
  _upd = try tx_db.execute(
    "UPDATE arvo_auth_totp SET recovery_digests_json = ?, updated_at = ? WHERE user_id = ?",
    [
      Sqlite.String(Json.encode(rem).to_text),
      Sqlite.String(plan.now.to_text),
      Sqlite.String(plan.user_id)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(true)
end

## Atomically verifies and consumes one recovery code for `user_id`.
fn consume_recovery_code_for_user(db: Sqlite.Database, clock: Clock, user_id: Text, candidate: Text) : Result(
  Bool,
  AuthStoreError
)
  Sqlite.transaction(
    db,
    ConsumeRecPlan(user_id: user_id, candidate: candidate, now: clock.now),
    run_consume_rec_tx,
    fn(e) Sql(e) end
  )
end

## Persists a verified WebAuthn passkey for `user_id`.
fn register_passkey(
  db: Sqlite.Database,
  clock: Clock,
  user_id: Text,
  name: Text,
  pk: Webauthn.RegisteredPasskey
) : Result(PasskeyRecord, AuthStoreError)
  now = clock.now
  clean_name = if name.trim.empty?: "Passkey" else: name.trim
  _ins = try db.execute(
    "INSERT INTO arvo_auth_passkeys (credential_id, user_id, name, public_key_b64url, alg, sign_count, aaguid_hex, backed_up, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)",
    [
      Sqlite.String(pk.credential_id),
      Sqlite.String(user_id),
      Sqlite.String(clean_name),
      Sqlite.String(pk.public_key_b64url),
      Sqlite.String(Webauthn.alg_to_text(pk.alg)),
      Sqlite.Integer(pk.sign_count),
      Sqlite.String(pk.aaguid_hex),
      Sqlite.Integer(if pk.backed_up?: 1 else: 0),
      Sqlite.String(now.to_text)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(
    PasskeyRecord(
      credential_id: pk.credential_id,
      user_id: user_id,
      name: clean_name,
      public_key_b64url: pk.public_key_b64url,
      alg: pk.alg,
      sign_count: pk.sign_count,
      aaguid_hex: pk.aaguid_hex,
      backed_up?: pk.backed_up?,
      created_at: now,
      last_used_at: None
    )
  )
end

## Looks up a passkey credential by `credential_id`.
fn get_passkey(db: Sqlite.Database, credential_id: Text) : Result(
  Option(PasskeyRecord),
  AuthStoreError
)
  res = try db.query(
    "SELECT credential_id, user_id, name, public_key_b64url, alg, sign_count, aaguid_hex, backed_up, created_at, last_used_at FROM arvo_auth_passkeys WHERE credential_id = ?",
    [Sqlite.String(credential_id)]
  ).map_error(fn(e) Sql(e) end)
  opt = try Sqlite.decode_optional[PasskeySqlRow](res).map_error(fn(e) Decode(e) end)
  case opt
    Some(r): Ok(Some(try row_to_passkey(r)))
    None: Ok(None)
  end
end

## Lists all registered passkeys for `user_id`.
fn list_passkeys_for_user(db: Sqlite.Database, user_id: Text) : Result(
  List(PasskeyRecord),
  AuthStoreError
)
  res = try db.query(
    "SELECT credential_id, user_id, name, public_key_b64url, alg, sign_count, aaguid_hex, backed_up, created_at, last_used_at FROM arvo_auth_passkeys WHERE user_id = ?",
    [Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  rows = try Sqlite.decode[PasskeySqlRow](res).map_error(fn(e) Decode(e) end)
  var out = []
  for r in rows
    out = out.append(try row_to_passkey(r))
  end
  Ok(out)
end

struct PasskeyUsePlan
  credential_id: Text
  new_sign_count: Int
  backed_up?: Bool
  now: Time
end

fn run_passkey_use_tx(tx_db: Sqlite.Database, plan: PasskeyUsePlan) : Result(Unit, AuthStoreError)
  rec = try (try get_passkey(tx_db, plan.credential_id)).or_fail(
    RecordNotFound("passkey '#{plan.credential_id}' not found")
  )
  if rec.sign_count > 0 and plan.new_sign_count <= rec.sign_count
    return Error(
      Conflict("cloned passkey signCount detected (#{plan.new_sign_count} <= #{rec.sign_count})")
    )
  end
  _upd = try tx_db.execute(
    "UPDATE arvo_auth_passkeys SET sign_count = ?, backed_up = ?, last_used_at = ? WHERE credential_id = ?",
    [
      Sqlite.Integer(plan.new_sign_count),
      Sqlite.Integer(if plan.backed_up?: 1 else: 0),
      Sqlite.String(plan.now.to_text),
      Sqlite.String(plan.credential_id)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(Unit)
end

## Atomically enforces monotonic `sign_count` and records passkey usage timestamp.
fn record_passkey_use(
  db: Sqlite.Database,
  clock: Clock,
  credential_id: Text,
  new_sign_count: Int,
  backed_up?: Bool
) : Result(Unit, AuthStoreError)
  plan = PasskeyUsePlan(
    credential_id: credential_id,
    new_sign_count: new_sign_count,
    backed_up?: backed_up?,
    now: clock.now
  )
  Sqlite.transaction(db, plan, run_passkey_use_tx, fn(e) Sql(e) end)
end

## Mints and persists a scoped API / agent token, returning the one-time `IssuedApiToken`.
fn mint_api_token(
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  user_id: Text,
  org_id: Option(Text),
  name: Text,
  prefix: Text,
  scopes: List(Text),
  grant_id: Option(Text),
  taint_policy_id: Option(Text),
  expires_at: Option(Time)
) : Result(ApiTokens.IssuedApiToken, AuthStoreError)
  issued = try ApiTokens.mint_token(
    rng,
    clock,
    user_id,
    org_id,
    name,
    prefix,
    scopes,
    grant_id,
    taint_policy_id,
    expires_at
  ).map_error(fn(e) Validation(ApiTokens.to_text(e)) end)
  rec = issued.record
  _ins = try db.execute(
    "INSERT INTO arvo_auth_api_tokens (id, user_id, org_id, name, prefix, secret_hash, scopes_json, grant_id, taint_policy_id, expires_at, last_used_at, revoked_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)",
    [
      Sqlite.String(rec.id),
      Sqlite.String(rec.user_id),
      text_opt_sql(rec.org_id),
      Sqlite.String(rec.name),
      Sqlite.String(rec.prefix),
      Sqlite.String(rec.secret_hash),
      Sqlite.String(Json.encode(rec.scopes).to_text),
      text_opt_sql(rec.grant_id),
      text_opt_sql(rec.taint_policy_id),
      time_opt_sql(rec.expires_at),
      Sqlite.String(rec.created_at.to_text)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(issued)
end

## Revokes an API token owned by `token_id`.
fn revoke_api_token(db: Sqlite.Database, clock: Clock, token_id: Text) : Result(
  Bool,
  AuthStoreError
)
  upd = try db.execute(
    "UPDATE arvo_auth_api_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
    [Sqlite.String(clock.now.to_text), Sqlite.String(token_id)]
  ).map_error(fn(e) Sql(e) end)
  Ok(upd.changes > 0)
end

## Lists all API tokens belonging to `user_id`.
fn list_api_tokens_for_user(db: Sqlite.Database, user_id: Text) : Result(
  List(ApiTokens.ApiTokenRecord),
  AuthStoreError
)
  res = try db.query(
    "SELECT id, user_id, org_id, name, prefix, secret_hash, scopes_json, grant_id, taint_policy_id, expires_at, last_used_at, revoked_at, created_at FROM arvo_auth_api_tokens WHERE user_id = ?",
    [Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  rows = try Sqlite.decode[ApiTokenSqlRow](res).map_error(fn(e) Decode(e) end)
  var out = []
  for r in rows
    out = out.append(try row_to_api_token(r))
  end
  Ok(out)
end

## Authenticates an HTTP request via `Authorization: Bearer ...` API token OR session cookie.
fn authenticate_request(
  req: Api.Request,
  db: Sqlite.Database,
  clock: Clock,
  session_key: Bytes,
  session_cfg: Session.SessionConfig
) : Result(Option(Principal), AuthStoreError)
  if ApiTokens.parse_bearer_header(req) is Some(parsed)
    res = try db.query(
      "SELECT id, user_id, org_id, name, prefix, secret_hash, scopes_json, grant_id, taint_policy_id, expires_at, last_used_at, revoked_at, created_at FROM arvo_auth_api_tokens WHERE id = ?",
      [Sqlite.String(parsed.token_id)]
    ).map_error(fn(e) Sql(e) end)
    opt = try Sqlite.decode_optional[ApiTokenSqlRow](res).map_error(fn(e) Decode(e) end)
    tok = case opt
      Some(r): try row_to_api_token(r)
      None: return Ok(None)
    end
    now = clock.now
    return Ok(None) if not ApiTokens.verify_token(tok, parsed, now)
    user = case try get_user(db, tok.user_id)
      Some(u) if Auth.user_active?(u): u
      Some(_) | None: return Ok(None)
    end
    return Ok(Some(ApiTokenPrincipal(user: user, token: tok)))
  end

  sess_opt = case Sessions.load(req, db, clock, session_key, session_cfg)
    Ok(s): s
    Error(Sessions.InvalidKey): return Error(CryptoFailed("invalid session key"))
    Error(Sessions.Database(e)): return Error(Sql(e))
    Error(Sessions.Decode(e)): return Error(Decode(e))
    Error(Sessions.CryptoFailed(e)): return Error(CryptoFailed(e.to_text))
  end
  sess = case sess_opt
    Some(s): s
    None: return Ok(None)
  end
  user = case try get_user(db, sess.member_id)
    Some(u) if Auth.user_active?(u): u
    Some(_) | None: return Ok(None)
  end
  Ok(Some(SessionPrincipal(user: user, session: sess)))
end

## Creates an organization after validating slug format and uniqueness.
fn create_org(db: Sqlite.Database, rng: SecureRandom, clock: Clock, slug: Text, name: Text) : Result(
  Orgs.Org,
  AuthStoreError
)
  clean_slug = slug.trim.ascii_lowercase
  return Error(Validation("invalid slug '#{slug}'")) if not Orgs.valid_slug?(clean_slug)
  clean_name = name.trim
  return Error(Validation("organization name cannot be empty")) if clean_name.empty?
  dup = try db.query("SELECT id FROM arvo_auth_orgs WHERE slug = ?", [Sqlite.String(clean_slug)])
    .map_error(fn(e) Sql(e) end)
  return Error(Conflict("organization slug '#{clean_slug}' already exists")) if not dup.rows.empty?
  org = Orgs.Org(
    id: "org_#{rng.bytes(16).to_hex}",
    slug: clean_slug,
    name: clean_name,
    created_at: clock.now
  )
  _ins = try db.execute(
    "INSERT INTO arvo_auth_orgs (id, slug, name, created_at) VALUES (?, ?, ?, ?)",
    [
      Sqlite.String(org.id),
      Sqlite.String(org.slug),
      Sqlite.String(org.name),
      Sqlite.String(org.created_at.to_text)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(org)
end

## Looks up an organization by `slug`.
fn get_org_by_slug(db: Sqlite.Database, slug: Text) : Result(Option(Orgs.Org), AuthStoreError)
  res = try db.query(
    "SELECT id, slug, name, created_at FROM arvo_auth_orgs WHERE slug = ?",
    [Sqlite.String(slug.trim.ascii_lowercase)]
  ).map_error(fn(e) Sql(e) end)
  opt = try Sqlite.decode_optional[OrgSqlRow](res).map_error(fn(e) Decode(e) end)
  case opt
    None: Ok(None)
    Some(r): Ok(
      Some(
        Orgs.Org(id: r.id, slug: r.slug, name: r.name, created_at: try parse_time_req(r.created_at))
      )
    )
  end
end

## Adds a user membership row to `org_id`.
fn add_membership(
  db: Sqlite.Database,
  clock: Clock,
  org_id: Text,
  user_id: Text,
  role: Orgs.OrgRole
) : Result(Orgs.Membership, AuthStoreError)
  m = Orgs.Membership(org_id: org_id, user_id: user_id, role: role, joined_at: clock.now)
  _ins = try db.execute(
    "INSERT INTO arvo_auth_memberships (org_id, user_id, role, joined_at) VALUES (?, ?, ?, ?)",
    [
      Sqlite.String(m.org_id),
      Sqlite.String(m.user_id),
      Sqlite.String(Orgs.role_to_text(m.role)),
      Sqlite.String(m.joined_at.to_text)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(m)
end

## Lists all memberships belonging to `org_id`.
fn list_org_memberships(db: Sqlite.Database, org_id: Text) : Result(
  List(Orgs.Membership),
  AuthStoreError
)
  res = try db.query(
    "SELECT org_id, user_id, role, joined_at FROM arvo_auth_memberships WHERE org_id = ?",
    [Sqlite.String(org_id)]
  ).map_error(fn(e) Sql(e) end)
  rows = try Sqlite.decode[MembershipSqlRow](res).map_error(fn(e) Decode(e) end)
  var out = []
  for r in rows
    out = out.append(try row_to_membership(r))
  end
  Ok(out)
end

struct UpdateRolePlan
  org_id: Text
  user_id: Text
  new_role: Orgs.OrgRole
end

fn run_update_role_tx(tx_db: Sqlite.Database, plan: UpdateRolePlan) : Result(Unit, AuthStoreError)
  ms = try list_org_memberships(tx_db, plan.org_id)
  if not ms.any?(fn(m) m.user_id == plan.user_id end)
    return Error(RecordNotFound("membership not found"))
  end
  if not Orgs.can_remove_or_demote?(ms, plan.user_id, Some(plan.new_role))
    return Error(LastOwnerProtected)
  end
  _upd = try tx_db.execute(
    "UPDATE arvo_auth_memberships SET role = ? WHERE org_id = ? AND user_id = ?",
    [
      Sqlite.String(Orgs.role_to_text(plan.new_role)),
      Sqlite.String(plan.org_id),
      Sqlite.String(plan.user_id)
    ]
  ).map_error(fn(e) Sql(e) end)
  Ok(Unit)
end

## Atomically updates a member's `OrgRole`, enforcing last-owner protection.
fn update_membership_role(db: Sqlite.Database, org_id: Text, user_id: Text, new_role: Orgs.OrgRole) : Result(
  Unit,
  AuthStoreError
)
  Sqlite.transaction(
    db,
    UpdateRolePlan(org_id: org_id, user_id: user_id, new_role: new_role),
    run_update_role_tx,
    fn(e) Sql(e) end
  )
end

struct RemoveMemberPlan
  org_id: Text
  user_id: Text
end

fn run_remove_member_tx(tx_db: Sqlite.Database, plan: RemoveMemberPlan) : Result(
  Unit,
  AuthStoreError
)
  ms = try list_org_memberships(tx_db, plan.org_id)
  if not ms.any?(fn(m) m.user_id == plan.user_id end)
    return Error(RecordNotFound("membership not found"))
  end
  if not Orgs.can_remove_or_demote?(ms, plan.user_id, None)
    return Error(LastOwnerProtected)
  end
  _del = try tx_db.execute(
    "DELETE FROM arvo_auth_memberships WHERE org_id = ? AND user_id = ?",
    [Sqlite.String(plan.org_id), Sqlite.String(plan.user_id)]
  ).map_error(fn(e) Sql(e) end)
  Ok(Unit)
end

## Atomically removes `user_id` from `org_id`, enforcing last-owner protection.
fn remove_membership(db: Sqlite.Database, org_id: Text, user_id: Text) : Result(
  Unit,
  AuthStoreError
)
  Sqlite.transaction(
    db,
    RemoveMemberPlan(org_id: org_id, user_id: user_id),
    run_remove_member_tx,
    fn(e) Sql(e) end
  )
end

fn run_delete_account_tx(tx_db: Sqlite.Database, user_id: Text) : Result(Unit, AuthStoreError)
  _u = try (try get_user(tx_db, user_id)).or_fail(RecordNotFound("user '#{user_id}' not found"))
  mres = try tx_db.query(
    "SELECT org_id, user_id, role, joined_at FROM arvo_auth_memberships WHERE user_id = ?",
    [Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  mrows = try Sqlite.decode[MembershipSqlRow](mres).map_error(fn(e) Decode(e) end)
  for mr in mrows
    org_ms = try list_org_memberships(tx_db, mr.org_id)
    if org_ms.size > 1 and not Orgs.can_remove_or_demote?(org_ms, user_id, None)
      return Error(LastOwnerProtected)
    end
  end
  for mr in mrows
    _dm = try tx_db.execute(
      "DELETE FROM arvo_auth_memberships WHERE org_id = ? AND user_id = ?",
      [Sqlite.String(mr.org_id), Sqlite.String(user_id)]
    ).map_error(fn(e) Sql(e) end)
  end
  _s = try Sessions.revoke_all_for_member(tx_db, user_id).map_error(fn(e) Sql(e) end)
  _t1 = try tx_db.execute(
    "DELETE FROM arvo_auth_tokens WHERE user_id = ?",
    [Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  _t2 = try tx_db.execute("DELETE FROM arvo_auth_totp WHERE user_id = ?", [Sqlite.String(user_id)])
    .map_error(fn(e) Sql(e) end)
  _t3 = try tx_db.execute(
    "DELETE FROM arvo_auth_passkeys WHERE user_id = ?",
    [Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  _t4 = try tx_db.execute(
    "DELETE FROM arvo_auth_api_tokens WHERE user_id = ?",
    [Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  _t5 = try tx_db.execute(
    "DELETE FROM arvo_auth_identities WHERE user_id = ?",
    [Sqlite.String(user_id)]
  ).map_error(fn(e) Sql(e) end)
  _t6 = try tx_db.execute("DELETE FROM arvo_auth_users WHERE id = ?", [Sqlite.String(user_id)])
    .map_error(fn(e) Sql(e) end)
  Ok(Unit)
end

## Atomically deletes user, credentials, tokens, passkeys, TOTP, API tokens, memberships, and sessions.
fn delete_account(db: Sqlite.Database, user_id: Text) : Result(Unit, AuthStoreError)
  Sqlite.transaction(db, user_id, run_delete_account_tx, fn(e) Sql(e) end)
end

fn must_ok_sauth(res: Result(A, B)) : A
  case res
    Ok(v): v
    Error(_): stop "unexpected Sqlite.AuthStore test error"
  end
end

test "Sqlite.AuthStore full lifecycle: user, timing-safe login, atomic tokens, TOTP replay, Passkey signCount, API tokens, org last-owner, delete"
  sql = Sqlite.in_memory()
  db = must_ok_sauth(sql.open("auth.db"))
  _init_s = must_ok_sauth(Sessions.init_schema(db))
  _init_a = must_ok_sauth(init_schema(db))

  rng = SecureRandom.seeded(2026)
  t0 = Time.parse("2026-11-28T00:00:00Z") or stop "t0"
  clk = Clock.fixed(t0)
  pol = Auth.default_password_policy()
  sess_cfg = Session.default_config(true)
  sess_key = rng.bytes(32)
  kr = must_ok_sauth(Keyring.single("k1", sess_key))

  # Create user + password + login
  u = must_ok_sauth(
    create_user_with_password(
      db,
      rng,
      clk,
      " Ada@Acme.IO ",
      "correct-horse-battery",
      pol,
      Some("Ada"),
      false
    )
  )
  assert u.email == "ada@acme.io" and u.email_verified_at == None
  assert must_ok_sauth(authenticate_password(db, "ada@acme.io", "correct-horse-battery")) == Some(u)
  assert must_ok_sauth(authenticate_password(db, "missing@acme.io", "wrong")) == None

  # Single-use token verification + atomic replay block + email verification
  ev = must_ok_sauth(
    issue_and_store_token(db, rng, clk, Some(u.id), Auth.EmailVerify, u.email, 300)
  )
  assert consume_auth_token(db, clk, ev.raw_token, Auth.PasswordReset, None) ==
    Error(InvalidOrExpiredToken)
  assert must_ok_sauth(
    consume_auth_token(
      db,
      Clock.fixed(t0 + 10.seconds),
      ev.raw_token,
      Auth.EmailVerify,
      Some("ada@acme.io")
    )
  ).user_id ==
    Some(u.id)
  assert consume_auth_token(db, clk, ev.raw_token, Auth.EmailVerify, None) ==
    Error(InvalidOrExpiredToken)
  _ver = must_ok_sauth(verify_user_email(db, clk, u.id))

  # TOTP enrollment, replay guard, and recovery code consume
  totp_sec = Totp.generate_secret(rng)
  (rec_codes, rec_digs) = Totp.generate_recovery_codes(rng, 4)
  _trec = must_ok_sauth(enroll_totp(db, rng, kr, clk, u.id, totp_sec, rec_digs))
  totp_cfg = Totp.default_config()
  code0 = Totp.code_at(totp_sec, t0, totp_cfg)
  assert must_ok_sauth(verify_totp_for_user(db, kr, clk, u.id, code0, totp_cfg)) is
    Totp.Accepted(matched_step: _)
  assert must_ok_sauth(verify_totp_for_user(db, kr, clk, u.id, code0, totp_cfg)) is
    Totp.ReplayedStep(step: _)
  first_rec = rec_codes.first or stop "rec 0"
  assert must_ok_sauth(consume_recovery_code_for_user(db, clk, u.id, first_rec))
  assert not must_ok_sauth(consume_recovery_code_for_user(db, clk, u.id, first_rec))

  # Passkey register & monotonic sign_count
  _pk = must_ok_sauth(
    register_passkey(
      db,
      clk,
      u.id,
      "Touch ID",
      Webauthn.RegisteredPasskey(
        credential_id: "cid_1",
        public_key_b64url: "pub1",
        alg: Webauthn.Es256,
        sign_count: 5,
        aaguid_hex: "00",
        backed_up?: false
      )
    )
  )
  _ok_use = must_ok_sauth(record_passkey_use(db, clk, "cid_1", 6, false))
  assert record_passkey_use(db, clk, "cid_1", 6, false) is Error(Conflict(_))

  # Session + Bearer API token authentication
  (sess, cval) = must_ok_sauth(Sessions.create(db, rng, clk, sess_key, u.id, sess_cfg))
  req_cookie = Api.get("/me").with_header("Cookie", "arvo_session=#{cval}")
  assert must_ok_sauth(authenticate_request(req_cookie, db, clk, sess_key, sess_cfg)) is
    Some(SessionPrincipal(user: _, session: s_loaded))
  assert s_loaded.id == sess.id

  api_tok = must_ok_sauth(
    mint_api_token(db, rng, clk, u.id, None, "CLI", "arvo_live", ["bills:read"], None, None, None)
  )
  req_tok = Api.get("/me").with_header("Authorization", "Bearer #{api_tok.plaintext_token}")
  assert must_ok_sauth(authenticate_request(req_tok, db, clk, sess_key, sess_cfg)) is
    Some(ApiTokenPrincipal(user: _, token: _))

  # Change password revokes all active sessions + outstanding tokens
  _rst = must_ok_sauth(
    issue_and_store_token(db, rng, clk, Some(u.id), Auth.PasswordReset, u.email, 300)
  )
  assert must_ok_sauth(change_password(db, rng, clk, u.id, "even-stronger-passphrase", pol)) == 1
  assert must_ok_sauth(authenticate_request(req_cookie, db, clk, sess_key, sess_cfg)) == None
  assert must_ok_sauth(authenticate_password(db, u.email, "even-stronger-passphrase")) is Some(_)

  # Org + Last Owner protection
  u2 = must_ok_sauth(
    create_user_with_identity(
      db,
      rng,
      clk,
      "bob@acme.io",
      "google",
      "g_sub_2",
      Some(t0),
      None,
      None
    )
  )
  org = must_ok_sauth(create_org(db, rng, clk, "acme-org", "Acme Inc"))
  _m1 = must_ok_sauth(add_membership(db, clk, org.id, u.id, Orgs.Owner))
  _m2 = must_ok_sauth(add_membership(db, clk, org.id, u2.id, Orgs.Member))
  assert update_membership_role(db, org.id, u.id, Orgs.Admin) == Error(LastOwnerProtected)
  assert remove_membership(db, org.id, u.id) == Error(LastOwnerProtected)
  assert delete_account(db, u.id) == Error(LastOwnerProtected)

  # Transfer ownership -> delete_account succeeds cleanly
  _m2_own = must_ok_sauth(update_membership_role(db, org.id, u2.id, Orgs.Owner))
  assert delete_account(db, u.id) == Ok(Unit)
  assert must_ok_sauth(get_user(db, u.id)) == None
  assert must_ok_sauth(authenticate_request(req_tok, db, clk, sess_key, sess_cfg)) == None
end
