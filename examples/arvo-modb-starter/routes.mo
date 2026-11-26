## Route handlers, MoDB Ledger schema, invariants, jobs, and ReadFiles-only auth for the MoDB + Inertia v2 starter.
module Routes
expose Member(..),
Bill(..),
PayInput(..),
AppError(..),
sessions_db_path,
ledger_db_path,
starter_schema,
authenticate,
show_login,
post_login,
post_logout,
home,
create_bill,
pay_bill,
import_csv,
drain_jobs
use Api
use Arvo.Auth
use Arvo.Changeset
use Arvo.Flash
use Arvo.Form
use Arvo.Inertia
use Arvo.Modb.Jobs
use Arvo.Modb.Sessions
use Arvo.Session
use Json
use Modb.Errors
use Modb.Ledger
use Modb.Table

sessions_db_path = "sessions.modb"
ledger_db_path = "starter.modb"

## Authenticated household member + active MoDB-backed session.
struct Member
  id: Text
  email: Text
  display_name: Text
  session: Session.Session
end

struct MemberRow
  id: Text
  email: Text
  password_hash: Text
  display_name: Text
end

## One bill row in the starter ledger, carrying an optimistic concurrency `version`.
struct Bill
  id: Int
  name: Text
  category: Text
  amount_cents: Int
  status: Text
  version: Int
end

struct NewBillDraft
  name: Text
  category: Text
  amount_cents: Int
end

## JSON payload for marking a bill `in_flight` with an optimistic concurrency check.
struct PayInput
  expected_version: Int
  reason: Option(Text)
end

## Audit item serialized into the exact shape expected by `frontend/src/pages/Home.tsx`.
struct AuditFeedItem
  id: Text
  actor_name: Text
  action: Text
  entity_table: Text
  entity_id: Text
  created_at: Time
end

## Domain errors mapped to HTTP status codes in `Main`'s `api` block.
enum AppError
  Unauthenticated
  Forbidden
  BillNotFound(id: Int)
  VersionConflict(id: Int)
  BadUpload(reason: Text)
  ServerFailed(reason: Text)
end

default_dev_key_hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"

fn members_by_email() : Table.Index(Text, MemberRow, Text)
  Table.unique_text_index[Text, MemberRow]("members_by_email", fn(m) m.email end)
end

fn members_table() : Table.Table(Text, MemberRow)
  Table.text_key[MemberRow]("members").with_index(members_by_email())
end

fn bills_table() : Table.Table(Int, Bill)
  Table.int_key[Bill]("bills")
end

fn counters_table() : Table.Table(Text, Int)
  Table.text_key[Int]("counters")
end

## Declarative `Modb.Ledger` schema (v1 migration + positive bill amounts invariant).
fn starter_schema() : Ledger.Schema
  bills = bills_table()
  counters = counters_table()
  Ledger.schema(1).with_require_reason(false).with_migration(
    Ledger.migration(
      1,
      "initialize bill sequence",
      fn(tx) Table.put(tx, counters, "next_bill_id", 1) end
    )
  ).with_invariant(
    Ledger.row_invariant(
      "bill_amount_positive",
      bills,
      fn(id, b) if b.amount_cents <= 0: Some("bill ##{id} must have amount_cents > 0") else: None end
    )
  )
end

fn map_table_error(err: Table.TableError) : AppError
  ServerFailed(reason: err.to_text)
end

fn map_ledger_error(err: Ledger.LedgerError) : AppError
  ServerFailed(reason: err.to_text)
end

fn not_found_ledger?(err: Ledger.LedgerError) : Bool
  err is Ledger.TableFailure(Table.Storage(Errors.Io(NotFound(path: _))))
end

fn app_secret_key(env: Env) : Result(Bytes, AppError)
  hex = env.get("ARVO_SECRET_KEY") or default_dev_key_hex
  case Bytes.from_hex(hex)
    Some(k):
      if k.size == 32
        Ok(k)
      else
        Error(ServerFailed(reason: "ARVO_SECRET_KEY must decode to 32 bytes"))
      end
    None: Error(ServerFailed(reason: "ARVO_SECRET_KEY must be 64 hex characters"))
  end
