## Flagship MoDB v0.9.0 Auth v2 backend (`_arvo_auth_*` indexed tables + `Modb.Ledger` tamper-evident
## security audit hash chain + `Modb.Grants`/`Modb.Taint` agent governance + `Modb.Erasure` GDPR deletion).
module Arvo.Modb.AuthStore
expose AuthError(..),
StoredTotp(..),
StoredPasskey(..),
Principal(..),
AgentPrincipal(..),
auth_schema,
users_table,
identities_table,
tokens_table,
totp_table,
passkeys_table,
api_tokens_table,
orgs_table,
memberships_table,
org_invites_table,
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
authenticate_agent_token,
create_org,
get_org_by_slug,
add_membership,
list_org_memberships,
list_user_memberships,
update_membership_role,
remove_membership,
delete_account_with_erasure
use Api
use Arvo.ApiTokens
use Arvo.Auth
use Arvo.Keyring
use Arvo.Modb.Sessions
use Arvo.Orgs
use Arvo.Session
use Arvo.Totp
use Arvo.Webauthn
use Json
use Modb
use Modb.Erasure
use Modb.Grants
use Modb.Ledger
use Modb.Table
use Modb.Taint

## Errors returned by `Arvo.Modb.AuthStore` operations.
enum AuthError
  LedgerFailure(Ledger.LedgerError)
  ErasureFailure(Erasure.ErasureError)
  GrantFailure(Grants.GrantError)
  TaintFailure(Taint.TaintError)
  SessionFailure(Sessions.SessionError)
  Validation(Text)
  Conflict(Text)
  RecordNotFound(Text)
  InvalidOrExpiredToken
  LastOwnerProtected
  AgentGrantRequired
  CryptoFailed(Text)
end

## Stored key-sealed TOTP credential row in `_arvo_auth_totp`.
struct StoredTotp
  user_id: Text
  sealed_secret: Text
  enabled?: Bool
  last_used_step: Option(Int)
  recovery_digests: List(Text)
  created_at: Time
  updated_at: Time
end

## Stored WebAuthn passkey row in `_arvo_auth_passkeys`.
struct StoredPasskey
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

## Read-only HTTP authenticated principal loaded via cookie session or Bearer API token.
enum Principal
  SessionPrincipal(
    user: Auth.User,
    session: Session.Session,
    view: Sessions.SessionView,
    needs_rekey?: Bool
  )
  ApiTokenPrincipal(user: Auth.User, token: ApiTokens.ApiTokenRecord)
end

## Verified agent identity carrying its attenuated `Modb.Grants` grant and active `Modb.Taint` session.
struct AgentPrincipal
  user: Auth.User
  token: ApiTokens.ApiTokenRecord
  grant: Grants.Grant
  taint_session: Taint.TaintSession
end

## Schema definition shared across all `Arvo.Modb.AuthStore`, `Ledger`, `Grants`, `Taint`, and `Erasure` calls.
fn auth_schema() : Ledger.Schema
  Ledger.schema(0).with_require_reason(false)
end

fn users_by_email() : Table.Index(Text, Auth.User, Text)
  Table.unique_text_index[Text, Auth.User]("_arvo_auth_users_by_email", fn(u) u.email end)
end

## Typed `Modb.Table` for `_arvo_auth_users`.
fn users_table() : Table.Table(Text, Auth.User)
  Table.text_key[Auth.User]("_arvo_auth_users").with_index(users_by_email())
end

fn ident_by_subj() : Table.Index(Text, Auth.AuthIdentity, Text)
  Table.unique_text_index[Text, Auth.AuthIdentity](
    "_arvo_auth_ident_by_subj",
    fn(i) "#{i.provider}|#{i.provider_subject}" end
  )
end

fn ident_by_user() : Table.Index(Text, Auth.AuthIdentity, Text)
  Table.text_index[Text, Auth.AuthIdentity]("_arvo_auth_ident_by_user", fn(i) i.user_id end)
end

## Typed `Modb.Table` for `_arvo_auth_identities`.
fn identities_table() : Table.Table(Text, Auth.AuthIdentity)
  Table.text_key[Auth.AuthIdentity]("_arvo_auth_identities").with_index(ident_by_subj()).with_index(
    ident_by_user()
  )
end

fn tokens_by_hash() : Table.Index(Text, Auth.AuthToken, Text)
  Table.unique_text_index[Text, Auth.AuthToken]("_arvo_auth_tokens_by_hash", fn(t) t.token_hash end)
end

fn tokens_by_user() : Table.Index(Text, Auth.AuthToken, Text)
  Table.text_index[Text, Auth.AuthToken]("_arvo_auth_tokens_by_user", fn(t) t.user_id or "" end)
end

## Typed `Modb.Table` for `_arvo_auth_tokens`.
fn tokens_table() : Table.Table(Text, Auth.AuthToken)
  Table.text_key[Auth.AuthToken]("_arvo_auth_tokens").with_index(tokens_by_hash()).with_index(
    tokens_by_user()
  )
end

## Typed `Modb.Table` for `_arvo_auth_totp`.
fn totp_table() : Table.Table(Text, StoredTotp)
  Table.text_key[StoredTotp]("_arvo_auth_totp")
end

fn passkeys_by_user() : Table.Index(Text, StoredPasskey, Text)
  Table.text_index[Text, StoredPasskey]("_arvo_auth_passkeys_by_user", fn(p) p.user_id end)
end

## Typed `Modb.Table` for `_arvo_auth_passkeys`.
fn passkeys_table() : Table.Table(Text, StoredPasskey)
  Table.text_key[StoredPasskey]("_arvo_auth_passkeys").with_index(passkeys_by_user())
end

fn api_tokens_by_user() : Table.Index(Text, ApiTokens.ApiTokenRecord, Text)
  Table.text_index[Text, ApiTokens.ApiTokenRecord](
    "_arvo_auth_api_tokens_by_user",
    fn(t) t.user_id end
  )
end

## Typed `Modb.Table` for `_arvo_auth_api_tokens`.
fn api_tokens_table() : Table.Table(Text, ApiTokens.ApiTokenRecord)
  Table.text_key[ApiTokens.ApiTokenRecord]("_arvo_auth_api_tokens").with_index(api_tokens_by_user())
end

fn orgs_by_slug() : Table.Index(Text, Orgs.Org, Text)
  Table.unique_text_index[Text, Orgs.Org]("_arvo_auth_orgs_by_slug", fn(o) o.slug end)
end

## Typed `Modb.Table` for `_arvo_auth_orgs`.
fn orgs_table() : Table.Table(Text, Orgs.Org)
  Table.text_key[Orgs.Org]("_arvo_auth_orgs").with_index(orgs_by_slug())
end

