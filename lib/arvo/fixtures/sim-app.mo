## Test-only API fixture for `Arvo.Sim` modeling multi-actor optimistic-lock bill payments,
## background sync jobs, and session revocation with an injectable lock-bypass bug.
module Arvo.Fixtures.SimApp
expose SimMember(..),
SimPayIn(..),
SimErr(..),
bootstrap_world,
authenticate,
list_bills,
pay_bill,
enqueue_sync,
rotate_session,
sync_bill_job
use Api
use Arvo.Auth
use Arvo.Session
use Arvo.Sqlite.Audit
use Arvo.Sqlite.Jobs
use Arvo.Sqlite.Migrations
use Arvo.Sqlite.Sessions
use Json

struct SimMember
  id: Text
  email: Text
  session: Session.Session
end

struct SimPayIn
  expected_version: Int
end

enum SimErr
  SimUnauth
  SimForbidden
  SimNotFound
  SimConflict
  SimServer(reason: Text)
end

default_key_hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"

api
  sqlite db from "sim.sqlite"
  auth SimMember via authenticate
  get "/bills" list_bills
  post "/bills/:id/pay" pay_bill
  post "/jobs/enqueue" enqueue_sync
  post "/sessions/rotate" rotate_session
  job "sync.bill" sync_bill_job
  status SimUnauth = 401
  status SimForbidden = 403
  status SimNotFound = 404
  status SimConflict = 409
  status SimServer(_) = 500
end

fn secret_key() : Bytes
  Bytes.from_hex(default_key_hex) or "".bytes
end

fn session_cfg() : Session.SessionConfig
  Session.SessionConfig(cookie_name: "arvo_session", ttl_seconds: 3600, secure?: false)
end

fn migrations() : List(Migrations.Migration)
  sql = """
    CREATE TABLE IF NOT EXISTS sim_members (
      id TEXT PRIMARY KEY,
      email TEXT NOT NULL UNIQUE
    ) STRICT;
    #{Sessions.schema_sql()}
    #{Audit.schema_sql()}
    #{Jobs.schema_sql()}
    CREATE TABLE IF NOT EXISTS sim_bills (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'due' CHECK (status IN ('due', 'in_flight', 'paid')),
      version INTEGER NOT NULL DEFAULT 1
    ) STRICT;
    """
  [Migrations.Migration(version: 1, name: "init_sim", sql: sql)]
end

## Seeds migrations, two actors (`ada`, `grace`), one due bill, and returns their `Set-Cookie` tokens.
fn bootstrap_world(db: Sqlite.Database, rng: SecureRandom, clock: Clock) : Result(
  (Text, Text),
  Text
)
  _m = try Migrations.run(db, clock, migrations()).map_error(fn(e) "#{e}" end)
  _m1 = try db.execute(
    "INSERT OR IGNORE INTO sim_members (id, email) VALUES (?, ?)",
    [Sqlite.String("mem_ada"), Sqlite.String("ada@household.local")]
  ).map_error(fn(e) "#{e}" end)
  _m2 = try db.execute(
    "INSERT OR IGNORE INTO sim_members (id, email) VALUES (?, ?)",
    [Sqlite.String("mem_grace"), Sqlite.String("grace@household.local")]
  ).map_error(fn(e) "#{e}" end)
  _b = try db.execute(
    "INSERT OR IGNORE INTO sim_bills (id, name, status, version) VALUES (1, 'Rent', 'due', 1)",
    []
  ).map_error(fn(e) "#{e}" end)
  (s1, c1) = try Sessions.create(db, rng, clock, secret_key(), "mem_ada", session_cfg()).map_error(
    fn(e) "#{e}" end
  )
  (s2, c2) = try Sessions.create(db, rng, clock, secret_key(), "mem_grace", session_cfg()).map_error(
    fn(e) "#{e}" end
  )
  Ok(("#{c1}|#{s1.csrf_token}", "#{c2}|#{s2.csrf_token}"))