end

fn allowed_emails(env: Env) : List(Text)
  raw = env.get("ARVO_ALLOWLIST") or "ada@household.local,grace@household.local"
  raw.split(",").map(fn(s) s.trim end).filter(fn(s) not s.empty? end)
end

fn secure_cookies?(env: Env) : Bool
  (env.get("ARVO_INSECURE_COOKIES") or "0") != "1"
end

fn session_cfg(env: Env) : Session.SessionConfig
  Session.SessionConfig(
    cookie_name: "arvo_session",
    ttl_seconds: 1209600,
    secure?: secure_cookies?(env)
  )
end

fn bootstrap_db(files: Files, rng: SecureRandom, clock: Clock, env: Env) : Result(Unit, AppError)
  members = members_table()
  if files.read_only.exists?(ledger_db_path)
    already_seeded? = try Ledger.read_locked(
      files.read_only,
      ledger_db_path,
      starter_schema(),
      map_ledger_error,
      fn(db)
        m = try Table.get(Ledger.store(db), members, "mem_ada").map_error(map_table_error)
        Ok(m != None)
      end
    )
    return Ok(Unit) if already_seeded?
  end

  seed_pw = env.get("ARVO_SEED_PASSWORD") or "correct-horse-battery-staple"
  pw_hash = try Auth.hash_password(rng, seed_pw).map_error(
    fn(e) ServerFailed(reason: "password hash failed: #{e}") end
  )
  now = clock.now
  bills = bills_table()
  counters = counters_table()

  Ledger.locked(
    files,
    ledger_db_path,
    starter_schema(),
    now,
    map_ledger_error,
    fn(db)
      existing = try Table.get(Ledger.store(db), members, "mem_ada").map_error(map_table_error)
      return Ok(Unit) if existing != None
      meta = Ledger.WriteMeta(
        principal: "system:bootstrap",
        action: "seed.bootstrap",
        reason: "seed initial household member and bill",
        at: now
      )
      seed_payload = Json.Object({
        "entity_table": Json.String("members"),
        "entity_id": Json.String("mem_ada")
      })
      (_next_db, _u) = try Ledger.transact(
        db,
        meta,
        "seed initial member and bill",
        seed_payload,
        map_ledger_error,
        fn(tx)
          mrow = MemberRow(
            id: "mem_ada",
            email: "ada@household.local",
            password_hash: pw_hash,
            display_name: "Ada & Household <Team>"
          )
          bill1 = Bill(
            id: 1,
            name: "Electric & Gas <Utility>",
            category: "utilities",
            amount_cents: 14500,
            status: "due",
            version: 1
          )
          tx1 = try Table.put(tx, members, mrow.id, mrow).map_error(map_table_error)
          tx2 = try Table.put(tx1, bills, bill1.id, bill1).map_error(map_table_error)
          tx3 = try Table.put(tx2, counters, "next_bill_id", 2).map_error(map_table_error)
          Ok((tx3, Unit))
        end
      )
      Ok(Unit)
    end
  )
end

fn load_inertia_config(files: ReadFiles, env: Env) : Result(Inertia.InertiaConfig, AppError)
  title = "Arvo MoDB Starter"
  head = "<meta name=\"theme-color\" content=\"#0f172a\">"
  if env.get("VITE_DEV_URL") is Some(dev_url)
    if not dev_url.trim.empty?
      return Ok(Inertia.dev_config(title, dev_url.trim, "src/main.tsx", head))
    end
  end
  case files.read_bytes("public/manifest.json")
    Ok(manifest_bytes): Inertia.config_from_manifest(title, manifest_bytes, "src/main.tsx", head)
      .map_error(fn(reason) ServerFailed(reason: reason) end)
    Error(_): Ok(Inertia.dev_config(title, "http://127.0.0.1:5173", "src/main.tsx", head))
  end
end

fn shared_props(viewer: Option(Member), flash: Flash.FlashData) : Map(Text, Json)
  var base = {
    "errors": Changeset.inertia_error_map_json(flash.errors),
    "flash": Json.Object({"notice": flash.notice.to_json, "alert": flash.alert.to_json})
  }
  case viewer
    Some(m): base = base.set(
      "auth",
      Json.Object({
        "id": Json.String(m.id),
        "email": Json.String(m.email),
        "display_name": Json.String(m.display_name)
      })
    )
    None: base = base.set("auth", Json.Null)
  end
  base