fn memberships_by_org() : Table.Index(Text, Orgs.Membership, Text)
  Table.text_index[Text, Orgs.Membership]("_arvo_auth_memb_by_org", fn(m) m.org_id end)
end

fn memberships_by_user() : Table.Index(Text, Orgs.Membership, Text)
  Table.text_index[Text, Orgs.Membership]("_arvo_auth_memb_by_user", fn(m) m.user_id end)
end

## Typed `Modb.Table` for `_arvo_auth_memberships` (composite key `org_id|user_id`).
fn memberships_table() : Table.Table(Text, Orgs.Membership)
  Table.text_key[Orgs.Membership]("_arvo_auth_memberships").with_index(memberships_by_org())
    .with_index(memberships_by_user())
end

fn invites_by_hash() : Table.Index(Text, Orgs.OrgInvite, Text)
  Table.unique_text_index[Text, Orgs.OrgInvite](
    "_arvo_auth_invites_by_hash",
    fn(v) v.token_hash end
  )
end

fn invites_by_org() : Table.Index(Text, Orgs.OrgInvite, Text)
  Table.text_index[Text, Orgs.OrgInvite]("_arvo_auth_invites_by_org", fn(v) v.org_id end)
end

## Typed `Modb.Table` for `_arvo_auth_org_invites`.
fn org_invites_table() : Table.Table(Text, Orgs.OrgInvite)
  Table.text_key[Orgs.OrgInvite]("_arvo_auth_org_invites").with_index(invites_by_hash()).with_index(
    invites_by_org()
  )
end

fn membership_key(org_id: Text, user_id: Text) : Text
  "#{org_id}|#{user_id}"
end

fn map_table_err(e: Table.TableError) : AuthError
  LedgerFailure(Ledger.TableFailure(e))
end

fn meta_for(principal: Text, action: Text, now: Time) : Ledger.WriteMeta
  Ledger.WriteMeta(principal: principal, action: action, reason: "", at: now)
end

fn tx_insert_user_and_identity(tx: Modb.WriteTx, u: Auth.User, ident: Auth.AuthIdentity) : Result(
  (Modb.WriteTx, Auth.User),
  AuthError
)
  ut = users_table()
  it = identities_table()
  if (try Table.tx_lookup_unique(tx, ut, users_by_email(), u.email).map_error(map_table_err)) is
    Some(_)
    return Error(Conflict("email '#{u.email}' already registered"))
  end
  if (
    try Table.tx_lookup_unique(
      tx,
      it,
      ident_by_subj(),
      "#{ident.provider}|#{ident.provider_subject}"
    ).map_error(map_table_err)
  ) is
    Some(_)
    return Error(Conflict("identity '#{ident.provider}:#{ident.provider_subject}' already exists"))
  end
  tx1 = try Table.put(tx, ut, u.id, u).map_error(map_table_err)
  tx2 = try Table.put(tx1, it, ident.id, ident).map_error(map_table_err)
  Ok((tx2, u))
end

## Creates a user + `"password"` identity in `db_path`, provisions an erasure DEK, and logs `"auth.user_created"`.
fn create_user_with_password(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  email: Text,
  password: Text,
  policy: Auth.PasswordPolicy,
  display_name: Option(Text),
  verify_immediately?: Bool
) : Result(Auth.User, AuthError)
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
  meta = meta_for("user:#{uid}", "auth.user_created", now)
  payload = Json.Object({"user_id": Json.String(uid), "provider": Json.String("password")})
  created = try Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta,
    "created user #{uid}",
    payload,
    fn(e) LedgerFailure(e) end,
    fn(tx) tx_insert_user_and_identity(tx, user, ident) end
  )
  _dek = try Erasure.provision_subject_key_locked(
    files,
    db_path,
    auth_schema(),
    rng,
    uid,
    meta_for("system", "auth.provision_dek", now)
  ).map_error(fn(e) ErasureFailure(e) end)
  Ok(created)
end

## Creates a passwordless user + external identity in `db_path`, provisions an erasure DEK, and logs `"auth.user_created"`.
fn create_user_with_identity(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  email: Text,
  provider: Text,
  provider_subject: Text,
  email_verified_at: Option(Time),
  display_name: Option(Text),
  avatar_url: Option(Text)
) : Result(Auth.User, AuthError)
  norm = Auth.normalize_email(email)
  return Error(Validation("email cannot be empty")) if norm.empty?
  if provider.trim.empty? or provider_subject.trim.empty?
    return Error(Validation("provider/subject cannot be empty"))
  end
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
  meta = meta_for("user:#{uid}", "auth.user_created", now)
  payload = Json.Object({"user_id": Json.String(uid), "provider": Json.String(ident.provider)})
  created = try Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta,
    "created user #{uid}",
    payload,
    fn(e) LedgerFailure(e) end,
    fn(tx) tx_insert_user_and_identity(tx, user, ident) end
  )
  _dek = try Erasure.provision_subject_key_locked(
    files,
    db_path,
    auth_schema(),
    rng,
    uid,
    meta_for("system", "auth.provision_dek", now)
  ).map_error(fn(e) ErasureFailure(e) end)
  Ok(created)
end

## Lock-free read of a user by `user_id` via `ReadFiles`.
fn get_user(rf: ReadFiles, db_path: Text, user_id: Text) : Result(Option(Auth.User), AuthError)
  return Ok(None) if not rf.exists?(db_path)
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db) Table.get(Ledger.store(db), users_table(), user_id).map_error(map_table_err) end
  )
end

## Lock-free lookup of a user by normalized email via `_arvo_auth_users_by_email`.
fn find_user_by_email(rf: ReadFiles, db_path: Text, email: Text) : Result(
  Option(Auth.User),
  AuthError
)
  norm = Auth.normalize_email(email)
  return Ok(None) if norm.empty? or not rf.exists?(db_path)
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db)
      opt = try Table.lookup_unique(Ledger.store(db), users_table(), users_by_email(), norm)
        .map_error(map_table_err)
      Ok(opt.map(fn(p) p.1 end))
    end
  )
end

## Lock-free lookup of a user by `(provider, provider_subject)` via `_arvo_auth_ident_by_subj`.
fn find_user_by_identity(rf: ReadFiles, db_path: Text, provider: Text, provider_subject: Text) : Result(
  Option(Auth.User),
  AuthError
)
  return Ok(None) if not rf.exists?(db_path)
  subj_key = "#{provider.trim}|#{provider_subject.trim}"
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db)
      s = Ledger.store(db)
      ident_opt = try Table.lookup_unique(s, identities_table(), ident_by_subj(), subj_key)
        .map_error(map_table_err)
      case ident_opt
        None: Ok(None)
        Some((_id, ident)): Table.get(s, users_table(), ident.user_id).map_error(map_table_err)
      end
    end
  )
end

