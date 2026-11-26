## Configurable test-only API server fixture for `Arvo.SecurityMatrix` positive and negative audits.
module Arvo.Fixtures.SecurityApp
expose SecMember(..),
SecPayInput(..),
SecErr(..),
app_migrations,
bootstrap_db,
authenticate,
show_login,
post_login,
post_logout,
home,
create_item,
pay_item
use Api
use Arvo.Auth
use Arvo.Inertia
use Arvo.Migrations
use Arvo.Session
use Json

struct SecMember
  id: Text
  email: Text
  session: Session.Session
end

struct SecPayInput
  expected_version: Int
  note: Option(Text)
end

enum SecErr
  SecUnauth
  SecForbidden
  SecServer(reason: Text)
end

default_key_hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"

api
  sqlite db from "security.sqlite"
  auth SecMember via authenticate
  get "/login" show_login
  post "/login" post_login
  post "/logout" post_logout
  get "/" home
  post "/items" create_item
  post "/items/:id/pay" pay_item
  status SecUnauth = 401
  status SecForbidden = 403
  status SecServer(_) = 500
end

fn secret_key() : Bytes
  Bytes.from_hex(default_key_hex) or "".bytes
end

fn session_cfg() : Session.SessionConfig
  Session.SessionConfig(cookie_name: "arvo_session", ttl_seconds: 3600, secure?: false)
end

fn inertia_cfg() : Inertia.InertiaConfig
  Inertia.InertiaConfig(
    app_title: "SecTest",
    version: "sec_v1",
    vite_dev_url: None,
    entry_js: "/assets/app.js",
    entry_css: [],
    head_extra: ""
  )
end

fn app_migrations() : List(Migrations.Migration)
  sql = """
    CREATE TABLE IF NOT EXISTS sec_members (
      id TEXT PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL
    ) STRICT;
    #{Session.schema_sql()}
    CREATE TABLE IF NOT EXISTS sec_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      owner_id TEXT NOT NULL REFERENCES sec_members(id),
      title TEXT NOT NULL,
      version INTEGER NOT NULL DEFAULT 1
    ) STRICT;
    """
  [Migrations.Migration(version: 1, name: "init_sec", sql: sql)]
end

fn bootstrap_db(db: Sqlite.Database, clock: Clock) : Result(Unit, SecErr)
  _m = try Migrations.run(db, clock, app_migrations()).map_error(
    fn(e) SecServer(reason: "migration: #{e}") end
  )
  rows = try db.query("SELECT id FROM sec_members LIMIT 1", []).map_error(
    fn(e) SecServer(reason: "#{e}") end
  )
  if rows.rows.empty?
    _im = try db.execute(
      "INSERT INTO sec_members (id, email, created_at) VALUES (?, ?, ?)",
      [
        Sqlite.String("mem_ada"),
        Sqlite.String("ada@household.local"),
        Sqlite.String(clock.now.to_text)
      ]
    ).map_error(fn(e) SecServer(reason: "#{e}") end)
    _ii = try db.execute(
      "INSERT INTO sec_items (owner_id, title, version) VALUES (?, ?, 1)",
      [Sqlite.String("mem_ada"), Sqlite.String("Rent and Utilities")]
    ).map_error(fn(e) SecServer(reason: "#{e}") end)
  end
  Ok(Unit)
end

fn env_flag?(env: Env, name: Text) : Bool
  env.get(name) == Some("1")
end

fn authenticate(req: Api.Request, db: Sqlite.Database, clock: Clock) : Result(SecMember, SecErr)
  try bootstrap_db(db, clock)
  maybe_sess = try Session.load(req, db, clock, secret_key(), session_cfg()).map_error(
    fn(e) SecServer(reason: "#{e}") end
  )
  sess = try maybe_sess.or_fail(SecUnauth)
  Ok(SecMember(id: sess.member_id, email: "ada@household.local", session: sess))
end

fn show_login(req: Api.Request, viewer: Option(SecMember), env: Env) : Api.Response
  if viewer is Some(_)
    return Inertia.redirect("/")
  end
  if not env_flag?(env, "BUG_STALE_VER")
    if Inertia.check_version(req, inertia_cfg()) is Some(conflict)
      return conflict
    end
  end
  Inertia.render(req, inertia_cfg(), "Login", {"hint": Json.String("Sign in")}, {})
end

