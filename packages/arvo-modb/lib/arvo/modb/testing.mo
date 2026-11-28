## MoDB testing parity (`Arvo.Modb.Testing`): deterministic seed profiles, CoW B+Tree &
## tamper-evident `Modb.Ledger` verification, `SecurityMatrixCore` route auditing, and
## formal `Arvo.Testing.Statechart` replay against `Arvo.Modb.Jobs`, `Arvo.Modb.Sessions`, & `Arvo.Modb.AuthStore`.
module Arvo.Modb.Testing
expose ModbSeedProfile(..),
profile_names,
find_profile,
run_seed_profile,
verify_modb_invariants,
run_security_matrix,
replay_modb_jobs_path,
replay_modb_session_path,
replay_modb_auth_path
use Api
use Arvo.Auth
use Arvo.Keyring
use Arvo.Modb.AuthStore
use Arvo.Modb.Jobs
use Arvo.Modb.Sessions
use Arvo.SecurityMatrixCore
use Arvo.Session
use Arvo.Testing.Statechart
use Arvo.Totp
use Arvo.WebTest
use Json
use Modb
use Modb.Ledger
use Modb.Table

## One named deterministic seed profile executable against an in-memory or real MoDB file.
struct ModbSeedProfile
  name: Text
  description: Text
  apply: fn(Files, Text, SecureRandom, Clock, Env) : Result(Unit, Text)
end

## Lists registered MoDB seed profile names in declaration order.
fn profile_names(profiles: List(ModbSeedProfile)) : List(Text)
  profiles.map(fn(p) p.name end)
end

## Finds a `ModbSeedProfile` by exact `name`.
fn find_profile(profiles: List(ModbSeedProfile), name: Text) : Option(ModbSeedProfile)
  profiles.find(fn(p) p.name == name end)
end

## Runs a named `ModbSeedProfile` against `(files, db_path)`.
fn run_seed_profile(
  profiles: List(ModbSeedProfile),
  name: Text,
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Unit, Text)
  case find_profile(profiles, name)
    Some(profile): profile.apply(files, db_path, rng, clock, env)
    None:
      names = profile_names(profiles)
      available = if names.empty?: "none" else: names.join(", ")
      Error("unknown modb seed profile '#{name}' (available: #{available})")
  end
end

## Verifies structural B+Tree integrity (`Modb.verify`), optional tamper-evident `Modb.Ledger`
## hash-chain audit integrity, and typed `_arvo_sessions` / `_arvo_jobs` row decoding.
fn verify_modb_invariants(rf: ReadFiles, db_path: Text, check_audit?: Bool) : Result(Unit, Text)
  if not rf.exists?(db_path)
    return Error("missing MoDB database '#{db_path}'")
  end
  store = try Modb.open_read_only(rf, db_path).map_error(fn(e) e.to_text end)
  _vrep = try Modb.verify(store).map_error(fn(e) e.to_text end)

  if check_audit?
    _arep = try Ledger.verify_audit_store(store).map_error(fn(e) e.to_text end)
  end

  buckets = try Modb.buckets(store).map_error(fn(e) e.to_text end)
  if buckets.contains?("_arvo_sessions")
    _srows = try Table.all(store, Sessions.sessions_table()).map_error(fn(e) e.to_text end)
  end
  if buckets.contains?("_arvo_jobs")
    _jrows = try Table.all(store, Jobs.jobs_table()).map_error(fn(e) e.to_text end)
  end
  if buckets.contains?("_arvo_auth_users")
    _arows = try Table.all(store, AuthStore.users_table()).map_error(fn(e) e.to_text end)
  end
  Ok(Unit)
end