## Links an external identity to `user_id` inside `Modb.Ledger`.
fn link_identity(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  user_id: Text,
  provider: Text,
  provider_subject: Text,
  email: Text
) : Result(Auth.AuthIdentity, AuthError)
  now = clock.now
  ident = Auth.AuthIdentity(
    id: "idn_#{rng.bytes(16).to_hex}",
    user_id: user_id,
    provider: provider.trim,
    provider_subject: provider_subject.trim,
    email: Auth.normalize_email(email),
    password_hash: None,
    created_at: now
  )
  meta = meta_for("user:#{user_id}", "auth.identity_linked", now)
  payload = Json.Object({"user_id": Json.String(user_id), "provider": Json.String(ident.provider)})
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta,
    "linked identity #{ident.provider}",
    payload,
    fn(e) LedgerFailure(e) end,
    fn(tx)
      _u = try (try Table.tx_get(tx, users_table(), user_id).map_error(map_table_err)).or_fail(
        RecordNotFound("user '#{user_id}' not found")
      )
      tx1 = try Table.put(tx, identities_table(), ident.id, ident).map_error(map_table_err)
      Ok((tx1, ident))
    end
  )
end

## Verifies password timing-safely and appends `"auth.login"` or `"auth.login_failed"` into `Modb.Ledger`.
fn authenticate_password(files: Files, db_path: Text, clock: Clock, email: Text, password: Text) : Result(
  Option(Auth.User),
  AuthError
)
  norm = Auth.normalize_email(email)
  now = clock.now
  (maybe_user, maybe_hash) = if not files.read_only.exists?(db_path) or norm.empty?
    (None, None)
  else
    try Ledger.read_locked(
      files.read_only,
      db_path,
      auth_schema(),
      fn(e) LedgerFailure(e) end,
      fn(db)
        s = Ledger.store(db)
        u_pair = try Table.lookup_unique(s, users_table(), users_by_email(), norm).map_error(
          map_table_err
        )
        case u_pair
          None: Ok((None, None))
          Some((_uid, u)):
            idents = try Table.lookup(s, identities_table(), ident_by_user(), u.id).map_error(
              map_table_err
            )
            pw_ident = idents.find(fn(p) p.1.provider == "password" end).map(fn(p) p.1 end)
            pw_hash_opt = case pw_ident
              Some(i): i.password_hash
              None: None
            end
            Ok((Some(u), pw_hash_opt))
        end
      end
    )
  end

  ok? = Auth.verify_password_timing_safe(password, maybe_hash)
  active_user = case maybe_user
    Some(u) if ok? and Auth.user_active?(u): Some(u)
    Some(_) | None: None
  end
  if files.read_only.exists?(db_path)
    action = if active_user is Some(_): "auth.login" else: "auth.login_failed"
    principal = case active_user
      Some(u): "user:#{u.id}"
      None: "anonymous"
    end
    _log = try Ledger.transact_locked(
      files,
      db_path,
      auth_schema(),
      meta_for(principal, action, now),
      action,
      Json.Object({"email_sha256": Json.String(Auth.hash_raw_token(norm))}),
      fn(e) LedgerFailure(e) end,
      fn(tx) Ok((tx, Unit)) end
    )
  end
  Ok(active_user)
end

fn tx_delete_tokens_for_user(tx: Modb.WriteTx, user_id: Text) : Result(Modb.WriteTx, AuthError)
  tt = tokens_table()
  rows = try Table.tx_lookup(tx, tt, tokens_by_user(), user_id).map_error(map_table_err)
  var cur = tx
  for (tid, _t) in rows
    cur = try Table.delete(cur, tt, tid).map_error(map_table_err)
  end
  Ok(cur)
end

## Changes `user_id`'s password, deletes pending tokens, revokes all active sessions, and logs `"auth.password_changed"`.
fn change_password(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  user_id: Text,
  new_password: Text,
  policy: Auth.PasswordPolicy
) : Result(Int, AuthError)
  u = try (try get_user(files.read_only, db_path, user_id)).or_fail(
    RecordNotFound("user '#{user_id}' not found")
  )
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
  now = clock.now
  new_iid = "idn_#{rng.bytes(16).to_hex}"
  meta = meta_for("user:#{user_id}", "auth.password_changed", now)
  payload = Json.Object({"user_id": Json.String(user_id)})
  _tx = try Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta,
    "password changed",
    payload,
    fn(e) LedgerFailure(e) end,
    fn(tx)
      cur_u = try (try Table.tx_get(tx, users_table(), user_id).map_error(map_table_err)).or_fail(
        RecordNotFound("user '#{user_id}' not found")
      )
      var next_u = cur_u
      next_u.updated_at = now
      tx1 = try Table.put(tx, users_table(), user_id, next_u).map_error(map_table_err)
      idents = try Table.tx_lookup(tx1, identities_table(), ident_by_user(), user_id).map_error(
        map_table_err
      )
      pw_pair = idents.find(fn(p) p.1.provider == "password" end)
      tx2 = case pw_pair
        Some((iid, existing_ident)):
          var ni = existing_ident
          ni.password_hash = Some(new_hash)
          try Table.put(tx1, identities_table(), iid, ni).map_error(map_table_err)
        None:
          ni = Auth.AuthIdentity(
            id: new_iid,
            user_id: user_id,
            provider: "password",
            provider_subject: cur_u.email,
            email: cur_u.email,
            password_hash: Some(new_hash),
            created_at: now
          )
          try Table.put(tx1, identities_table(), new_iid, ni).map_error(map_table_err)
      end
      tx3 = try tx_delete_tokens_for_user(tx2, user_id)
      Ok((tx3, Unit))
    end
  )
  Sessions.revoke_all_for_member(files, db_path, user_id).map_error(
    fn(e) SessionFailure(Sessions.Storage(e)) end
  )
end

## Changes `user_id`'s email and invalidates all outstanding `AuthToken`s for that user.
fn change_email(
  files: Files,
  db_path: Text,
  clock: Clock,
  user_id: Text,
  new_email: Text,
  verified_now?: Bool
) : Result(Unit, AuthError)
  norm = Auth.normalize_email(new_email)
  return Error(Validation("email cannot be empty")) if norm.empty?
  now = clock.now
  meta = meta_for("user:#{user_id}", "auth.email_changed", now)
  payload = Json.Object({"user_id": Json.String(user_id)})
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta,
    "email changed",
    payload,
    fn(e) LedgerFailure(e) end,
    fn(tx)
      cur_u = try (try Table.tx_get(tx, users_table(), user_id).map_error(map_table_err)).or_fail(
        RecordNotFound("user '#{user_id}' not found")
      )
      case try Table.tx_lookup_unique(tx, users_table(), users_by_email(), norm).map_error(
        map_table_err
      )
        Some((other_id, _)) if other_id != user_id: return Error(
          Conflict("email '#{norm}' already in use")
        )
        Some(_) | None: Unit
      end
      var next_u = cur_u
      next_u.email = norm
      next_u.email_verified_at = if verified_now?: Some(now) else: None
      next_u.updated_at = now
      tx1 = try Table.put(tx, users_table(), user_id, next_u).map_error(map_table_err)
      idents = try Table.tx_lookup(tx1, identities_table(), ident_by_user(), user_id).map_error(
        map_table_err
      )
      var cur_tx = tx1
      for (iid, ident) in idents
        if ident.provider == "password"
          var ni = ident
          ni.email = norm
          ni.provider_subject = norm
          cur_tx = try Table.put(cur_tx, identities_table(), iid, ni).map_error(map_table_err)
        end
      end
      tx_final = try tx_delete_tokens_for_user(cur_tx, user_id)
      Ok((tx_final, Unit))
    end
  )