end

## Authenticates the encrypted `arvo_session` cookie using ONLY `ReadFiles` (lock-free MoDB snapshot reads).
fn authenticate(req: Api.Request, rf: ReadFiles, clock: Clock, env: Env) : Result(Member, AppError)
  key = try app_secret_key(env)
  maybe_sess = try Sessions.load_read_only(req, rf, sessions_db_path, clock, key, session_cfg(env))
    .map_error(fn(e) ServerFailed(reason: "session load failed: #{e}") end)
  sess = try maybe_sess.or_fail(Unauthenticated)
  return Error(Unauthenticated) if not rf.exists?(ledger_db_path)

  members = members_table()
  read_res = Ledger.read_locked(
    rf,
    ledger_db_path,
    starter_schema(),
    fn(le) le end,
    fn(db)
      Table.get(Ledger.store(db), members, sess.member_id).map_error(
        fn(te) Ledger.TableFailure(te) end
      )
    end
  )
  maybe_member = case read_res
    Ok(v): v
    Error(le):
      if not_found_ledger?(le)
        return Error(Unauthenticated)
      end
      return Error(map_ledger_error(le))
  end
  mrow = try maybe_member.or_fail(Unauthenticated)
  Ok(Member(id: mrow.id, email: mrow.email, display_name: mrow.display_name, session: sess))
end

## Renders the Inertia `Login` page for guests, or redirects authenticated members to `/`.
fn show_login(req: Api.Request, viewer: Option(Member), files: ReadFiles, env: Env) : Result(
  Api.Response,
  AppError
)
  if viewer is Some(_)
    return Ok(Inertia.redirect("/"))
  end
  cfg = try load_inertia_config(files, env)
  if Inertia.check_version(req, cfg) is Some(conflict)
    return Ok(conflict)
  end
  key = try app_secret_key(env)
  (flash, had_flash?) = Flash.take(req, key)
  res = Inertia.render(
    req,
    cfg,
    "Login",
    {"allowlist_hint": Json.String("Household members only")},
    shared_props(None, flash)
  )
  Ok(Flash.clear_if_present(res, had_flash?, secure_cookies?(env)))
end

## Verifies allowlisted email + scrypt password, issues encrypted MoDB session + CSRF cookies, and redirects `303`.
fn post_login(req: Api.Request, files: Files, rng: SecureRandom, clock: Clock, env: Env) : Result(
  Api.Response,
  AppError
)
  try bootstrap_db(files, rng, clock, env)
  key = try app_secret_key(env)
  sec? = secure_cookies?(env)
  fields = try Form.parse_urlencoded(req).map_error(
    fn(e) BadUpload(reason: "invalid login form: #{e}") end
  )
  email = Auth.normalize_email(Form.field(fields, "email") or "")
  password = Form.field(fields, "password") or ""

  if not Auth.email_allowed?(email, allowed_emails(env))
    return Ok(
      Inertia.validation_error(
        req,
        rng,
        key,
        "/login",
        {"email": ["email is not on the household allowlist"]},
        sec?
      )
    )
  end

  members = members_table()
  email_idx = members_by_email()
  maybe_pair = try Ledger.read_locked(
    files.read_only,
    ledger_db_path,
    starter_schema(),
    map_ledger_error,
    fn(db)
      Table.lookup_unique(Ledger.store(db), members, email_idx, email).map_error(map_table_error)
    end
  )
  mrow = case maybe_pair
    Some(p): p.1
    None: return Ok(
      Inertia.validation_error(
        req,
        rng,
        key,
        "/login",
        {"email": ["invalid email or password"]},
        sec?
      )
    )
  end

  if not Auth.verify_password(password, mrow.password_hash)
    return Ok(
      Inertia.validation_error(
        req,
        rng,
        key,
        "/login",
        {"password": ["invalid email or password"]},
        sec?
      )
    )
  end

  scfg = session_cfg(env)
  (sess, cookie_val) = try Sessions.create(files, sessions_db_path, rng, clock, key, mrow.id, scfg)
    .map_error(fn(e) ServerFailed(reason: "session create failed: #{e}") end)

  meta = Ledger.WriteMeta(
    principal: mrow.email,
    action: "auth.login",
    reason: "interactive sign in",
    at: clock.now
  )
  login_payload = Json.Object({
    "entity_table": Json.String("members"),
    "entity_id": Json.String(mrow.id),
    "session_id": Json.String(sess.id)
  })
  _u = try Ledger.transact_locked(
    files,
    ledger_db_path,
    starter_schema(),
    meta,
    "signed in #{mrow.email}",
    login_payload,
    map_ledger_error,
    fn(tx) Ok((tx, Unit)) end
  )

  redir = Flash.attach(Inertia.redirect("/"), rng, key, Flash.with_notice("Signed in"), sec?)
  Ok(Auth.login_response(redir, sess, cookie_val, scfg))