end

fn authenticate(req: Api.Request, db: Sqlite.Database, clock: Clock) : Result(SimMember, SimErr)
  maybe_sess = try Sessions.load(req, db, clock, secret_key(), session_cfg()).map_error(
    fn(e) SimServer(reason: "#{e}") end
  )
  sess = try maybe_sess.or_fail(SimUnauth)
  email = if sess.member_id == "mem_ada": "ada@household.local" else: "grace@household.local"
  Ok(SimMember(id: sess.member_id, email: email, session: sess))
end

fn list_bills(member: SimMember, db: Sqlite.Database, env: Env) : Result(Map(Text, Int), SimErr)
  _ = member
  return Error(SimServer(reason: "injected 500")) if env.get("BUG_500") == Some("1")
  rows = try db.query("SELECT id FROM sim_bills WHERE status = 'due'", []).map_error(
    fn(e) SimServer(reason: "#{e}") end
  )
  Ok({"due_count": rows.rows.size})
end

fn pay_bill(
  req: Api.Request,
  member: SimMember,
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  env: Env,
  id: Int,
  input: SimPayIn
) : Result(Map(Text, Int), SimErr)
  return Error(SimForbidden) if not Auth.require_csrf(req, member.session)
  upd = if env.get("BUG_SKIP_LOCK") == Some("1")
    try db.execute(
      "UPDATE sim_bills SET status = 'in_flight', version = version + 1 WHERE id = ?",
      [Sqlite.Integer(id)]
    ).map_error(fn(e) SimServer(reason: "#{e}") end)
  else
    try db.execute(
      "UPDATE sim_bills SET status = 'in_flight', version = version + 1 WHERE id = ? AND status = 'due' AND version = ?",
      [Sqlite.Integer(id), Sqlite.Integer(input.expected_version)]
    ).map_error(fn(e) SimServer(reason: "#{e}") end)
  end
  if upd.changes == 0
    return Error(SimConflict)
  end
  _ev = try Audit.record(
    db,
    rng,
    clock,
    member.email,
    "bill.mark_in_flight",
    "sim_bills",
    "#{id}",
    None,
    Some({"version": input.expected_version + 1}.to_json),
    None,
    None
  ).map_error(fn(e) SimServer(reason: "#{e}") end)
  Ok({"version": input.expected_version + 1})
end

fn enqueue_sync(
  req: Api.Request,
  member: SimMember,
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock
) : Result(Map(Text, Text), SimErr)
  return Error(SimForbidden) if not Auth.require_csrf(req, member.session)
  jid = try Jobs.enqueue(db, rng, clock, "sync.bill", Json.Object({"bill_id": Json.int(1)}))
    .map_error(fn(e) SimServer(reason: "#{e}") end)
  Ok({"job_id": jid})
end

fn sync_bill_job(payload: Json, db: Sqlite.Database) : Result(Unit, Text)
  _ = payload
  _q = try db.query("SELECT id FROM sim_bills LIMIT 1", []).map_error(fn(e) "#{e}" end)
  Ok(Unit)
end

fn rotate_session(
  req: Api.Request,
  member: SimMember,
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Api.Response, SimErr)
  return Error(SimForbidden) if not Auth.require_csrf(req, member.session)
  (next_sess, raw_cookie) = if env.get("BUG_NO_REVOKE") == Some("1")
    try Sessions.create(db, rng, clock, secret_key(), member.id, session_cfg()).map_error(
      fn(e) SimServer(reason: "#{e}") end
    )
  else
    try Sessions.rotate(db, rng, clock, secret_key(), member.session.id, member.id, session_cfg())
      .map_error(fn(e) SimServer(reason: "#{e}") end)
  end
  body = Json.Object({"csrf_token": Json.String(next_sess.csrf_token)}).to_text
  res = Api.response(200, [("Content-Type", "application/json")], body.bytes)
  Ok(Session.attach_cookie(res, raw_cookie, session_cfg()))
end