fn post_login(db: Sqlite.Database, rng: SecureRandom, clock: Clock) : Result(Api.Response, SecErr)
  try bootstrap_db(db, clock)
  (sess, cval) = try Session.create(db, rng, clock, secret_key(), "mem_ada", session_cfg())
    .map_error(fn(e) SecServer(reason: "#{e}") end)
  Ok(Auth.login_response(Inertia.redirect("/"), sess, cval, session_cfg()))
end

fn post_logout(req: Api.Request, member: SecMember, db: Sqlite.Database, env: Env) : Result(
  Api.Response,
  SecErr
)
  if not env_flag?(env, "BUG_NO_CSRF")
    return Error(SecForbidden) if not Auth.require_csrf(req, member.session)
  end
  if not env_flag?(env, "BUG_NO_REVOKE")
    _rev = try Session.revoke(db, member.session.id).map_error(fn(e) SecServer(reason: "#{e}") end)
  end
  Ok(Auth.logout_response(Inertia.redirect("/login"), session_cfg()))
end

fn home(req: Api.Request, viewer: Option(SecMember), db: Sqlite.Database, env: Env) : Result(
  Api.Response,
  SecErr
)
  if not env_flag?(env, "BUG_NO_AUTH")
    case viewer
      Some(_): Unit
      None: return Ok(Inertia.redirect("/login"))
    end
  end
  if not env_flag?(env, "BUG_STALE_VER")
    if Inertia.check_version(req, inertia_cfg()) is Some(conflict)
      return Ok(conflict)
    end
  end
  if env_flag?(env, "BUG_N_PLUS_ONE")
    var i = 0
    while i < 12
      _extra = try db.query("SELECT id FROM sec_items", []).map_error(
        fn(e) SecServer(reason: "#{e}") end
      )
      i += 1
    end
  else
    _single = try db.query("SELECT id, title, version FROM sec_items", []).map_error(
      fn(e) SecServer(reason: "#{e}") end
    )
  end
  if env_flag?(env, "BUG_HOME_500")
    return Error(SecServer(reason: "injected home failure"))
  end
  if env_flag?(env, "BUG_XSS")
    raw_json = "{\"component\":\"Home\",\"props\":{\"title\":\"<script>alert(1)</script>\"},\"url\":\"/\",\"version\":\"sec_v1\"}"
    return Ok(
      Api.html_response(
        200,
        "<!doctype html><html><body><div id=\"app\" data-page=\"#{raw_json}\"></div></body></html>"
      )
    )
  end
  if env_flag?(env, "BUG_XSS_REFLECT")
    q_xss = req.query_param("_arvo_xss") or ""
    return Ok(
      Api.html_response(
        200,
        "<!doctype html><html><body><div id=\"app\" data-page=\"{&quot;component&quot;:&quot;Home&quot;,&quot;props&quot;:{},&quot;url&quot;:&quot;/&quot;,&quot;version&quot;:&quot;sec_v1&quot;}\"></div><div>#{q_xss}</div></body></html>"
      )
    )
  end
  if env_flag?(env, "BUG_XSS_PLAIN")
    plain_json = "{\"component\":\"Home\",\"props\":{\"title\":\"Household Budget\"},\"url\":\"/\",\"version\":\"sec_v1\"}"
    return Ok(
      Api.html_response(
        200,
        "<!doctype html><html><body><div id=\"app\" data-page=\"#{plain_json}\"></div></body></html>"
      )
    )
  end
  Ok(Inertia.render(req, inertia_cfg(), "Home", {"title": Json.String("Household Budget")}, {}))
end

fn create_item(req: Api.Request, member: SecMember, rng: SecureRandom, env: Env) : Result(
  Api.Response,
  SecErr
)
  if not env_flag?(env, "BUG_NO_CSRF")
    return Error(SecForbidden) if not Auth.require_csrf(req, member.session)
  end
  if env_flag?(env, "BUG_OPEN_REDIRECT")
    unsafe_ref = req.header("Referer") or "/"
    return Ok(Api.redirect_see_other(unsafe_ref))
  end
  _ = member
  Ok(Inertia.validation_error(req, rng, secret_key(), "/", {}, false))
end

fn pay_item(req: Api.Request, member: SecMember, id: Int, body: SecPayInput, env: Env) : Result(
  Map(Text, Int),
  SecErr
)
  if not env_flag?(env, "BUG_NO_CSRF")
    return Error(SecForbidden) if not Auth.require_csrf(req, member.session)
  end
  if env_flag?(env, "BUG_NO_STRICT_JSON")
    return Ok({"id": id, "version": body.expected_version + 1})
  end
  Ok({"id": id, "version": body.expected_version + 1})
end