## Runs `SecurityMatrixCore.run_app` against `app`, then verifies `verify_modb_invariants`
## for every `(db_path, check_audit?)` listed in `db_paths`.
fn run_security_matrix(
  app: ApiTest.App,
  rf: ReadFiles,
  db_paths: List((Text, Bool)),
  authed_session: WebTest.Session,
  cfg: SecurityMatrixCore.AuditConfig
) : SecurityMatrixCore.AuditReport
  base = SecurityMatrixCore.run_app(app, authed_session, cfg)
  var findings = base.findings
  var checks = base.checks_run
  for (db_path, check_audit?) in db_paths
    checks += 1
    case verify_modb_invariants(rf, db_path, check_audit?)
      Ok(_): Unit
      Error(msg): findings = findings.append(
        SecurityMatrixCore.make_finding(
          SecurityMatrixCore.StorageIntegrityValid,
          "MODB",
          db_path,
          "Modb.verify + Table/Ledger invariants pass",
          msg,
          ""
        )
      )
    end
  end
  SecurityMatrixCore.AuditReport(
    routes_checked: base.routes_checked,
    checks_run: checks,
    findings: findings
  )
end

## Replays an abstract `JobsModelAction` trace against real `Arvo.Modb.Jobs`, returning the
## final `JobRecord` or flagging `MODEL_DRIFT` whenever real MoDB behavior diverges.
fn replay_modb_jobs_path(
  actions: List(Statechart.JobsModelAction),
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock
) : Result(Jobs.JobRecord, Text)
  t0 = clock.now
  jid = try Jobs.enqueue_at(
    files,
    db_path,
    rng,
    clock,
    "default",
    "email.send",
    Json.Object({}),
    t0,
    2
  ).map_error(fn(e) e.to_text end)
  stale_ttl = 60
  var last_attempts = None
  for act in actions
    case act
      Statechart.TickWait:
        prev = try last_attempts.or_fail("MODEL_DRIFT: TickWait without prior Claim")
        delay = Jobs.backoff_seconds(prev)
        clock.sleep(delay.seconds)
      Statechart.Claim:
        claimed = try Jobs.claim_next(files, db_path, clock, ["email.send"]).map_error(
          fn(e) e.to_text end
        )
        case claimed
          None: return Error("MODEL_DRIFT: Claim refused by real Arvo.Modb.Jobs.claim_next")
          Some(rec): last_attempts = Some(rec.attempts)
        end
      Statechart.Complete:
        cur_att = try last_attempts.or_fail("MODEL_DRIFT: Complete without prior Claim")
        try Jobs.complete(files, db_path, clock, jid, cur_att).map_error(fn(e) e.to_text end)
      Statechart.FailOrRetry:
        cur_att = try last_attempts.or_fail("MODEL_DRIFT: FailOrRetry without prior Claim")
        try Jobs.fail_or_retry(files, db_path, clock, jid, cur_att, "transient").map_error(
          fn(e) e.to_text end
        )
      Statechart.WorkerStalls: clock.sleep(stale_ttl.seconds)
      Statechart.RequeueStale:
        changed = try Jobs.requeue_stale_running(files, db_path, clock, stale_ttl).map_error(
          fn(e) e.to_text end
        )
        if changed != 1
          return Error("MODEL_DRIFT: RequeueStale affected #{changed} row(s), expected 1")
        end
    end
  end

  Modb.with_shared_lock(
    files.read_only,
    db_path,
    fn(me) me.to_text end,
    fn(s)
      rec = try Table.get(s, Jobs.jobs_table(), jid).map_error(fn(e) e.to_text end)
      rec.or_fail("missing replayed MoDB job row")
    end
  )
end