end

## Marks `user_id`'s email verified at `clock.now`.
fn verify_user_email(files: Files, db_path: Text, clock: Clock, user_id: Text) : Result(
  Unit,
  AuthError
)
  now = clock.now
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("user:#{user_id}", "auth.email_verified", now),
    "email verified",
    Json.Object({"user_id": Json.String(user_id)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      u = try (try Table.tx_get(tx, users_table(), user_id).map_error(map_table_err)).or_fail(
        RecordNotFound("user '#{user_id}' not found")
      )
      var next_u = u
      next_u.email_verified_at = Some(now)
      next_u.updated_at = now
      tx1 = try Table.put(tx, users_table(), user_id, next_u).map_error(map_table_err)
      Ok((tx1, Unit))
    end
  )
end

## Issues and stores a single-use SHA-256 `AuthToken`, logging `"auth.token_issued"`.
fn issue_and_store_token(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  user_id: Option(Text),
  purpose: Auth.TokenPurpose,
  target_email: Text,
  ttl_seconds: Int
) : Result(Auth.IssuedToken, AuthError)
  issued = Auth.issue_auth_token(rng, clock, user_id, purpose, target_email, ttl_seconds)
  tok = issued.token
  now = tok.created_at
  meta = meta_for(user_id.map(fn(id) "user:#{id}" end) or "anonymous", "auth.token_issued", now)
  payload = Json.Object({
    "token_id": Json.String(tok.id),
    "purpose": Json.String(Auth.purpose_to_text(tok.purpose))
  })
  _tx = try Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta,
    "token issued",
    payload,
    fn(e) LedgerFailure(e) end,
    fn(tx)
      tx1 = try Table.put(tx, tokens_table(), tok.id, tok).map_error(map_table_err)
      Ok((tx1, Unit))
    end
  )
  Ok(issued)
end

## Atomically verifies and consumes a single-use `AuthToken`, logging `"auth.token_consumed"`.
fn consume_auth_token(
  files: Files,
  db_path: Text,
  clock: Clock,
  raw_token: Text,
  expected_purpose: Auth.TokenPurpose,
  expected_email: Option(Text)
) : Result(Auth.AuthToken, AuthError)
  return Error(InvalidOrExpiredToken) if raw_token.empty? or not files.read_only.exists?(db_path)
  tok_hash = Auth.hash_raw_token(raw_token)
  now = clock.now
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("token", "auth.token_consumed", now),
    "token consumed",
    Json.Object({"purpose": Json.String(Auth.purpose_to_text(expected_purpose))}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      pair = try Table.tx_lookup_unique(tx, tokens_table(), tokens_by_hash(), tok_hash).map_error(
        map_table_err
      )
      (tid, stored) = case pair
        Some(p): p
        None: return Error(InvalidOrExpiredToken)
      end
      if not Auth.token_valid?(stored, raw_token, expected_purpose, expected_email, now)
        return Error(InvalidOrExpiredToken)
      end
      var updated = stored
      updated.used_at = Some(now)
      tx1 = try Table.put(tx, tokens_table(), tid, updated).map_error(map_table_err)
      Ok((tx1, updated))
    end
  )
end

## Stores a Keyring-sealed TOTP secret + SHA-256 recovery digests and logs `"auth.mfa_enrolled"`.
fn enroll_totp(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  clock: Clock,
  user_id: Text,
  secret: Bytes,
  recovery_digests: List(Text)
) : Result(StoredTotp, AuthError)
  sealed = try Totp.seal_secret(rng, keyring, user_id, secret).map_error(
    fn(e) CryptoFailed(Totp.to_text(e)) end
  )
  now = clock.now
  rec = StoredTotp(
    user_id: user_id,
    sealed_secret: sealed,
    enabled?: true,
    last_used_step: None,
    recovery_digests: recovery_digests,
    created_at: now,
    updated_at: now
  )
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("user:#{user_id}", "auth.mfa_enrolled", now),
    "totp enrolled",
    Json.Object({"user_id": Json.String(user_id)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      u = try (try Table.tx_get(tx, users_table(), user_id).map_error(map_table_err)).or_fail(
        RecordNotFound("user '#{user_id}' not found")
      )
      var nu = u
      nu.mfa_enabled? = true
      nu.updated_at = now
      tx1 = try Table.put(tx, users_table(), user_id, nu).map_error(map_table_err)
      tx2 = try Table.put(tx1, totp_table(), user_id, rec).map_error(map_table_err)
      Ok((tx2, rec))
    end
  )
end

## Lock-free read of a user's TOTP credential.
fn get_totp(rf: ReadFiles, db_path: Text, user_id: Text) : Result(Option(StoredTotp), AuthError)
  return Ok(None) if not rf.exists?(db_path)
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db) Table.get(Ledger.store(db), totp_table(), user_id).map_error(map_table_err) end
  )
end