end

## Enforces CSRF, revokes the active MoDB session, clears both cookies, and redirects to `/login`.
fn post_logout(req: Api.Request, member: Member, files: Files, env: Env) : Result(
  Api.Response,
  AppError
)
  return Error(Forbidden) if not Auth.require_csrf(req, member.session)
  _rev = try Sessions.revoke(files, sessions_db_path, member.session.id).map_error(map_table_error)
  Ok(Auth.logout_response(Inertia.redirect("/login"), session_cfg(env)))
end

fn to_audit_item(ev: Ledger.AuditEntry) : AuditFeedItem
  entity_table = ev.payload.text_at("entity_table") or "system"
  entity_id = ev.payload.text_at("entity_id") or "#{ev.seq}"
  AuditFeedItem(
    id: "#{ev.seq}",
    actor_name: ev.principal,
    action: ev.action,
    entity_table: entity_table,
    entity_id: entity_id,
    created_at: ev.at
  )
end

## Renders the household `Home` Inertia dashboard using strictly `ReadFiles` (or redirects guests to `/login`).
fn home(req: Api.Request, viewer: Option(Member), rf: ReadFiles, env: Env, status: Option(Text)) : Result(
  Api.Response,
  AppError
)
  member = case viewer
    Some(m): m
    None: return Ok(Inertia.redirect("/login"))
  end

  cfg = try load_inertia_config(rf, env)
  if Inertia.check_version(req, cfg) is Some(conflict)
    return Ok(conflict)
  end

  bills_tbl = bills_table()
  (bills, audit_feed) = try Ledger.read_locked(
    rf,
    ledger_db_path,
    starter_schema(),
    map_ledger_error,
    fn(db)
      all_rows = try Table.all(Ledger.store(db), bills_tbl).map_error(map_table_error)
      all_bills = all_rows.map(fn(p) p.1 end)
      filtered_bills = case status
        Some(st): all_bills.filter(fn(b) b.status == st end)
        None: all_bills
      end
      entries = try Ledger.audit_tail(db, 20).map_error(map_ledger_error)
      feed = entries.reverse.map(to_audit_item)
      Ok((filtered_bills, feed))
    end
  )

  key = try app_secret_key(env)
  (flash, had_flash?) = Flash.take(req, key)
  total_due_cents = bills.filter(fn(b) b.status == "due" end).map(fn(b) b.amount_cents end).sum

  res = Inertia.render(
    req,
    cfg,
    "Home",
    {
      "bills": bills.to_json,
      "total_due_cents": Json.int(total_due_cents),
      "audit_feed": audit_feed.to_json
    },
    shared_props(Some(member), flash)
  )
  Ok(Flash.clear_if_present(res, had_flash?, secure_cookies?(env)))
end