## Replays a `SessionModelAction` trace against real `Arvo.Modb.Sessions` + `Arvo.Session`,
## returning whether the final cookie authenticates or `MODEL_DRIFT` on divergence.
fn replay_modb_session_path(
  actions: List(Statechart.SessionModelAction),
  cfg: Session.SessionConfig,
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock
) : Result(Bool, Text)
  key = try Bytes.from_hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    .or_fail("bad key")
  rf = files.read_only

  var cur_id = ""
  var cur_cookie = ""
  var old_cookie = ""
  var expected_auth? = false
  var actual_auth? = false
  for act in actions
    case act
      Statechart.CreateSession:
        (s, ck) = try Sessions.create(files, db_path, rng, clock, key, "mem_1", cfg).map_error(
          fn(e) "#{e}" end
        )
        cur_id = s.id
        cur_cookie = ck
        expected_auth? = true
      Statechart.RotateSession:
        old_cookie = cur_cookie
        (s2, ck2) = try Sessions.rotate(files, db_path, rng, clock, key, cur_id, "mem_1", cfg)
          .map_error(fn(e) "#{e}" end)
        cur_id = s2.id
        cur_cookie = ck2
        old_session = try Sessions.load_read_only(
          Api.get("/").with_header("Cookie", "#{cfg.cookie_name}=#{old_cookie}"),
          rf,
          db_path,
          clock,
          key,
          cfg
        ).map_error(fn(e) "#{e}" end)
        if old_session is Some(_)
          return Error(
            "MODEL_DRIFT: old rotated cookie accepted by real Arvo.Modb.Sessions.load_read_only"
          )
        end
        expected_auth? = true
      Statechart.ReplayOldCookie:
        loaded = try Sessions.load_read_only(
          Api.get("/").with_header("Cookie", "#{cfg.cookie_name}=#{old_cookie}"),
          rf,
          db_path,
          clock,
          key,
          cfg
        ).map_error(fn(e) "#{e}" end)
        if loaded is None
          return Error(
            "MODEL_DRIFT: old rotated cookie rejected by real Arvo.Modb.Sessions.load_read_only"
          )
        end
      Statechart.RevokeSession:
        try Sessions.revoke(files, db_path, cur_id).map_error(fn(e) e.to_text end)
        expected_auth? = false
      Statechart.ExpireTime:
        clock.sleep(cfg.ttl_seconds.seconds)
        expected_auth? = false
      Statechart.PruneExpired:
        _n = try Sessions.prune_expired(files, db_path, clock).map_error(fn(e) e.to_text end)
        expected_auth? = false
    end
    loaded_cur = try Sessions.load_read_only(
      Api.get("/").with_header("Cookie", "#{cfg.cookie_name}=#{cur_cookie}"),
      rf,
      db_path,
      clock,
      key,
      cfg
    ).map_error(fn(e) "#{e}" end)
    actual_auth? = loaded_cur is Some(_)
    if actual_auth? != expected_auth?
      return Error(
        "MODEL_DRIFT: expected auth=#{expected_auth?}, real Modb.Sessions=#{actual_auth?}"
      )
    end
  end
  Ok(actual_auth?)
end

fn rotate_modb_no_fixation(
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock,
  key: Bytes,
  cur_id: Text,
  cur_cookie: Text,
  uid: Text,
  cfg: Session.SessionConfig,
  step_name: Text
) : Result((Text, Text), Text)
  rf = files.read_only
  (ns, nck) = try Sessions.rotate(files, db_path, rng, clock, key, cur_id, uid, cfg).map_error(
    fn(e) "#{e}" end
  )
  old_loaded = try Sessions.load_read_only(
    Api.get("/").with_header("Cookie", "#{cfg.cookie_name}=#{cur_cookie}"),
    rf,
    db_path,
    clock,
    key,
    cfg
  ).map_error(fn(e) "#{e}" end)
  if old_loaded is Some(_)
    return Error("MODEL_DRIFT: pre-#{step_name} session fixation detected in Modb.Sessions")
  end
  new_loaded = try Sessions.load_read_only(
    Api.get("/").with_header("Cookie", "#{cfg.cookie_name}=#{nck}"),
    rf,
    db_path,
    clock,
    key,
    cfg
  ).map_error(fn(e) "#{e}" end)
  if new_loaded is None
    return Error("MODEL_DRIFT: rotated #{step_name} MoDB session failed to authenticate")
  end
  Ok((ns.id, nck))
end