## Atomically verifies TOTP and updates monotonic `last_used_step` inside `Modb.Ledger`.
fn verify_totp_for_user(
  files: Files,
  db_path: Text,
  keyring: Keyring.Keyring,
  clock: Clock,
  user_id: Text,
  code: Text,
  cfg: Totp.TotpConfig
) : Result(Totp.TotpVerifyResult, AuthError)
  return Ok(Totp.InvalidCode) if not files.read_only.exists?(db_path)
  now = clock.now
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("user:#{user_id}", "auth.mfa_verified", now),
    "totp check",
    Json.Object({"user_id": Json.String(user_id)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      rec = case try Table.tx_get(tx, totp_table(), user_id).map_error(map_table_err)
        Some(r) if r.enabled?: r
        Some(_) | None: return Ok((tx, Totp.InvalidCode))
      end
      (secret, _rekey?) = case Totp.open_secret(keyring, user_id, rec.sealed_secret)
        Ok(v): v
        Error(e): return Error(CryptoFailed(Totp.to_text(e)))
      end
      vres = Totp.verify(secret, code, now, cfg, rec.last_used_step)
      case vres
        Totp.Accepted(matched_step: step):
          var next_rec = rec
          next_rec.last_used_step = Some(step)
          next_rec.updated_at = now
          tx1 = try Table.put(tx, totp_table(), user_id, next_rec).map_error(map_table_err)
          Ok((tx1, vres))
        Totp.ReplayedStep(step: _) | Totp.InvalidCode: Ok((tx, vres))
      end
    end
  )
end

## Atomically consumes one recovery code for `user_id` inside `Modb.Ledger`.
fn consume_recovery_code_for_user(
  files: Files,
  db_path: Text,
  clock: Clock,
  user_id: Text,
  candidate: Text
) : Result(Bool, AuthError)
  return Ok(false) if not files.read_only.exists?(db_path)
  now = clock.now
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("user:#{user_id}", "auth.recovery_code_used", now),
    "recovery code check",
    Json.Object({"user_id": Json.String(user_id)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      rec = case try Table.tx_get(tx, totp_table(), user_id).map_error(map_table_err)
        Some(r) if r.enabled?: r
        Some(_) | None: return Ok((tx, false))
      end
      rem = case Totp.verify_and_consume_recovery_code(candidate, rec.recovery_digests)
        Some(r): r
        None: return Ok((tx, false))
      end
      var next_rec = rec
      next_rec.recovery_digests = rem
      next_rec.updated_at = now
      tx1 = try Table.put(tx, totp_table(), user_id, next_rec).map_error(map_table_err)
      Ok((tx1, true))
    end
  )
end

## Registers a WebAuthn passkey and logs `"auth.passkey_registered"`.
fn register_passkey(
  files: Files,
  db_path: Text,
  clock: Clock,
  user_id: Text,
  name: Text,
  pk: Webauthn.RegisteredPasskey
) : Result(StoredPasskey, AuthError)
  now = clock.now
  rec = StoredPasskey(
    credential_id: pk.credential_id,
    user_id: user_id,
    name: if name.trim.empty?: "Passkey" else: name.trim,
    public_key_b64url: pk.public_key_b64url,
    alg: pk.alg,
    sign_count: pk.sign_count,
    aaguid_hex: pk.aaguid_hex,
    backed_up?: pk.backed_up?,
    created_at: now,
    last_used_at: None
  )
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("user:#{user_id}", "auth.passkey_registered", now),
    "passkey registered",
    Json.Object({"user_id": Json.String(user_id)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      tx1 = try Table.put(tx, passkeys_table(), rec.credential_id, rec).map_error(map_table_err)
      Ok((tx1, rec))
    end
  )
end

## Lock-free read of a passkey credential by ID.
fn get_passkey(rf: ReadFiles, db_path: Text, credential_id: Text) : Result(
  Option(StoredPasskey),
  AuthError
)
  return Ok(None) if not rf.exists?(db_path)
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db) Table.get(Ledger.store(db), passkeys_table(), credential_id).map_error(map_table_err) end
  )
end

## Lists all registered passkeys for `user_id` via `_arvo_auth_passkeys_by_user`.
fn list_passkeys_for_user(rf: ReadFiles, db_path: Text, user_id: Text) : Result(
  List(StoredPasskey),
  AuthError
)
  return Ok([]) if not rf.exists?(db_path)
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db)
      rows = try Table.lookup(Ledger.store(db), passkeys_table(), passkeys_by_user(), user_id)
        .map_error(map_table_err)
      Ok(rows.map(fn(p) p.1 end))
    end
  )
end