## Validates a new bill via `Arvo.Changeset`, persisting on valid input or flashing errors across `303`.
fn create_bill(
  req: Api.Request,
  member: Member,
  files: Files,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Api.Response, AppError)
  return Error(Forbidden) if not Auth.require_csrf(req, member.session)
  fields = try Form.parse_urlencoded(req).map_error(
    fn(e) BadUpload(reason: "invalid bill form: #{e}") end
  )
  name = (Form.field(fields, "name") or "").trim
  category = (Form.field(fields, "category") or "").trim
  raw_amount = (Form.field(fields, "amount_cents") or "").trim
  amount_cents = raw_amount.to_int or -1

  draft = NewBillDraft(name: name, category: category, amount_cents: amount_cents)
  cs = Changeset.new(draft).require_non_empty("name", draft.name).require_length(
    "name",
    draft.name,
    2,
    80
  ).require_one_of("category", draft.category, ["utilities", "housing", "groceries", "card"])
    .require_positive_int("amount_cents", draft.amount_cents)

  key = try app_secret_key(env)
  sec? = secure_cookies?(env)
  validated = case Changeset.finish(cs)
    Ok(v): v
    Error(errs): return Ok(Inertia.validation_error(req, rng, key, "/", errs, sec?))
  end

  bills = bills_table()
  counters = counters_table()
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: member.email,
    action: "bill.create",
    reason: "create bill #{validated.name}",
    at: now
  )

  created = try Ledger.locked(
    files,
    ledger_db_path,
    starter_schema(),
    now,
    map_ledger_error,
    fn(db)
      next_id = (
        try Table.get(Ledger.store(db), counters, "next_bill_id").map_error(map_table_error)
      ) or
        1
      bill = Bill(
        id: next_id,
        name: validated.name,
        category: validated.category,
        amount_cents: validated.amount_cents,
        status: "due",
        version: 1
      )
      payload = Json.Object({
        "entity_table": Json.String("bills"),
        "entity_id": Json.String("#{bill.id}"),
        "bill": bill.to_json
      })
      (_next_db, out) = try Ledger.transact(
        db,
        meta,
        "create bill ##{bill.id} (#{bill.name})",
        payload,
        map_ledger_error,
        fn(tx)
          tx1 = try Table.put(tx, bills, bill.id, bill).map_error(map_table_error)
          tx2 = try Table.put(tx1, counters, "next_bill_id", next_id + 1).map_error(map_table_error)
          Ok((tx2, bill))
        end
      )
      Ok(out)
    end
  )
  _created = created

  Ok(Flash.attach(Inertia.redirect("/"), rng, key, Flash.with_notice("Bill added"), sec?))
end

## Marks a bill `in_flight` ("I just paid this") with optimistic concurrency + `Modb.Ledger` audit chain.
fn pay_bill(req: Api.Request, member: Member, files: Files, clock: Clock, id: Int, input: PayInput) : Result(
  Bill,
  AppError
)
  return Error(Forbidden) if not Auth.require_csrf(req, member.session)
  bills = bills_table()
  now = clock.now
  reason_txt = input.reason or "mark bill in_flight"
  meta = Ledger.WriteMeta(
    principal: member.email,
    action: "bill.mark_in_flight",
    reason: reason_txt,
    at: now
  )

  Ledger.locked(
    files,
    ledger_db_path,
    starter_schema(),
    now,
    map_ledger_error,
    fn(db)
      existing = try Table.get(Ledger.store(db), bills, id).map_error(map_table_error)
      before_bill = try existing.or_fail(BillNotFound(id: id))
      if before_bill.version != input.expected_version
        return Error(VersionConflict(id: id))
      end
      after_bill = Bill(
        id: before_bill.id,
        name: before_bill.name,
        category: before_bill.category,
        amount_cents: before_bill.amount_cents,
        status: "in_flight",
        version: before_bill.version + 1
      )
      payload = Json.Object({
        "entity_table": Json.String("bills"),
        "entity_id": Json.String("#{id}"),
        "before": before_bill.to_json,
        "after": after_bill.to_json
      })
      (_next_db, out) = try Ledger.transact(
        db,
        meta,
        "mark bill ##{id} in_flight",
        payload,
        map_ledger_error,
        fn(tx)
          tx1 = try Table.put(tx, bills, id, after_bill).map_error(map_table_error)
          Ok((tx1, after_bill))
        end
      )
      Ok(out)
    end
  )
end