## Replays an `AuthModelAction` trace against real `Arvo.Modb.AuthStore`, `Arvo.Modb.Sessions`,
## `Arvo.Auth`, and `Arvo.Totp`, and verifies B+Tree + `Modb.Ledger` audit chain invariants.
fn replay_modb_auth_path(
  actions: List(Statechart.AuthModelAction),
  files: Files,
  db_path: Text,
  rng: SecureRandom,
  clock: Clock
) : Result(Text, Text)
  key = try Bytes.from_hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    .or_fail("bad key")
  kr = try Keyring.single("k1", key).map_error(fn(e) Keyring.to_text(e) end)
  cfg = Session.default_config(true)
  tcfg = Totp.default_config()
  pol = Auth.default_password_policy()
  rf = files.read_only

  var cur_email = "alice@acme.io"
  cur_pw = "correct-horse-battery"
  u = try AuthStore.create_user_with_password(
    files,
    db_path,
    rng,
    clock,
    cur_email,
    cur_pw,
    pol,
    Some("Alice"),
    true
  ).map_error(fn(e) "#{e}" end)
  totp_secret = Totp.generate_secret(rng)
  (_rcodes, rdigs) = Totp.generate_recovery_codes(rng, 4)
  _enr = try AuthStore.enroll_totp(files, db_path, rng, kr, clock, u.id, totp_secret, rdigs)
    .map_error(fn(e) "#{e}" end)

  (s0, ck0) = try Sessions.create(files, db_path, rng, clock, key, u.id, cfg).map_error(
    fn(e) "#{e}" end
  )
  (_ps, peer_cookie) = try Sessions.create(files, db_path, rng, clock, key, u.id, cfg).map_error(
    fn(e) "#{e}" end
  )

  var cur_id = s0.id
  var cur_cookie = ck0
  var last_totp_code = ""
  var reset_token = ""
  var last_phase = "registered"

  for act in actions
    case act
      Statechart.LoginPassword:
        if (
          try AuthStore.authenticate_password(files, db_path, clock, cur_email, cur_pw).map_error(
            fn(e) "#{e}" end
          )
        ) is
          None
          return Error("MODEL_DRIFT: LoginPassword rejected valid credentials")
        end
        (nid, nck) = try rotate_modb_no_fixation(
          files,
          db_path,
          rng,
          clock,
          key,
          cur_id,
          cur_cookie,
          u.id,
          cfg,
          "login"
        )
        cur_id = nid
        cur_cookie = nck
        last_phase = "mfa_pending"
      Statechart.VerifyTotp:
        code = Totp.code_at(totp_secret, clock.now, tcfg)
        vres = try AuthStore.verify_totp_for_user(files, db_path, kr, clock, u.id, code, tcfg)
          .map_error(fn(e) "#{e}" end)
        if not (vres is Totp.Accepted(matched_step: _))
          return Error("MODEL_DRIFT: valid TOTP code rejected")
        end
        last_totp_code = code
        (nid, nck) = try rotate_modb_no_fixation(
          files,
          db_path,
          rng,
          clock,
          key,
          cur_id,
          cur_cookie,
          u.id,
          cfg,
          "mfa"
        )
        cur_id = nid
        cur_cookie = nck
        last_phase = "authenticated"
      Statechart.ReplayTotpSameStep:
        if last_totp_code.empty?
          return Error("MODEL_DRIFT: ReplayTotpSameStep without prior VerifyTotp")
        end
        rres = try AuthStore.verify_totp_for_user(
          files,
          db_path,
          kr,
          clock,
          u.id,
          last_totp_code,
          tcfg
        ).map_error(fn(e) "#{e}" end)
        if not (rres is Totp.ReplayedStep(step: _))
          return Error("MODEL_DRIFT: TOTP code replay accepted within same step")
        end
        last_phase = "totp_replay_blocked"
      Statechart.StepUpSudo:
        if (
          try AuthStore.authenticate_password(files, db_path, clock, cur_email, cur_pw).map_error(
            fn(e) "#{e}" end
          )
        ) is
          None
          return Error("MODEL_DRIFT: StepUpSudo rejected valid credentials")
        end
        (nid, nck) = try rotate_modb_no_fixation(
          files,
          db_path,
          rng,
          clock,
          key,
          cur_id,
          cur_cookie,
          u.id,
          cfg,
          "sudo"
        )
        cur_id = nid
        cur_cookie = nck
        last_phase = "sudo_active"
      Statechart.ChangePassword:
        _rev = try AuthStore.change_password(
          files,
          db_path,
          rng,
          clock,
          u.id,
          "updated-strong-passphrase",
          pol
        ).map_error(fn(e) "#{e}" end)
        for ck in [cur_cookie, peer_cookie]
          still = try Sessions.load_read_only(
            Api.get("/").with_header("Cookie", "#{cfg.cookie_name}=#{ck}"),
            rf,
            db_path,
            clock,
            key,
            cfg
          ).map_error(fn(e) "#{e}" end)
          if still is Some(_)
            return Error("MODEL_DRIFT: session remained valid after password change")
          end
        end
        last_phase = "sessions_revoked"
      Statechart.IssueResetToken:
        issued = try AuthStore.issue_and_store_token(
          files,
          db_path,
          rng,
          clock,
          Some(u.id),
          Auth.PasswordReset,
          cur_email,
          900
        ).map_error(fn(e) "#{e}" end)
        reset_token = issued.raw_token
        last_phase = "token_issued"
      Statechart.ConsumeResetToken:
        if reset_token.empty?
          return Error("MODEL_DRIFT: ConsumeResetToken without prior IssueResetToken")
        end
        _ct = try AuthStore.consume_auth_token(
          files,
          db_path,
          clock,
          reset_token,
          Auth.PasswordReset,
          Some(cur_email)
        ).map_error(fn(e) "MODEL_DRIFT: ConsumeResetToken failed: #{e}" end)
        last_phase = "token_consumed"
      Statechart.ReplayResetToken:
        if reset_token.empty?
          return Error("MODEL_DRIFT: ReplayResetToken without prior IssueResetToken")
        end
        case AuthStore.consume_auth_token(
          files,
          db_path,
          clock,
          reset_token,
          Auth.PasswordReset,
          Some(cur_email)
        )
          Ok(_): return Error(
            "MODEL_DRIFT: replayed or stale reset token accepted by real AuthStore"
          )
          Error(AuthStore.InvalidOrExpiredToken): Unit
          Error(e): return Error("MODEL_DRIFT: unexpected reset replay error: #{e}")
        end
        last_phase = "token_replay_blocked"
      Statechart.ChangeEmail:
        try AuthStore.change_email(files, db_path, clock, u.id, "alice.new@acme.io", true).map_error(
          fn(e) "#{e}" end
        )
        cur_email = "alice.new@acme.io"
        last_phase = "email_changed"
      Statechart.AttemptUnverifiedOidcLink:
        existing = try AuthStore.find_user_by_email(rf, db_path, cur_email).map_error(
          fn(e) "#{e}" end
        )
        dec = Auth.resolve_oidc_link(
          Auth.OidcLinkConfig(signup_mode: Auth.OpenSignup, auto_link_verified_oidc?: true),
          None,
          existing,
          cur_email,
          false,
          false
        )
        if not (dec is Auth.AccountLinkRequiresLogin(user_id: _))
          return Error("MODEL_DRIFT: unverified OIDC login attempted automatic account takeover")
        end
        last_phase = "oidc_blocked"
    end
  end
  try verify_modb_invariants(rf, db_path, true)
  Ok(last_phase)