## Atomically verifies monotonic `sign_count` and logs `"auth.passkey_used"`.
fn record_passkey_use(
  files: Files,
  db_path: Text,
  clock: Clock,
  credential_id: Text,
  new_sign_count: Int,
  backed_up?: Bool
) : Result(Unit, AuthError)
  now = clock.now
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("passkey:#{credential_id}", "auth.passkey_used", now),
    "passkey used",
    Json.Object({"credential_id": Json.String(credential_id)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      rec = try (try Table.tx_get(tx, passkeys_table(), credential_id).map_error(map_table_err))
        .or_fail(RecordNotFound("passkey '#{credential_id}' not found"))
      if rec.sign_count > 0 and new_sign_count <= rec.sign_count
        return Error(Conflict("cloned passkey signCount detected"))
      end
      var updated = rec
      updated.sign_count = new_sign_count
      updated.backed_up? = backed_up?
      updated.last_used_at = Some(now)
      tx1 = try Table.put(tx, passkeys_table(), credential_id, updated).map_error(map_table_err)
      Ok((tx1, Unit))
    end
  )
end

## Mints and persists an API / AI Agent bearer token and logs `"auth.api_token_minted"`.
fn mint_api_token(
  files: Files,
  db_path: Text,
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
) : Result(ApiTokens.IssuedApiToken, AuthError)
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
  _tx = try Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("user:#{user_id}", "auth.api_token_minted", rec.created_at),
    "api token minted",
    Json.Object({"token_id": Json.String(rec.id), "prefix": Json.String(rec.prefix)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      tx1 = try Table.put(tx, api_tokens_table(), rec.id, rec).map_error(map_table_err)
      Ok((tx1, Unit))
    end
  )
  Ok(issued)
end

## Revokes an API token and logs `"auth.api_token_revoked"`.
fn revoke_api_token(files: Files, db_path: Text, clock: Clock, token_id: Text) : Result(
  Bool,
  AuthError
)
  return Ok(false) if not files.read_only.exists?(db_path)
  now = clock.now
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("token:#{token_id}", "auth.api_token_revoked", now),
    "api token revoked",
    Json.Object({"token_id": Json.String(token_id)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      rec = case try Table.tx_get(tx, api_tokens_table(), token_id).map_error(map_table_err)
        Some(r) if r.revoked_at is None: r
        Some(_) | None: return Ok((tx, false))
      end
      var updated = rec
      updated.revoked_at = Some(now)
      tx1 = try Table.put(tx, api_tokens_table(), token_id, updated).map_error(map_table_err)
      Ok((tx1, true))
    end
  )
end

## Lock-free listing of API tokens for `user_id` via `_arvo_auth_api_tokens_by_user`.
fn list_api_tokens_for_user(rf: ReadFiles, db_path: Text, user_id: Text) : Result(
  List(ApiTokens.ApiTokenRecord),
  AuthError
)
  return Ok([]) if not rf.exists?(db_path)
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db)
      rows = try Table.lookup(Ledger.store(db), api_tokens_table(), api_tokens_by_user(), user_id)
        .map_error(map_table_err)
      Ok(rows.map(fn(p) p.1 end))
    end
  )
end

## `ReadFiles`-only request authentication (ZERO disk writes!) supporting BOTH Bearer API tokens
## and keyring-rotated encrypted cookie sessions.
fn authenticate_request(
  req: Api.Request,
  rf: ReadFiles,
  db_path: Text,
  clock: Clock,
  keyring: Keyring.Keyring,
  session_cfg: Session.SessionConfig
) : Result(Option(Principal), AuthError)
  return Ok(None) if not rf.exists?(db_path)

  if ApiTokens.parse_bearer_header(req) is Some(parsed)
    now = clock.now
    return Ledger.read_locked(
      rf,
      db_path,
      auth_schema(),
      fn(e) LedgerFailure(e) end,
      fn(db)
        s = Ledger.store(db)
        tok = case try Table.get(s, api_tokens_table(), parsed.token_id).map_error(map_table_err)
          Some(t): t
          None: return Ok(None)
        end
        return Ok(None) if not ApiTokens.verify_token(tok, parsed, now)
        user = case try Table.get(s, users_table(), tok.user_id).map_error(map_table_err)
          Some(u) if Auth.user_active?(u): u
          Some(_) | None: return Ok(None)
        end
        Ok(Some(ApiTokenPrincipal(user: user, token: tok)))
      end
    )
  end

  loaded = try Sessions.load_read_only_with_keyring(req, rf, db_path, clock, keyring, session_cfg)
    .map_error(fn(e) SessionFailure(e) end)
  (sess, view, rekey?) = case loaded
    Some(triple): triple
    None: return Ok(None)
  end
  user_opt = try get_user(rf, db_path, sess.member_id)
  case user_opt
    Some(u) if Auth.user_active?(u): Ok(
      Some(SessionPrincipal(user: u, session: sess, view: view, needs_rekey?: rekey?))
    )
    Some(_) | None: Ok(None)
  end
end

## Authenticates an AI agent Bearer token, validates its active `Modb.Grants` chain, and ensures
## a persistent `Modb.Taint` session bound to `grant_id`.
fn authenticate_agent_token(
  req: Api.Request,
  files: Files,
  db_path: Text,
  clock: Clock,
  taint_session_prefix: Text
) : Result(Option(AgentPrincipal), AuthError)
  return Ok(None) if not files.read_only.exists?(db_path)
  parsed = case ApiTokens.parse_bearer_header(req)
    Some(p): p
    None: return Ok(None)
  end
  now = clock.now
  (user, tok, grant) = case try Ledger.read_locked(
    files.read_only,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db)
      s = Ledger.store(db)
      tok = case try Table.get(s, api_tokens_table(), parsed.token_id).map_error(map_table_err)
        Some(t): t
        None: return Ok(None)
      end
      return Ok(None) if not ApiTokens.verify_token(tok, parsed, now)
      user = case try Table.get(s, users_table(), tok.user_id).map_error(map_table_err)
        Some(u) if Auth.user_active?(u): u
        Some(_) | None: return Ok(None)
      end
      gid = case tok.grant_id
        Some(g): g
        None: return Error(AgentGrantRequired)
      end
      tx = Modb.begin_write(s)
      grant = try Grants.tx_verify_active(tx, gid, now).map_error(fn(e) GrantFailure(e) end)
      Ok(Some((user, tok, grant)))
    end
  )
    Some(t): t
    None: return Ok(None)
  end

  prefix = if taint_session_prefix.trim.empty?: "agent" else: taint_session_prefix.trim
  ts = try Taint.ensure_session_locked(
    files,
    db_path,
    auth_schema(),
    "#{prefix}:#{tok.id}",
    "user:#{user.id}",
    Some(grant.id),
    now
  ).map_error(fn(e) TaintFailure(e) end)
  Ok(Some(AgentPrincipal(user: user, token: tok, grant: grant, taint_session: ts)))
end

## Creates an organization in `db_path` and logs `"auth.org_created"`.
fn create_org(files: Files, db_path: Text, rng: SecureRandom, clock: Clock, slug: Text, name: Text) : Result(
  Orgs.Org,
  AuthError
)
  clean_slug = slug.trim.ascii_lowercase
  return Error(Validation("invalid slug '#{slug}'")) if not Orgs.valid_slug?(clean_slug)
  clean_name = name.trim
  return Error(Validation("organization name cannot be empty")) if clean_name.empty?
  now = clock.now
  org = Orgs.Org(
    id: "org_#{rng.bytes(16).to_hex}",
    slug: clean_slug,
    name: clean_name,
    created_at: now
  )
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("org:#{org.id}", "auth.org_created", now),
    "org created",
    Json.Object({"org_id": Json.String(org.id), "slug": Json.String(org.slug)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      if (
        try Table.tx_lookup_unique(tx, orgs_table(), orgs_by_slug(), clean_slug).map_error(
          map_table_err
        )
      ) is
        Some(_)
        return Error(Conflict("organization slug '#{clean_slug}' already exists"))
      end
      tx1 = try Table.put(tx, orgs_table(), org.id, org).map_error(map_table_err)
      Ok((tx1, org))
    end
  )
end

## Lock-free lookup of an organization by `slug`.
fn get_org_by_slug(rf: ReadFiles, db_path: Text, slug: Text) : Result(Option(Orgs.Org), AuthError)
  return Ok(None) if not rf.exists?(db_path)
  clean = slug.trim.ascii_lowercase
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db)
      opt = try Table.lookup_unique(Ledger.store(db), orgs_table(), orgs_by_slug(), clean).map_error(
        map_table_err
      )
      Ok(opt.map(fn(p) p.1 end))
    end
  )
end

## Adds an organization membership row and logs `"auth.membership_updated"`.
fn add_membership(
  files: Files,
  db_path: Text,
  clock: Clock,
  org_id: Text,
  user_id: Text,
  role: Orgs.OrgRole
) : Result(Orgs.Membership, AuthError)
  now = clock.now
  m = Orgs.Membership(org_id: org_id, user_id: user_id, role: role, joined_at: now)
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("org:#{org_id}", "auth.membership_updated", now),
    "membership added",
    Json.Object({"org_id": Json.String(org_id), "user_id": Json.String(user_id)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      k = membership_key(org_id, user_id)
      tx1 = try Table.put(tx, memberships_table(), k, m).map_error(map_table_err)
      Ok((tx1, m))
    end
  )
end

## Lists memberships for `org_id`.
fn list_org_memberships(rf: ReadFiles, db_path: Text, org_id: Text) : Result(
  List(Orgs.Membership),
  AuthError
)
  return Ok([]) if not rf.exists?(db_path)
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db)
      rows = try Table.lookup(Ledger.store(db), memberships_table(), memberships_by_org(), org_id)
        .map_error(map_table_err)
      Ok(rows.map(fn(p) p.1 end))
    end
  )
end