## Parses a multipart CSV upload (`name,category,amount_cents` rows), inserts bills atomically,
## and enqueues an `import.notify` MoDB job inside the exact same `Modb.Ledger` transaction.
fn import_csv(req: Api.Request, member: Member, files: Files, rng: SecureRandom, clock: Clock) : Result(
  Map(Text, Int),
  AppError
)
  return Error(Forbidden) if not Auth.require_csrf(req, member.session)
  mp = try Form.parse_multipart(req, 65536).map_error(
    fn(e) BadUpload(reason: "multipart error: #{e}") end
  )
  upload = try Form.file(mp, "statement").or_fail(BadUpload(reason: "missing 'statement' file"))
  csv_text = try upload.data.decode_utf8.or_fail(BadUpload(reason: "CSV is not valid UTF-8"))
  default_cat = Form.field(mp.fields, "default_category") or "utilities"

  var parsed_bills = []
  for (idx, raw_line) in csv_text.lines.enumerate
    line = raw_line.trim
    continue if line.empty?
    continue if idx == 0 and line.ascii_lowercase.starts_with?("name,")
    cols = line.split(",")
    if cols.size < 3
      return Error(BadUpload(reason: "expected 3 CSV columns at line #{idx + 1}"))
    end
    bname = (cols.get(0) or "").trim
    bcat_raw = (cols.get(1) or "").trim
    bcat = if bcat_raw.empty?: default_cat else: bcat_raw
    cents = try (cols.get(2) or "").trim.to_int.or_fail(
      BadUpload(reason: "invalid amount_cents at line #{idx + 1}")
    )
    if bname.empty? or cents <= 0
      return Error(BadUpload(reason: "invalid bill row at line #{idx + 1}"))
    end
    parsed_bills = parsed_bills.append(
      NewBillDraft(name: bname, category: bcat, amount_cents: cents)
    )
  end

  bills = bills_table()
  counters = counters_table()
  now = clock.now
  meta = Ledger.WriteMeta(
    principal: member.email,
    action: "bills.csv_import",
    reason: "Multipart CSV upload",
    at: now
  )
  payload = Json.Object({
    "entity_table": Json.String("bills"),
    "entity_id": Json.String(upload.filename),
    "filename": Json.String(upload.filename),
    "imported": Json.int(parsed_bills.size)
  })
  job_payload = Json.Object({
    "filename": Json.String(upload.filename),
    "imported": Json.int(parsed_bills.size)
  })
  job_rec = Jobs.prepare(rng, clock, "import.notify", job_payload)

  try Ledger.transact_locked(
    files,
    ledger_db_path,
    starter_schema(),
    meta,
    "imported #{parsed_bills.size} bills from #{upload.filename}",
    payload,
    map_ledger_error,
    fn(tx)
      var next_id = (try Table.tx_get(tx, counters, "next_bill_id").map_error(map_table_error)) or 1
      var cur_tx = tx
      for draft in parsed_bills
        bill = Bill(
          id: next_id,
          name: draft.name,
          category: draft.category,
          amount_cents: draft.amount_cents,
          status: "due",
          version: 1
        )
        cur_tx = try Table.put(cur_tx, bills, next_id, bill).map_error(map_table_error)
        next_id += 1
      end
      cur_tx = try Table.put(cur_tx, counters, "next_bill_id", next_id).map_error(map_table_error)
      (final_tx, _job_id) = try Jobs.tx_put(cur_tx, job_rec).map_error(map_table_error)
      Ok((final_tx, Unit))
    end
  )

  Ok({"imported": parsed_bills.size})
end

## Periodic `mo serve` job handler draining MoDB-queued `import.notify` jobs and pruning expired sessions.
fn drain_jobs(_payload: Json, files: Files, clock: Clock) : Result(Unit, AppError)
  _pruned = try Sessions.prune_expired(files, sessions_db_path, clock).map_error(map_table_error)
  var keep_going = true
  while keep_going
    claimed = try Jobs.claim_next(files, ledger_db_path, clock, ["import.notify"]).map_error(
      map_table_error
    )
    case claimed
      None: keep_going = false
      Some(job): try Jobs.complete(files, ledger_db_path, clock, job.id).map_error(map_table_error)
    end
  end
  Ok(Unit)
end