end

fn seed_note(files: Files, db_path: Text, rng: SecureRandom, clock: Clock, env: Env) : Result(
  Unit,
  Text
)
  tbl = Table.text_key[Text]("notes")
  tok = rng.bytes(4).to_hex
  lbl = env.get("SEED_LABEL") or "baseline"
  note_val = "#{lbl}@#{clock.now.to_text}:#{tok}"
  _db = try Modb.with_exclusive_lock(
    files,
    db_path,
    fn(e) e.to_text end,
    fn(s)
      Table.write_tx(s, fn(tx) Table.put(tx, tbl, "n1", note_val) end).map_error(
        fn(e) e.to_text end
      )
    end
  )
  Ok(Unit)
end

test "Modb.Testing verifies MoDB & Ledger invariants, runs deterministic seeds, and replays Statechart traces"
  t0 = Time.parse("2026-11-27T10:00:00Z") or stop "t0"

  # 1. Seed profiles
  profiles = [ModbSeedProfile(name: "baseline", description: "Seed note", apply: seed_note)]
  assert profile_names(profiles) == ["baseline"]
  assert find_profile(profiles, "baseline") is Some(_)
  f1 = Files.in_memory({})
  f2 = Files.in_memory({})
  env = Env.of({"SEED_LABEL": "demo"})
  assert run_seed_profile(
    profiles,
    "baseline",
    f1,
    "s.modb",
    SecureRandom.seeded(1),
    Clock.fixed(t0),
    env
  ) ==
    Ok(Unit)
  assert run_seed_profile(
    profiles,
    "baseline",
    f2,
    "s.modb",
    SecureRandom.seeded(1),
    Clock.fixed(t0),
    env
  ) ==
    Ok(Unit)
  assert run_seed_profile(
    profiles,
    "missing",
    f1,
    "s.modb",
    SecureRandom.seeded(1),
    Clock.fixed(t0),
    env
  ) ==
    Error("unknown modb seed profile 'missing' (available: baseline)")

  assert verify_modb_invariants(f1.read_only, "s.modb", false) == Ok(Unit)
  assert verify_modb_invariants(f1.read_only, "missing.modb", false) is Error(_)

  # Corrupt `_arvo_sessions` row fails invariant decoding
  _corrupt = Modb.with_exclusive_lock(
    f1,
    "corrupt.modb",
    fn(e) e.to_text end,
    fn(s)
      Modb.write_tx(s, fn(tx) Modb.tx_put(tx, "_arvo_sessions", "bad".bytes, "{broken".bytes) end)
        .map_error(fn(e) e.to_text end)
    end
  )
  assert verify_modb_invariants(f1.read_only, "corrupt.modb", false) is Error(_)

  # 2. Ledger verify_modb_invariants check
  notes = Table.text_key[Text]("notes")
  lschema = Ledger.schema(1)
  lf = Files.in_memory({})
  _ldb = Ledger.locked(
    lf,
    "ledger.modb",
    lschema,
    t0,
    fn(e) e.to_text end,
    fn(db)
      meta = Ledger.WriteMeta(principal: "test", action: "note.put", reason: "init", at: t0)
      (_ndb, _u) = try Ledger.transact(
        db,
        meta,
        "add note",
        Json.Null,
        fn(e) e.to_text end,
        fn(tx)
          tx1 = try Table.put(tx, notes, "k", "v").map_error(fn(e) e.to_text end)
          Ok((tx1, Unit))
        end
      )
      Ok(Unit)
    end
  )
  assert verify_modb_invariants(lf.read_only, "ledger.modb", true) == Ok(Unit)

  # 3. Formal Statechart replay against real Arvo.Modb.Jobs
  jf = Files.in_memory({})
  assert replay_modb_jobs_path(
    [Statechart.Claim, Statechart.Complete],
    jf,
    "j1.modb",
    SecureRandom.seeded(11),
    Clock.fixed(t0)
  ) is
    Ok(rj_ok)
  assert rj_ok.state == "completed" and rj_ok.attempts == 1
  assert replay_modb_jobs_path(
    [
      Statechart.Claim,
      Statechart.FailOrRetry,
      Statechart.TickWait,
      Statechart.Claim,
      Statechart.WorkerStalls,
      Statechart.RequeueStale,
      Statechart.Claim
    ],
    Files.in_memory({}),
    "j2.modb",
    SecureRandom.seeded(11),
    Clock.fixed(t0)
  ) ==
    Error("MODEL_DRIFT: Claim refused by real Arvo.Modb.Jobs.claim_next")
  assert replay_modb_jobs_path(
    [
      Statechart.Claim,
      Statechart.FailOrRetry,
      Statechart.TickWait,
      Statechart.Claim,
      Statechart.FailOrRetry
    ],
    Files.in_memory({}),
    "j3.modb",
    SecureRandom.seeded(11),
    Clock.fixed(t0)
  ) is
    Ok(rj_fail)
  assert rj_fail.state == "failed" and rj_fail.attempts == 2

  # 4. Formal Statechart replay against real Arvo.Modb.Sessions
  scfg = Session.default_config(true)
  assert replay_modb_session_path(
    [Statechart.CreateSession],
    scfg,
    Files.in_memory({}),
    "ms1.modb",
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Ok(true)
  assert replay_modb_session_path(
    [Statechart.CreateSession, Statechart.RotateSession, Statechart.RevokeSession],
    scfg,
    Files.in_memory({}),
    "ms2.modb",
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Ok(false)
  assert replay_modb_session_path(
    [Statechart.CreateSession, Statechart.ExpireTime, Statechart.PruneExpired],
    scfg,
    Files.in_memory({}),
    "ms3.modb",
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Ok(false)
  assert replay_modb_session_path(
    [Statechart.CreateSession, Statechart.RotateSession, Statechart.ReplayOldCookie],
    scfg,
    Files.in_memory({}),
    "ms4.modb",
    SecureRandom.seeded(22),
    Clock.fixed(t0)
  ) ==
    Error("MODEL_DRIFT: old rotated cookie rejected by real Arvo.Modb.Sessions.load_read_only")

  # 5. Formal Statechart replay against real Arvo.Modb.AuthStore + Modb.Sessions + Modb.Ledger
  assert replay_modb_auth_path(
    [Statechart.LoginPassword, Statechart.VerifyTotp, Statechart.ReplayTotpSameStep],
    Files.in_memory({}),
    "ma1.modb",
    SecureRandom.seeded(41),
    Clock.fixed(t0)
  ) ==
    Ok("totp_replay_blocked")
  assert replay_modb_auth_path(
    [
      Statechart.LoginPassword,
      Statechart.VerifyTotp,
      Statechart.StepUpSudo,
      Statechart.ChangePassword
    ],
    Files.in_memory({}),
    "ma2.modb",
    SecureRandom.seeded(42),
    Clock.fixed(t0)
  ) ==
    Ok("sessions_revoked")
  assert replay_modb_auth_path(
    [Statechart.IssueResetToken, Statechart.ConsumeResetToken, Statechart.ReplayResetToken],
    Files.in_memory({}),
    "ma3.modb",
    SecureRandom.seeded(43),
    Clock.fixed(t0)
  ) ==
    Ok("token_replay_blocked")
  assert replay_modb_auth_path(
    [Statechart.IssueResetToken, Statechart.ChangeEmail, Statechart.ReplayResetToken],
    Files.in_memory({}),
    "ma4.modb",
    SecureRandom.seeded(44),
    Clock.fixed(t0)
  ) ==
    Ok("token_replay_blocked")
  assert replay_modb_auth_path(
    [Statechart.AttemptUnverifiedOidcLink],
    Files.in_memory({}),
    "ma5.modb",
    SecureRandom.seeded(45),
    Clock.fixed(t0)
  ) ==
    Ok("oidc_blocked")
  assert replay_modb_auth_path(
    [Statechart.ReplayTotpSameStep],
    Files.in_memory({}),
    "ma6.modb",
    SecureRandom.seeded(46),
    Clock.fixed(t0)
  ) ==
    Error("MODEL_DRIFT: ReplayTotpSameStep without prior VerifyTotp")
end