## Lists organizations `user_id` belongs to.
fn list_user_memberships(rf: ReadFiles, db_path: Text, user_id: Text) : Result(
  List(Orgs.Membership),
  AuthError
)
  return Ok([]) if not rf.exists?(db_path)
  Ledger.read_locked(
    rf,
    db_path,
    auth_schema(),
    fn(e) LedgerFailure(e) end,
    fn(db)
      rows = try Table.lookup(Ledger.store(db), memberships_table(), memberships_by_user(), user_id)
        .map_error(map_table_err)
      Ok(rows.map(fn(p) p.1 end))
    end
  )
end

## Updates `user_id`'s role inside `org_id`, enforcing last-owner protection.
fn update_membership_role(
  files: Files,
  db_path: Text,
  clock: Clock,
  org_id: Text,
  user_id: Text,
  new_role: Orgs.OrgRole
) : Result(Unit, AuthError)
  now = clock.now
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("org:#{org_id}", "auth.membership_updated", now),
    "membership role updated",
    Json.Object({"org_id": Json.String(org_id), "role": Json.String(Orgs.role_to_text(new_role))}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      mt = memberships_table()
      rows = try Table.tx_lookup(tx, mt, memberships_by_org(), org_id).map_error(map_table_err)
      ms = rows.map(fn(p) p.1 end)
      existing = ms.find(fn(m) m.user_id == user_id end)
      cur_m = try existing.or_fail(RecordNotFound("membership not found"))
      if not Orgs.can_remove_or_demote?(ms, user_id, Some(new_role))
        return Error(LastOwnerProtected)
      end
      var nm = cur_m
      nm.role = new_role
      tx1 = try Table.put(tx, mt, membership_key(org_id, user_id), nm).map_error(map_table_err)
      Ok((tx1, Unit))
    end
  )
end

## Removes `user_id` from `org_id`, enforcing last-owner protection.
fn remove_membership(files: Files, db_path: Text, clock: Clock, org_id: Text, user_id: Text) : Result(
  Unit,
  AuthError
)
  now = clock.now
  Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("org:#{org_id}", "auth.membership_updated", now),
    "membership removed",
    Json.Object({"org_id": Json.String(org_id), "user_id": Json.String(user_id)}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      mt = memberships_table()
      rows = try Table.tx_lookup(tx, mt, memberships_by_org(), org_id).map_error(map_table_err)
      ms = rows.map(fn(p) p.1 end)
      if not ms.any?(fn(m) m.user_id == user_id end)
        return Error(RecordNotFound("membership not found"))
      end
      if not Orgs.can_remove_or_demote?(ms, user_id, None)
        return Error(LastOwnerProtected)
      end
      tx1 = try Table.delete(tx, mt, membership_key(org_id, user_id)).map_error(map_table_err)
      Ok((tx1, Unit))
    end
  )
end

## GDPR Right-to-be-Forgotten account deletion: enforces last-owner safety, revokes all sessions,
## cleans all indexed `_arvo_auth_*` tables via `Table.delete`, shreds per-subject DEK & scrubs
## audit history via `Modb.Erasure.erase_subject_locked`, and returns an `ErasureReceipt`.
fn delete_account_with_erasure(
  files: Files,
  db_path: Text,
  clock: Clock,
  user_id: Text,
  reviewer: Text,
  reason: Text
) : Result(Erasure.ErasureReceipt, AuthError)
  u = try (try get_user(files.read_only, db_path, user_id)).or_fail(
    RecordNotFound("user '#{user_id}' not found")
  )
  now = clock.now

  # Pre-check last-owner invariant across every org user belongs to BEFORE deleting sessions/data
  user_ms = try list_user_memberships(files.read_only, db_path, user_id)
  for m in user_ms
    org_ms = try list_org_memberships(files.read_only, db_path, m.org_id)
    if org_ms.size > 1 and not Orgs.can_remove_or_demote?(org_ms, user_id, None)
      return Error(LastOwnerProtected)
    end
  end

  _rev = try Sessions.revoke_all_for_member(files, db_path, user_id).map_error(
    fn(e) SessionFailure(Sessions.Storage(e)) end
  )

  _del_tx = try Ledger.transact_locked(
    files,
    db_path,
    auth_schema(),
    meta_for("reviewer:#{reviewer}", "auth.account_deleted", now),
    "account deleted",
    Json.Object({}),
    fn(e) LedgerFailure(e) end,
    fn(tx)
      var cur = tx
      mt = memberships_table()
      mrows = try Table.tx_lookup(cur, mt, memberships_by_user(), user_id).map_error(map_table_err)
      for (mk, _) in mrows
        cur = try Table.delete(cur, mt, mk).map_error(map_table_err)
      end
      at_tbl = api_tokens_table()
      at_rows = try Table.tx_lookup(cur, at_tbl, api_tokens_by_user(), user_id).map_error(
        map_table_err
      )
      for (ak, _) in at_rows
        cur = try Table.delete(cur, at_tbl, ak).map_error(map_table_err)
      end
      pt_tbl = passkeys_table()
      p_rows = try Table.tx_lookup(cur, pt_tbl, passkeys_by_user(), user_id).map_error(
        map_table_err
      )
      for (pk, _) in p_rows
        cur = try Table.delete(cur, pt_tbl, pk).map_error(map_table_err)
      end
      cur = try Table.delete(cur, totp_table(), user_id).map_error(map_table_err)
      tt_tbl = tokens_table()
      t_rows = try Table.tx_lookup(cur, tt_tbl, tokens_by_user(), user_id).map_error(map_table_err)
      for (tk, _) in t_rows
        cur = try Table.delete(cur, tt_tbl, tk).map_error(map_table_err)
      end
      it_tbl = identities_table()
      i_rows = try Table.tx_lookup(cur, it_tbl, ident_by_user(), user_id).map_error(map_table_err)
      for (ik, _) in i_rows
        cur = try Table.delete(cur, it_tbl, ik).map_error(map_table_err)
      end
      cur = try Table.delete(cur, users_table(), user_id).map_error(map_table_err)
      Ok((cur, Unit))
    end
  )

  var req = Erasure.erasure_request("er_#{user_id}", user_id)
  req.match_tokens = [user_id, u.email]
  req.shred_key? = true
  req.scrub_audit? = true
  req.scrub_replay? = true
  req.scrub_read_log? = true
  Erasure.erase_subject_locked(files, db_path, auth_schema(), req, reviewer, true, reason, now)
    .map_error(fn(e) ErasureFailure(e) end)
end

fn must_ok_mauth(res: Result(A, B)) : A
  case res
    Ok(v): v
    Error(_): stop "unexpected Modb.Auth test error"
  end
end

test "Arvo.Modb.AuthStore full lifecycle: users, ReadFiles auth, TOTP replay, agent Grants+Taint, and GDPR Erasure"
  files = Files.in_memory({})
  rf = files.read_only
  path = "auth_v2.modb"
  rng = SecureRandom.seeded(202611)
  t0 = Time.parse("2026-11-28T00:00:00Z") or stop "t0"
  clk = Clock.fixed(t0)
  pol = Auth.default_password_policy()
  k1 = rng.bytes(32)
  k2 = rng.bytes(32)
  kr1 = must_ok_mauth(Keyring.single("k1", k1))
  kr2 = must_ok_mauth(
    Keyring.from_entries([Keyring.KeyEntry(id: "k2", key: k2), Keyring.KeyEntry(id: "k1", key: k1)])
  )
  sess_cfg = Session.default_config(true)

  # 1. Create user, verify timing-safe login, email verify token (single-use), and change_password revocation
  u = must_ok_mauth(
    create_user_with_password(
      files,
      path,
      rng,
      clk,
      " Ada@Acme.IO ",
      "correct-horse-battery",
      pol,
      Some("Ada"),
      false
    )
  )
  assert must_ok_mauth(
    authenticate_password(files, path, clk, "ada@acme.io", "correct-horse-battery")
  ) ==
    Some(u)
  assert must_ok_mauth(authenticate_password(files, path, clk, "nobody@acme.io", "nope")) == None

  ev = must_ok_mauth(
    issue_and_store_token(files, path, rng, clk, Some(u.id), Auth.EmailVerify, u.email, 300)
  )
  assert consume_auth_token(files, path, clk, ev.raw_token, Auth.PasswordReset, None) ==
    Error(InvalidOrExpiredToken)
  assert must_ok_mauth(consume_auth_token(files, path, clk, ev.raw_token, Auth.EmailVerify, None))
    .user_id ==
    Some(u.id)
  assert consume_auth_token(files, path, clk, ev.raw_token, Auth.EmailVerify, None) ==
    Error(InvalidOrExpiredToken)
  _ver = must_ok_mauth(verify_user_email(files, path, clk, u.id))

  # Create session under kr1 and read lock-free via kr2 (needs_rekey? = true, ZERO disk writes!)
  (sess, cval) = must_ok_mauth(
    Sessions.create_with_keyring(files, path, rng, clk, kr1, u.id, Session.default_meta(), sess_cfg)
  )
  req_cookie = Api.get("/dashboard").with_header("Cookie", "arvo_session=#{cval}")
  assert must_ok_mauth(authenticate_request(req_cookie, rf, path, clk, kr2, sess_cfg)) is
    Some(SessionPrincipal(user: _, session: s_ld, view: _, needs_rekey?: true))
  assert s_ld.id == sess.id

  # TOTP enroll + monotonic replay protection
  sec = Totp.generate_secret(rng)
  (rcodes, rdigs) = Totp.generate_recovery_codes(rng, 4)
  _t = must_ok_mauth(enroll_totp(files, path, rng, kr2, clk, u.id, sec, rdigs))
  tcfg = Totp.default_config()
  code0 = Totp.code_at(sec, t0, tcfg)
  assert must_ok_mauth(verify_totp_for_user(files, path, kr2, clk, u.id, code0, tcfg)) is
    Totp.Accepted(matched_step: _)
  assert must_ok_mauth(verify_totp_for_user(files, path, kr2, clk, u.id, code0, tcfg)) is
    Totp.ReplayedStep(step: _)
  r0 = rcodes.first or stop "r0"
  assert must_ok_mauth(consume_recovery_code_for_user(files, path, clk, u.id, r0))
  assert not must_ok_mauth(consume_recovery_code_for_user(files, path, clk, u.id, r0))

  # AI Agent token wired to Modb.Grants + Modb.Taint
  grant = must_ok_mauth(
    Grants.issue_root_locked(
      files,
      path,
      auth_schema(),
      meta_for("user:#{u.id}", "grant.issue", t0),
      Grants.GrantSpec(
        id: "gr_agent_1",
        principal: "agent:billing",
        allowed_actions: ["bills:read"],
        max_calls: 50,
        expires_at: t0 + 3600.seconds
      )
    )
  )
  agent_tok = must_ok_mauth(
    mint_api_token(
      files,
      path,
      rng,
      clk,
      u.id,
      None,
      "Billing Agent",
      "arvo_agent",
      ["bills:read"],
      Some(grant.id),
      None,
      None
    )
  )
  req_agent = Api.get("/mcp").with_header("Authorization", "Bearer #{agent_tok.plaintext_token}")
  assert must_ok_mauth(authenticate_agent_token(req_agent, files, path, clk, "taint")) is Some(ap)
  assert ap.grant.id == grant.id and ap.taint_session.grant_id == Some(grant.id)

  # Revoking root grant immediately blocks authenticate_agent_token
  _rev_g = must_ok_mauth(
    Grants.revoke_locked(
      files,
      path,
      auth_schema(),
      meta_for("user:#{u.id}", "grant.revoke", t0),
      grant.id
    )
  )
  assert authenticate_agent_token(req_agent, files, path, clk, "taint") is
    Error(GrantFailure(Grants.Revoked(id: _, revoked_ancestor: _)))

  # Password change revokes sessions; Org last-owner prevents orphan org
  assert must_ok_mauth(change_password(files, path, rng, clk, u.id, "even-newer-passphrase", pol)) ==
    1
  assert must_ok_mauth(authenticate_request(req_cookie, rf, path, clk, kr2, sess_cfg)) == None

  u2 = must_ok_mauth(
    create_user_with_identity(
      files,
      path,
      rng,
      clk,
      "grace@acme.io",
      "google",
      "g_sub_grace",
      Some(t0),
      None,
      None
    )
  )
  org = must_ok_mauth(create_org(files, path, rng, clk, "acme-modb", "Acme MoDB"))
  _m1 = must_ok_mauth(add_membership(files, path, clk, org.id, u.id, Orgs.Owner))
  _m2 = must_ok_mauth(add_membership(files, path, clk, org.id, u2.id, Orgs.Member))
  assert remove_membership(files, path, clk, org.id, u.id) == Error(LastOwnerProtected)
  assert delete_account_with_erasure(files, path, clk, u.id, "admin_1", "user requested deletion") ==
    Error(LastOwnerProtected)

  # Promote u2 -> GDPR delete_account_with_erasure shreds DEK, deletes rows & scrubs audit chain!
  _m2_up = must_ok_mauth(update_membership_role(files, path, clk, org.id, u2.id, Orgs.Owner))
  receipt = must_ok_mauth(
    delete_account_with_erasure(files, path, clk, u.id, "admin_1", "user requested deletion")
  )
  assert receipt.key_shredded?
  assert must_ok_mauth(get_user(rf, path, u.id)) == None

  # Structural Modb.verify and Ledger tamper-evident audit hash chain BOTH pass after erasure!
  store = must_ok_mauth(Modb.open_read_only(rf, path))
  assert Modb.verify(store) is Ok(_)
  assert Ledger.verify_audit_store(store) is Ok(_)
end
