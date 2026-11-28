## `arvo new` full-stack project scaffolder generating compile- and test-ready Arvo apps
## backed by MoDB v0.9.0 (default) or SQLite, with native Auth (`full`/`allowlist`/`none`),
## optional Organizations (`--orgs`), MCP (`--mcp`), Live SSE, Dev Dashboard, React 19 + Inertia v2,
## Executable Feature Maps, and byte-exact `arvo.gen.ts` TypeScript contracts.
module NewCmd
expose NewArgs(..),
new_usage,
valid_app_name?,
parse_new_args,
build_contracts,
plan_app_files,
run_new
use Arvo.Inertia
use Codegen

## Parsed CLI options for `arvo new`.
struct NewArgs
  app_name: Text
  db: Text
  auth: Text
  orgs?: Bool
  mcp?: Bool
  dir: Option(Text)
  arvo_path: Text
  modb_path: Text
  force?: Bool
  help?: Bool
end

struct ScaffoldAuthUser
  id: Text
  email: Text
  display_name: Text
end

struct ScaffoldFlashProps
  notice: Option(Text)
  alert: Option(Text)
end

struct ScaffoldSharedProps
  auth: Option(ScaffoldAuthUser)
  flash: ScaffoldFlashProps
  errors: Map(Text, Text)
end

struct ScaffoldHomeProps
  app_name: Text
  db_engine: Text
  auth_mode: Text
  active_org: Option(Text)
  orgs: List(Text)
end

struct ScaffoldLoginProps
  auth_mode: Text
  hint: Text
end

struct ScaffoldRegisterProps
  hint: Text
end

## Usage text for `arvo new`.
fn new_usage() : Text
  """
    usage: arvo new <app-name> [--db modb|sqlite] [--auth full|allowlist|none] [--orgs] [--mcp] [flags]

    Scaffolds a complete, test-ready full-stack Arvo + Inertia v2 + React 19 application
    with native Auth, Live SSE, Dev Dashboard (/__arvo), Feature Maps, and TypeScript contracts.

    Flags:
      --db modb|sqlite          Database backend (default: modb)
      --auth full|allowlist|none Native auth preset (default: full)
      --orgs                    Include multi-tenant workspace / organization creation
      --mcp                     Include Arvo.Action + POST /mcp JSON-RPC endpoint
      --dir PATH                Target directory (default: <app-name>)
      --arvo-path PATH          Path to Arvo repo in mo.toml (default: ../arvo)
      --modb-path PATH          Path to MoDB repo in mo.toml (default: ../modb)
      --force                   Overwrite existing scaffolded files
      -h, --help                Show this help
    """
end

fn ascii_lower?(ch: Char) : Bool
  c = ch.code
  c >= 97 and c <= 122
end

## Validates `<app-name>` (`^[a-z][a-z0-9_-]{0,63}$`).
fn valid_app_name?(raw: Text) : Bool
  examples
    valid_app_name?("my-app")
    valid_app_name?("demo_modb2")
    not valid_app_name?("")
    not valid_app_name?("../escape")
    not valid_app_name?("MyApp")
    not valid_app_name?("9lives")
  end

  return false if raw.empty? or raw.byte_count > 64
  first = raw.chars.first or ' '
  return false if not ascii_lower?(first)
  raw.chars.all?(fn(c) ascii_lower?(c) or c.ascii_digit? or c == '-' or c == '_' end)
end

fn need_val(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("`#{flag}` requires a value. Run `arvo new --help`.")
  else
    Ok(v)
  end
end

## Parses arguments after `arvo new`.
fn parse_new_args(rest: List(Text)) : Result(NewArgs, Text)
  var app_name = ""
  var seen_name? = false
  var db = "modb"
  var auth = "full"
  var orgs? = false
  var mcp? = false
  var dir = None
  var arvo_path = "../arvo"
  var modb_path = "../modb"
  var force? = false

  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(
        NewArgs(
          app_name: app_name,
          db: db,
          auth: auth,
          orgs?: orgs?,
          mcp?: mcp?,
          dir: dir,
          arvo_path: arvo_path,
          modb_path: modb_path,
          force?: force?,
          help?: true
        )
      )
    else if a == "--orgs"
      orgs? = true
    else if a == "--mcp"
      mcp? = true
    else if a == "--force"
      force? = true
    else if a == "--db"
      v = (try need_val(rest, i, "--db")).trim.ascii_lowercase
      if v != "modb" and v != "sqlite"
        return Error("invalid --db '#{v}'; expected 'modb' or 'sqlite'")
      end
      db = v
      i += 1
    else if a == "--auth"
      v = (try need_val(rest, i, "--auth")).trim.ascii_lowercase
      if v != "full" and v != "allowlist" and v != "none"
        return Error("invalid --auth '#{v}'; expected 'full', 'allowlist', or 'none'")
      end
      auth = v
      i += 1
    else if a == "--dir"
      dir = Some(try need_val(rest, i, "--dir"))
      i += 1
    else if a == "--arvo-path"
      arvo_path = try need_val(rest, i, "--arvo-path")
      i += 1
    else if a == "--modb-path"
      modb_path = try need_val(rest, i, "--modb-path")
      i += 1
    else if a.starts_with?("-")
      return Error("unknown flag '#{a}' for `arvo new`. Run `arvo new --help`.")
    else if not seen_name?
      app_name = a.trim
      seen_name? = true
    else
      return Error("unexpected positional argument '#{a}' for `arvo new`. Run `arvo new --help`.")
    end
    i += 1
  end

  if not seen_name? or not valid_app_name?(app_name)
    return Error(
      "expected a valid lowercase <app-name> (^[a-z][a-z0-9_-]*$). Run `arvo new --help`."
    )
  end
  Ok(
    NewArgs(
      app_name: app_name,
      db: db,
      auth: auth,
      orgs?: orgs?,
      mcp?: mcp?,
      dir: dir,
      arvo_path: arvo_path,
      modb_path: modb_path,
      force?: force?,
      help?: false
    )
  )
end

## Returns the exact `PageContract` manifest matching the scaffolded `Routes.contracts()`.
fn build_contracts(n: NewArgs) : List(Inertia.PageContract)
  var list = []
  if n.auth != "none"
    list = list.append(
      Inertia.page_contract[ScaffoldLoginProps, ScaffoldSharedProps](
        "Login",
        ["/login"],
        Inertia.Of,
        Inertia.Of
      )
    )
  end
  if n.auth == "full"
    list = list.append(
      Inertia.page_contract[ScaffoldRegisterProps, ScaffoldSharedProps](
        "Register",
        ["/register"],
        Inertia.Of,
        Inertia.Of
      )
    )
  end
  list.append(
    Inertia.page_contract[ScaffoldHomeProps, ScaffoldSharedProps](
      "Home",
      ["/"],
      Inertia.Of,
      Inertia.Of
    )
  )
end

fn render_mo_toml(n: NewArgs) : Text
  if n.db == "modb"
    """
    [package]
    name = "#{n.app_name}"
    version = "0.1.0"

    [dependencies]
    arvo = { path = "#{n.arvo_path}" }
    arvo-modb = { path = "#{n.arvo_path}/packages/arvo-modb" }
    modb = { path = "#{n.modb_path}" }
    """
  else
    """
    [package]
    name = "#{n.app_name}"
    version = "0.1.0"

    [dependencies]
    arvo = { path = "#{n.arvo_path}" }
    """
  end
end

fn render_arvo_toml(n: NewArgs) : Text
  pub = if n.auth == "full"
    "[\"GET /login\", \"POST /login\", \"GET /register\", \"POST /register\", \"GET /verify-email\"]"
  else if n.auth == "allowlist"
    "[\"GET /login\", \"POST /login\"]"
  else
    "[\"GET /\"]"
  end
  """
  [app]
  entry = "main.mo"
  contracts_module = "Routes"
  contracts_fn = "contracts"
  frontend_dir = "frontend"
  pages_dir = "frontend/src/pages"
  contracts_out = "frontend/src/arvo.gen.ts"
  features_dir = "specs/features"
  strength_dir = "strength"

  [testing]
  public_routes = #{pub}
  csrf_exempt_routes = []
  max_queries_per_get = 10
  sim_tier1_seeds = 200
  sim_tier2_seeds = 5000
  mo_mutant_min_kill_rate = 1.0
  ts_stryker_min_kill_rate = 0.85
  strength_min_kill_rate = 1.0
  viewports = [
    { name = "mobile", width = 390, height = 844 },
    { name = "desktop", width = 1280, height = 800 },
  ]
  visual_parity_max_diff_pixels = 0

  [testing.tamper_protected]
  globs = [
    "specs/features/**/*.feature.md",
    "snapshots/**/*",
    "strength/**/*",
    "arvo.toml",
  ]
  """
end

fn render_env_example(n: NewArgs) : Text
  """
  # Local development defaults for #{n.app_name} (`arvo dev` sets these automatically)
  ARVO_SECRET_KEY=0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20
  ARVO_SEED_PASSWORD=change-me-in-production
  ARVO_ALLOWLIST=ada@example.local
  ARVO_DEV=1
  ARVO_INSECURE_COOKIES=1
  ARVO_DEV_MAILBOX=.arvo/mailbox
  VITE_DEV_URL=http://127.0.0.1:5173
  """
end

fn render_routes_mo(n: NewArgs) : Text
  modb? = n.db == "modb"
  full_auth? = n.auth == "full"
  allow_auth? = n.auth == "allowlist"
  has_auth? = full_auth? or allow_auth?

  var exposes = [
    "AppError(..)",
    "AuthUser(..)",
    "FlashProps(..)",
    "SharedProps(..)",
    "HomeProps(..)",
    "contracts",
    "home",
    "live_stream",
    "dev_dashboard"
  ]
  if has_auth?
    exposes = [
      "Member(..)",
      "LoginProps(..)",
      "authenticate",
      "show_login",
      "post_login",
      "post_logout"
    ].concat(exposes)
  end
  if full_auth?
    exposes = exposes.concat(["RegisterProps(..)", "show_register", "post_register", "verify_email"])
  end
  if n.orgs?
    exposes = exposes.concat(["create_org"])
  end
  if n.mcp?
    exposes = exposes.concat(["PingInput(..)", "PingOutput(..)", "ping_action", "post_mcp"])
  end

  var uses = [
    "use Api",
    "use Arvo.DevDashboard",
    "use Arvo.Flash",
    "use Arvo.Inertia",
    "use Arvo.Keyring",
    "use Arvo.Live",
    "use Arvo.Web"
  ]
  if has_auth? or n.orgs?
    uses = uses.append("use Arvo.Form")
  end
  if full_auth?
    uses = uses.append("use Arvo.AuthKit")
    uses = uses.append("use Arvo.Mail")
  end
  if has_auth?
    uses = uses.append("use Arvo.Auth")
    uses = uses.append("use Arvo.Session")
  end
  if has_auth? or n.mcp?
    uses = uses.append("use Arvo.Changeset")
  end
  if n.mcp?
    uses = uses.append("use Arvo.Action")
    uses = uses.append("use Arvo.Mcp")
  end
  if n.orgs?
    uses = uses.append("use Arvo.Orgs")
  end
  if modb?
    uses = uses.append("use Arvo.Modb.Inspector")
    if has_auth?
      uses = uses.append("use Arvo.Modb.Sessions")
    end
    if full_auth?
      uses = uses.append("use Arvo.Modb.AuthStore")
    end
    if allow_auth? or n.orgs?
      uses = uses.append("use Modb")
      uses = uses.append("use Modb.Table")
    end
  else
    if has_auth?
      uses = uses.append("use Arvo.Sqlite.Migrations")
      uses = uses.append("use Arvo.Sqlite.Sessions")
    end
    if full_auth?
      uses = uses.append("use Arvo.Sqlite.AuthStore")
    end
  end
  uses_block = uses.sort.join("\n")

  member_decl = if has_auth?
    """
    struct Member
      id: Text
      email: Text
      display_name: Text
      session: Session.Session
    end

    struct LoginProps
      auth_mode: Text
      hint: Text
    end
    """
  else
    ""
  end

  reg_decl = if full_auth?
    """
    struct RegisterProps
      hint: Text
    end
    """
  else
    ""
  end

  db_constants = if modb?
    """
    auth_db_path = "auth.modb"
    sessions_db_path = "sessions.modb"
    """
  else
    ""
  end

  contracts_items = [
    if has_auth?: Some(
      "  list = list.append(Inertia.page_contract[LoginProps, SharedProps](\"Login\", [\"/login\"], Inertia.Of, Inertia.Of))"
    ) else: None,
    if full_auth?: Some(
      "  list = list.append(Inertia.page_contract[RegisterProps, SharedProps](\"Register\", [\"/register\"], Inertia.Of, Inertia.Of))"
    ) else: None,
    Some(
      "  list.append(Inertia.page_contract[HomeProps, SharedProps](\"Home\", [\"/\"], Inertia.Of, Inertia.Of))"
    )
  ].filter_map(fn(x) x end).join("\n")

  shared_helper = if has_auth?
    """
    fn build_shared(viewer: Option(Member), flash: Flash.FlashData) : SharedProps
      auth_u = case viewer
        Some(m): Some(AuthUser(id: m.id, email: m.email, display_name: m.display_name))
        None: None
      end
      SharedProps(
        auth: auth_u,
        flash: FlashProps(notice: flash.notice, alert: flash.alert),
        errors: Changeset.first_errors(flash.errors)
      )
    end
    """
  else
    """
    fn build_shared(flash: Flash.FlashData) : SharedProps
      SharedProps(
        auth: None,
        flash: FlashProps(notice: flash.notice, alert: flash.alert),
        errors: {}
      )
    end
    """
  end

  # Note: wait! In `--auth allowlist --db modb` without `n.mcp?`, did we import `Arvo.Changeset`?
  # Look: `build_shared` above uses `Changeset.first_errors(flash.errors)` whenever `has_auth?`!
  # We should make sure `Arvo.Changeset` is in `uses` whenever `has_auth?`! (Fixed right below.)
  orgs_store_section = if not n.orgs? and modb?
    """
    fn load_orgs(_rf: ReadFiles) : List(Text)
      []
    end
    """
  else if not n.orgs?
    """
    fn load_orgs_sql(_db: Sqlite.Database) : List(Text)
      []
    end
    """
  else if modb?
    """
    struct OrgEntry
      slug: Text
      name: Text
    end

    fn org_entries_table() : Table.Table(Text, OrgEntry)
      Table.text_key[OrgEntry]("_app_orgs")
    end

    fn load_orgs(rf: ReadFiles) : List(Text)
      return [] if not rf.exists?("app.modb")
      case Modb.with_shared_lock(rf, "app.modb", fn(e) e.to_text end, fn(s)
        buckets = try Modb.buckets(s).map_error(fn(e) e.to_text end)
        return Ok([]) if not buckets.contains?("_app_orgs")
        rows = try Table.all(s, org_entries_table()).map_error(fn(e) e.to_text end)
        Ok(rows.map(fn(p) p.1.slug end))
      end)
        Ok(slugs): slugs
        Error(_): []
      end
    end
    """
  else
    """
    fn load_orgs_sql(db: Sqlite.Database) : List(Text)
      case db.query("SELECT slug FROM app_orgs ORDER BY slug ASC", [])
        Ok(res): res.rows.filter_map(fn(r)
          case r.first
            Some(Sqlite.String(s)): Some(s)
            Some(_) | None: None
          end
        end)
        Error(_): []
      end
    end
    """
  end

  auth_section = render_auth_section(n)
  orgs_handler = render_orgs_handler(n)
  mcp_section = render_mcp_section(n)
  dev_dash_section = render_dev_dash_section(n)

  # Ensure Arvo.Changeset is always imported when `has_auth?`
  uses_fixed = if has_auth? and not uses.contains?("use Arvo.Changeset")
    uses.append("use Arvo.Changeset").sort.join("\n")
  else
    uses_block
  end

  """
  ## Generated routes and contracts for `#{n.app_name}` (`--db #{n.db} --auth #{n.auth}`).
  module Routes
  expose #{exposes.join(",\n")}
  #{uses_fixed}

  #{db_constants}

  #{member_decl}

  #{reg_decl}

  struct AuthUser
    id: Text
    email: Text
    display_name: Text
  end

  struct FlashProps
    notice: Option(Text)
    alert: Option(Text)
  end

  struct SharedProps
    auth: Option(AuthUser)
    flash: FlashProps
    errors: Map(Text, Text)
  end

  struct HomeProps
    app_name: Text
    db_engine: Text
    auth_mode: Text
    active_org: Option(Text)
    orgs: List(Text)
  end

  enum AppError
    Unauthenticated
    Forbidden
    BadInput(reason: Text)
    ServerFailed(reason: Text)
  end

  ## Typed Inertia v2 page contract manifest inspected by `arvo contracts`.
  fn contracts() : List(Inertia.PageContract)
    var list = []
  #{contracts_items}
  end

  fn secret_key_bytes(env: Env) : Result(Bytes, AppError)
    hex = env.get("ARVO_SECRET_KEY") or "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    k = try Bytes.from_hex(hex).or_fail(ServerFailed(reason: "ARVO_SECRET_KEY must be 64 hex chars"))
    if k.size == 32: Ok(k) else: Error(ServerFailed(reason: "ARVO_SECRET_KEY must decode to 32 bytes"))
  end

  fn app_keyring(env: Env) : Result(Keyring.Keyring, AppError)
    key = try secret_key_bytes(env)
    Keyring.single("v1", key).map_error(fn(e) ServerFailed(reason: Keyring.to_text(e)) end)
  end

  fn secure_cookies?(env: Env) : Bool
    (env.get("ARVO_INSECURE_COOKIES") or "0") != "1"
  end

  fn web_config(files: ReadFiles, env: Env) : Result(Web.WebConfig, AppError)
    title = "#{n.app_name}"
    icfg = if env.get("VITE_DEV_URL") is Some(u) and not u.trim.empty?
      Inertia.dev_config(title, u.trim, "src/main.tsx", "")
    else
      case files.read_bytes("public/manifest.json")
        Ok(mb): try Inertia.config_from_manifest(title, mb, "src/main.tsx", "").map_error(fn(e) ServerFailed(reason: e) end)
        Error(_): Inertia.dev_config(title, "http://127.0.0.1:5173", "src/main.tsx", "")
      end
    end
    Ok(Web.default_config(icfg, secure_cookies?(env)))
  end

  #{shared_helper}

  #{orgs_store_section}

  #{auth_section}

  #{orgs_handler}

  #{mcp_section}

  #{dev_dash_section}
  """
end

fn render_auth_section(n: NewArgs) : Text
  modb? = n.db == "modb"
  full? = n.auth == "full"
  allow? = n.auth == "allowlist"

  if n.auth == "none"
    home_body = if modb?
      """
      fn home(req: Api.Request, rf: ReadFiles, rng: SecureRandom, env: Env) : Result(Api.Response, AppError)
        kr = try app_keyring(env)
        cfg = try web_config(rf, env)
        orgs = load_orgs(rf)
        props = HomeProps(
          app_name: "#{n.app_name}",
          db_engine: "#{n.db}",
          auth_mode: "#{n.auth}",
          active_org: orgs.first,
          orgs: orgs
        )
        Ok(Web.render_page(req, rng, kr, cfg, "Home", props, fn(fl) build_shared(fl) end))
      end
      """
    else
      """
      fn home(req: Api.Request, db: Sqlite.Database, rf: ReadFiles, rng: SecureRandom, clock: Clock, env: Env) : Result(Api.Response, AppError)
        try ensure_sql_schema(db, clock)
        kr = try app_keyring(env)
        cfg = try web_config(rf, env)
        orgs = load_orgs_sql(db)
        props = HomeProps(
          app_name: "#{n.app_name}",
          db_engine: "#{n.db}",
          auth_mode: "#{n.auth}",
          active_org: orgs.first,
          orgs: orgs
        )
        Ok(Web.render_page(req, rng, kr, cfg, "Home", props, fn(fl) build_shared(fl) end))
      end

      fn ensure_sql_schema(db: Sqlite.Database, clock: Clock) : Result(Unit, AppError)
        _ = clock
        _ = try db.run("CREATE TABLE IF NOT EXISTS app_orgs (slug TEXT PRIMARY KEY, name TEXT NOT NULL) STRICT", []).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
        Ok(Unit)
      end
      """
    end
    return """
    #{home_body}

    fn live_stream(req: Api.Request) : Api.Response
      Live.stream(req, [Live.resource_topic("app", "#{n.app_name}")], [], Live.default_config())
    end
    """
  end

  session_cfg_fn = """
  fn session_cfg(env: Env) : Session.SessionConfig
    Session.SessionConfig(cookie_name: "arvo_session", ttl_seconds: 1209600, secure?: secure_cookies?(env))
  end
  """

  show_login_fn = if modb?
    """
    fn show_login(req: Api.Request, viewer: Option(Member), rf: ReadFiles, rng: SecureRandom, env: Env) : Result(Api.Response, AppError)
      return Ok(Inertia.redirect("/")) if viewer is Some(_)
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      props = LoginProps(auth_mode: "#{n.auth}", hint: if "#{n.auth}" == "full": "Sign in or register an account" else: "Allowlisted emails only")
      Ok(Web.render_page(req, rng, kr, cfg, "Login", props, fn(fl) build_shared(None, fl) end))
    end
    """
  else
    """
    fn show_login(req: Api.Request, viewer: Option(Member), rf: ReadFiles, rng: SecureRandom, env: Env) : Result(Api.Response, AppError)
      return Ok(Inertia.redirect("/")) if viewer is Some(_)
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      props = LoginProps(auth_mode: "#{n.auth}", hint: if "#{n.auth}" == "full": "Sign in or register an account" else: "Allowlisted emails only")
      Ok(Web.render_page(req, rng, kr, cfg, "Login", props, fn(fl) build_shared(None, fl) end))
    end
    """
  end

  home_authed = if modb?
    """
    fn home(req: Api.Request, viewer: Option(Member), rf: ReadFiles, rng: SecureRandom, env: Env) : Result(Api.Response, AppError)
      member = case viewer
        Some(m): m
        None: return Ok(Inertia.redirect("/login"))
      end
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      orgs = load_orgs(rf)
      props = HomeProps(
        app_name: "#{n.app_name}",
        db_engine: "#{n.db}",
        auth_mode: "#{n.auth}",
        active_org: orgs.first,
        orgs: orgs
      )
      Ok(Web.render_page(req, rng, kr, cfg, "Home", props, fn(fl) build_shared(Some(member), fl) end))
    end

    fn live_stream(req: Api.Request, member: Member) : Api.Response
      Live.stream(req, [Live.user_topic(member.id), Live.resource_topic("app", "#{n.app_name}")], [], Live.default_config())
    end
    """
  else
    """
    fn home(req: Api.Request, viewer: Option(Member), db: Sqlite.Database, rf: ReadFiles, rng: SecureRandom, clock: Clock, env: Env) : Result(Api.Response, AppError)
      member = case viewer
        Some(m): m
        None: return Ok(Inertia.redirect("/login"))
      end
      try ensure_sql_schema(db, clock)
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      orgs = load_orgs_sql(db)
      props = HomeProps(
        app_name: "#{n.app_name}",
        db_engine: "#{n.db}",
        auth_mode: "#{n.auth}",
        active_org: orgs.first,
        orgs: orgs
      )
      Ok(Web.render_page(req, rng, kr, cfg, "Home", props, fn(fl) build_shared(Some(member), fl) end))
    end

    fn live_stream(req: Api.Request, member: Member) : Api.Response
      Live.stream(req, [Live.user_topic(member.id), Live.resource_topic("app", "#{n.app_name}")], [], Live.default_config())
    end
    """
  end

  if full? and modb?
    """
    #{session_cfg_fn}

    fn mailbox_dir(env: Env) : Text
      env.get("ARVO_DEV_MAILBOX") or ".arvo/mailbox"
    end

    fn flow_cfg(env: Env) : AuthKit.AuthFlowConfig
      base_url = env.get("APP_URL") or "http://127.0.0.1:8080"
      AuthKit.default_flow_config("#{n.app_name}", base_url, "no-reply@#{n.app_name}.local", secure_cookies?(env))
    end

    fn authenticate(req: Api.Request, rf: ReadFiles, clock: Clock, env: Env) : Result(Member, AppError)
      key = try secret_key_bytes(env)
      loaded = try Sessions.load_read_only(req, rf, sessions_db_path, clock, key, session_cfg(env))
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      sess = try loaded.or_fail(Unauthenticated)
      user_opt = try AuthStore.get_user(rf, auth_db_path, sess.member_id).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      u = try user_opt.or_fail(Unauthenticated)
      return Error(Unauthenticated) if not Auth.user_active?(u)
      Ok(Member(id: u.id, email: u.email, display_name: u.display_name or u.email, session: sess))
    end

    #{show_login_fn}

    fn show_register(req: Api.Request, viewer: Option(Member), rf: ReadFiles, rng: SecureRandom, env: Env) : Result(Api.Response, AppError)
      return Ok(Inertia.redirect("/")) if viewer is Some(_)
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      Ok(Web.render_page(req, rng, kr, cfg, "Register", RegisterProps(hint: "Minimum 12 characters"), fn(fl) build_shared(None, fl) end))
    end

    fn post_register(req: Api.Request, files: Files, rng: SecureRandom, clock: Clock, env: Env) : Result(Api.Response, AppError)
      kr = try app_keyring(env)
      cfg = try web_config(files.read_only, env)
      fields = try Form.parse_urlencoded(req).map_error(fn(e) BadInput(reason: "\#{e}") end)
      email = Auth.normalize_email(Form.field(fields, "email") or "")
      password = Form.field(fields, "password") or ""
      raw_name = (Form.field(fields, "display_name") or "").trim
      display_name = if raw_name.empty?: None else: Some(raw_name)
      fcfg = flow_cfg(env)

      u = case AuthStore.create_user_with_password(files, auth_db_path, rng, clock, email, password, fcfg.password_policy, display_name, false)
        Ok(created): created
        Error(AuthStore.Validation(msg)): return Ok(Web.redirect_with_errors("/register", rng, kr, cfg, {"password": [msg]}))
        Error(AuthStore.Conflict(msg)): return Ok(Web.redirect_with_errors("/register", rng, kr, cfg, {"email": [msg]}))
        Error(err): return Error(ServerFailed(reason: "\#{err}"))
      end
      issued = try AuthStore.issue_and_store_token(files, auth_db_path, rng, clock, Some(u.id), Auth.EmailVerify, u.email, 86400)
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      mail_msg = AuthKit.build_verification_email(fcfg, u.email, issued.raw_token)
      _sent = Mail.deliver_dev_mailbox(mailbox_dir(env), mail_msg, files, rng, clock)
      key = try secret_key_bytes(env)
      scfg = session_cfg(env)
      (sess, cookie_val) = try Sessions.create(files, sessions_db_path, rng, clock, key, u.id, scfg)
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      redir = Web.redirect_with_notice("/", rng, kr, cfg, "Account created! Check Dev Mailbox to verify email.")
      Ok(Auth.login_response(redir, sess, cookie_val, scfg))
    end

    fn verify_email(viewer: Option(Member), files: Files, rng: SecureRandom, clock: Clock, env: Env, token: Option(Text)) : Result(Api.Response, AppError)
      _ = viewer
      kr = try app_keyring(env)
      cfg = try web_config(files.read_only, env)
      raw_tok = (token or "").trim
      return Ok(Web.redirect_with_alert("/login", rng, kr, cfg, "Missing verification token")) if raw_tok.empty?
      consumed = case AuthStore.consume_auth_token(files, auth_db_path, clock, raw_tok, Auth.EmailVerify, None)
        Ok(t): t
        Error(_): return Ok(Web.redirect_with_alert("/", rng, kr, cfg, "Invalid or expired verification link"))
      end
      if consumed.user_id is Some(uid)
        _v = try AuthStore.verify_user_email(files, auth_db_path, clock, uid).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      end
      Ok(Web.redirect_with_notice("/", rng, kr, cfg, "Email verified"))
    end

    fn post_login(req: Api.Request, files: Files, rng: SecureRandom, clock: Clock, env: Env) : Result(Api.Response, AppError)
      kr = try app_keyring(env)
      cfg = try web_config(files.read_only, env)
      fields = try Form.parse_urlencoded(req).map_error(fn(e) BadInput(reason: "\#{e}") end)
      email = Auth.normalize_email(Form.field(fields, "email") or "")
      password = Form.field(fields, "password") or ""
      user_opt = try AuthStore.authenticate_password(files, auth_db_path, clock, email, password)
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      u = case user_opt
        Some(found): found
        None: return Ok(Web.redirect_with_errors("/login", rng, kr, cfg, {"email": ["invalid email or password"]}))
      end
      key = try secret_key_bytes(env)
      scfg = session_cfg(env)
      (sess, cookie_val) = try Sessions.create(files, sessions_db_path, rng, clock, key, u.id, scfg)
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Auth.login_response(Web.redirect_with_notice("/", rng, kr, cfg, "Signed in"), sess, cookie_val, scfg))
    end

    fn post_logout(req: Api.Request, member: Member, files: Files, env: Env) : Result(Api.Response, AppError)
      return Error(Forbidden) if not Auth.require_csrf(req, member.session)
      _rev = try Sessions.revoke(files, sessions_db_path, member.session.id).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Auth.logout_response(Inertia.redirect("/login"), session_cfg(env)))
    end

    #{home_authed}
    """
  else if full? and not modb?
    """
    #{session_cfg_fn}

    fn mailbox_dir(env: Env) : Text
      env.get("ARVO_DEV_MAILBOX") or ".arvo/mailbox"
    end

    fn flow_cfg(env: Env) : AuthKit.AuthFlowConfig
      base_url = env.get("APP_URL") or "http://127.0.0.1:8080"
      AuthKit.default_flow_config("#{n.app_name}", base_url, "no-reply@#{n.app_name}.local", secure_cookies?(env))
    end

    fn ensure_sql_schema(db: Sqlite.Database, clock: Clock) : Result(Unit, AppError)
      sql = "\#{Sessions.schema_sql()};\\n\#{AuthStore.schema_sql()};\\nCREATE TABLE IF NOT EXISTS app_orgs (slug TEXT PRIMARY KEY, name TEXT NOT NULL) STRICT;"
      migs = [Migrations.Migration(version: 1, name: "init_app", sql: sql)]
      _applied = try Migrations.run(db, clock, migs).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Unit)
    end

    fn authenticate(req: Api.Request, db: Sqlite.Database, clock: Clock, env: Env) : Result(Member, AppError)
      try ensure_sql_schema(db, clock)
      key = try secret_key_bytes(env)
      loaded = try Sessions.load(req, db, clock, key, session_cfg(env)).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      sess = try loaded.or_fail(Unauthenticated)
      user_opt = try AuthStore.get_user(db, sess.member_id).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      u = try user_opt.or_fail(Unauthenticated)
      return Error(Unauthenticated) if not Auth.user_active?(u)
      Ok(Member(id: u.id, email: u.email, display_name: u.display_name or u.email, session: sess))
    end

    #{show_login_fn}

    fn show_register(req: Api.Request, viewer: Option(Member), rf: ReadFiles, rng: SecureRandom, env: Env) : Result(Api.Response, AppError)
      return Ok(Inertia.redirect("/")) if viewer is Some(_)
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      Ok(Web.render_page(req, rng, kr, cfg, "Register", RegisterProps(hint: "Minimum 12 characters"), fn(fl) build_shared(None, fl) end))
    end

    fn post_register(req: Api.Request, db: Sqlite.Database, files: Files, rng: SecureRandom, clock: Clock, env: Env) : Result(Api.Response, AppError)
      try ensure_sql_schema(db, clock)
      kr = try app_keyring(env)
      cfg = try web_config(files.read_only, env)
      fields = try Form.parse_urlencoded(req).map_error(fn(e) BadInput(reason: "\#{e}") end)
      email = Auth.normalize_email(Form.field(fields, "email") or "")
      password = Form.field(fields, "password") or ""
      raw_name = (Form.field(fields, "display_name") or "").trim
      display_name = if raw_name.empty?: None else: Some(raw_name)
      fcfg = flow_cfg(env)

      u = case AuthStore.create_user_with_password(db, rng, clock, email, password, fcfg.password_policy, display_name, false)
        Ok(created): created
        Error(AuthStore.Validation(msg)): return Ok(Web.redirect_with_errors("/register", rng, kr, cfg, {"password": [msg]}))
        Error(AuthStore.Conflict(msg)): return Ok(Web.redirect_with_errors("/register", rng, kr, cfg, {"email": [msg]}))
        Error(err): return Error(ServerFailed(reason: "\#{err}"))
      end
      issued = try AuthStore.issue_and_store_token(db, rng, clock, Some(u.id), Auth.EmailVerify, u.email, 86400)
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      mail_msg = AuthKit.build_verification_email(fcfg, u.email, issued.raw_token)
      _sent = Mail.deliver_dev_mailbox(mailbox_dir(env), mail_msg, files, rng, clock)
      key = try secret_key_bytes(env)
      scfg = session_cfg(env)
      (sess, cookie_val) = try Sessions.create(db, rng, clock, key, u.id, scfg)
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      redir = Web.redirect_with_notice("/", rng, kr, cfg, "Account created!")
      Ok(Auth.login_response(redir, sess, cookie_val, scfg))
    end

    fn verify_email(viewer: Option(Member), db: Sqlite.Database, rf: ReadFiles, rng: SecureRandom, clock: Clock, env: Env, token: Option(Text)) : Result(Api.Response, AppError)
      _ = viewer
      try ensure_sql_schema(db, clock)
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      raw_tok = (token or "").trim
      return Ok(Web.redirect_with_alert("/login", rng, kr, cfg, "Missing verification token")) if raw_tok.empty?
      consumed = case AuthStore.consume_auth_token(db, clock, raw_tok, Auth.EmailVerify, None)
        Ok(t): t
        Error(_): return Ok(Web.redirect_with_alert("/", rng, kr, cfg, "Invalid or expired verification link"))
      end
      if consumed.user_id is Some(uid)
        _v = try AuthStore.verify_user_email(db, clock, uid).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      end
      Ok(Web.redirect_with_notice("/", rng, kr, cfg, "Email verified"))
    end

    fn post_login(req: Api.Request, db: Sqlite.Database, rf: ReadFiles, rng: SecureRandom, clock: Clock, env: Env) : Result(Api.Response, AppError)
      try ensure_sql_schema(db, clock)
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      fields = try Form.parse_urlencoded(req).map_error(fn(e) BadInput(reason: "\#{e}") end)
      email = Auth.normalize_email(Form.field(fields, "email") or "")
      password = Form.field(fields, "password") or ""
      user_opt = try AuthStore.authenticate_password(db, email, password).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      u = case user_opt
        Some(found): found
        None: return Ok(Web.redirect_with_errors("/login", rng, kr, cfg, {"email": ["invalid email or password"]}))
      end
      key = try secret_key_bytes(env)
      scfg = session_cfg(env)
      (sess, cookie_val) = try Sessions.create(db, rng, clock, key, u.id, scfg)
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Auth.login_response(Web.redirect_with_notice("/", rng, kr, cfg, "Signed in"), sess, cookie_val, scfg))
    end

    fn post_logout(req: Api.Request, member: Member, db: Sqlite.Database, env: Env) : Result(Api.Response, AppError)
      return Error(Forbidden) if not Auth.require_csrf(req, member.session)
      _rev = try Sessions.revoke(db, member.session.id).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Auth.logout_response(Inertia.redirect("/login"), session_cfg(env)))
    end

    #{home_authed}
    """
  else if allow? and modb?
    """
    #{session_cfg_fn}

    struct SeedMember
      id: Text
      email: Text
      password_hash: Text
      display_name: Text
    end

    fn seed_members_table() : Table.Table(Text, SeedMember)
      Table.text_key[SeedMember]("_seed_members")
    end

    fn allowed_emails(env: Env) : List(Text)
      raw = env.get("ARVO_ALLOWLIST") or "ada@example.local"
      raw.split(",").map(fn(s) s.trim end).filter(fn(s) not s.empty? end)
    end

    fn ensure_seed_member(files: Files, rng: SecureRandom, env: Env) : Result(Unit, AppError)
      seed_pw = env.get("ARVO_SEED_PASSWORD") or "dev-password-change-me"
      pw_hash = try Auth.hash_password(rng, seed_pw).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      tbl = seed_members_table()
      Modb.with_exclusive_lock(files, auth_db_path, fn(e) ServerFailed(reason: e.to_text) end, fn(s)
        existing = try Table.get(s, tbl, "mem_ada").map_error(fn(e) ServerFailed(reason: e.to_text) end)
        return Ok(Unit) if existing != None
        tx = Modb.begin_write(s)
        tx1 = try Table.put(tx, tbl, "mem_ada", SeedMember(id: "mem_ada", email: "ada@example.local", password_hash: pw_hash, display_name: "Ada")).map_error(fn(e) ServerFailed(reason: e.to_text) end)
        _next = try Modb.commit(tx1).map_error(fn(e) ServerFailed(reason: e.to_text) end)
        Ok(Unit)
      end)
    end

    fn authenticate(req: Api.Request, rf: ReadFiles, clock: Clock, env: Env) : Result(Member, AppError)
      key = try secret_key_bytes(env)
      loaded = try Sessions.load_read_only(req, rf, sessions_db_path, clock, key, session_cfg(env))
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      sess = try loaded.or_fail(Unauthenticated)
      return Error(Unauthenticated) if not rf.exists?(auth_db_path)
      m_opt = try Modb.with_shared_lock(rf, auth_db_path, fn(e) ServerFailed(reason: e.to_text) end, fn(s)
        Table.get(s, seed_members_table(), sess.member_id).map_error(fn(e) ServerFailed(reason: e.to_text) end)
      end)
      m = try m_opt.or_fail(Unauthenticated)
      Ok(Member(id: m.id, email: m.email, display_name: m.display_name, session: sess))
    end

    #{show_login_fn}

    fn post_login(req: Api.Request, files: Files, rng: SecureRandom, clock: Clock, env: Env) : Result(Api.Response, AppError)
      try ensure_seed_member(files, rng, env)
      kr = try app_keyring(env)
      cfg = try web_config(files.read_only, env)
      fields = try Form.parse_urlencoded(req).map_error(fn(e) BadInput(reason: "\#{e}") end)
      email = Auth.normalize_email(Form.field(fields, "email") or "")
      password = Form.field(fields, "password") or ""
      if not Auth.email_allowed?(email, allowed_emails(env))
        return Ok(Web.redirect_with_errors("/login", rng, kr, cfg, {"email": ["email is not allowlisted"]}))
      end
      m_opt = try Modb.with_shared_lock(files.read_only, auth_db_path, fn(e) ServerFailed(reason: e.to_text) end, fn(s)
        rows = try Table.all(s, seed_members_table()).map_error(fn(e) ServerFailed(reason: e.to_text) end)
        Ok(rows.map(fn(p) p.1 end).find(fn(r) r.email == email end))
      end)
      m = case m_opt
        Some(found) if Auth.verify_password(password, found.password_hash): found
        Some(_) | None: return Ok(Web.redirect_with_errors("/login", rng, kr, cfg, {"email": ["invalid email or password"]}))
      end
      key = try secret_key_bytes(env)
      scfg = session_cfg(env)
      (sess, cookie_val) = try Sessions.create(files, sessions_db_path, rng, clock, key, m.id, scfg)
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Auth.login_response(Web.redirect_with_notice("/", rng, kr, cfg, "Signed in"), sess, cookie_val, scfg))
    end

    fn post_logout(req: Api.Request, member: Member, files: Files, env: Env) : Result(Api.Response, AppError)
      return Error(Forbidden) if not Auth.require_csrf(req, member.session)
      _rev = try Sessions.revoke(files, sessions_db_path, member.session.id).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Auth.logout_response(Inertia.redirect("/login"), session_cfg(env)))
    end

    #{home_authed}
    """
  else
    # allowlist + sqlite
    """
    #{session_cfg_fn}

    struct SeedRow
      id: Text
      email: Text
      password_hash: Text
      display_name: Text
    end

    fn allowed_emails(env: Env) : List(Text)
      raw = env.get("ARVO_ALLOWLIST") or "ada@example.local"
      raw.split(",").map(fn(s) s.trim end).filter(fn(s) not s.empty? end)
    end

    fn ensure_sql_schema(db: Sqlite.Database, clock: Clock) : Result(Unit, AppError)
      sql = "\#{Sessions.schema_sql()};\\nCREATE TABLE IF NOT EXISTS members (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, display_name TEXT NOT NULL) STRICT;\\nCREATE TABLE IF NOT EXISTS app_orgs (slug TEXT PRIMARY KEY, name TEXT NOT NULL) STRICT;"
      migs = [Migrations.Migration(version: 1, name: "init_allowlist", sql: sql)]
      _a = try Migrations.run(db, clock, migs).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Unit)
    end

    fn ensure_seed_member_sql(db: Sqlite.Database, rng: SecureRandom, clock: Clock, env: Env) : Result(Unit, AppError)
      try ensure_sql_schema(db, clock)
      res = try db.query("SELECT id, email, password_hash, display_name FROM members WHERE id = 'mem_ada'", []).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      return Ok(Unit) if not res.rows.empty?
      seed_pw = env.get("ARVO_SEED_PASSWORD") or "dev-password-change-me"
      pw_hash = try Auth.hash_password(rng, seed_pw).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      _ins = try db.execute("INSERT OR IGNORE INTO members (id, email, password_hash, display_name) VALUES ('mem_ada', 'ada@example.local', ?, 'Ada')", [Sqlite.String(pw_hash)]).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Unit)
    end

    fn authenticate(req: Api.Request, db: Sqlite.Database, clock: Clock, env: Env) : Result(Member, AppError)
      try ensure_sql_schema(db, clock)
      key = try secret_key_bytes(env)
      loaded = try Sessions.load(req, db, clock, key, session_cfg(env)).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      sess = try loaded.or_fail(Unauthenticated)
      res = try db.query("SELECT id, email, password_hash, display_name FROM members WHERE id = ?", [Sqlite.String(sess.member_id)]).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      opt = try Sqlite.decode_optional[SeedRow](res).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      m = try opt.or_fail(Unauthenticated)
      Ok(Member(id: m.id, email: m.email, display_name: m.display_name, session: sess))
    end

    #{show_login_fn}

    fn post_login(req: Api.Request, db: Sqlite.Database, rf: ReadFiles, rng: SecureRandom, clock: Clock, env: Env) : Result(Api.Response, AppError)
      try ensure_seed_member_sql(db, rng, clock, env)
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      fields = try Form.parse_urlencoded(req).map_error(fn(e) BadInput(reason: "\#{e}") end)
      email = Auth.normalize_email(Form.field(fields, "email") or "")
      password = Form.field(fields, "password") or ""
      if not Auth.email_allowed?(email, allowed_emails(env))
        return Ok(Web.redirect_with_errors("/login", rng, kr, cfg, {"email": ["email is not allowlisted"]}))
      end
      res = try db.query("SELECT id, email, password_hash, display_name FROM members WHERE email = ?", [Sqlite.String(email)]).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      opt = try Sqlite.decode_optional[SeedRow](res).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      m = case opt
        Some(found) if Auth.verify_password(password, found.password_hash): found
        Some(_) | None: return Ok(Web.redirect_with_errors("/login", rng, kr, cfg, {"email": ["invalid email or password"]}))
      end
      key = try secret_key_bytes(env)
      scfg = session_cfg(env)
      (sess, cookie_val) = try Sessions.create(db, rng, clock, key, m.id, scfg)
        .map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Auth.login_response(Web.redirect_with_notice("/", rng, kr, cfg, "Signed in"), sess, cookie_val, scfg))
    end

    fn post_logout(req: Api.Request, member: Member, db: Sqlite.Database, env: Env) : Result(Api.Response, AppError)
      return Error(Forbidden) if not Auth.require_csrf(req, member.session)
      _rev = try Sessions.revoke(db, member.session.id).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      Ok(Auth.logout_response(Inertia.redirect("/login"), session_cfg(env)))
    end

    #{home_authed}
    """
  end
end

fn render_orgs_handler(n: NewArgs) : Text
  return "" if not n.orgs?
  has_auth? = n.auth != "none"
  member_arg = if has_auth?: "member: Member, " else: ""
  csrf_guard = if has_auth?
    "return Error(Forbidden) if not Auth.require_csrf(req, member.session)"
  else
    ""
  end
  if n.db == "modb"
    """
    fn create_org(req: Api.Request, #{member_arg}files: Files, rng: SecureRandom, env: Env) : Result(Api.Response, AppError)
      #{csrf_guard}
      kr = try app_keyring(env)
      cfg = try web_config(files.read_only, env)
      fields = try Form.parse_urlencoded(req).map_error(fn(e) BadInput(reason: "\#{e}") end)
      slug = (Form.field(fields, "slug") or "").trim.ascii_lowercase
      name = (Form.field(fields, "name") or slug).trim
      if not Orgs.valid_slug?(slug) or name.empty?
        return Ok(Web.redirect_with_errors("/", rng, kr, cfg, {"slug": ["invalid workspace slug"]}))
      end
      tbl = org_entries_table()
      _saved = try Modb.with_exclusive_lock(files, "app.modb", fn(e) ServerFailed(reason: e.to_text) end, fn(s)
        tx = Modb.begin_write(s)
        tx1 = try Table.put(tx, tbl, slug, OrgEntry(slug: slug, name: name)).map_error(fn(e) ServerFailed(reason: e.to_text) end)
        _next = try Modb.commit(tx1).map_error(fn(e) ServerFailed(reason: e.to_text) end)
        Ok(Unit)
      end)
      res = Web.redirect_with_notice("/", rng, kr, cfg, "Workspace \#{slug} created")
      Ok(Live.invalidate_inertia(res, [Live.resource_topic("app", "#{n.app_name}")], ["orgs", "active_org"], Some("org.create")))
    end
    """
  else
    """
    fn create_org(req: Api.Request, #{member_arg}db: Sqlite.Database, rf: ReadFiles, rng: SecureRandom, clock: Clock, env: Env) : Result(Api.Response, AppError)
      #{csrf_guard}
      try ensure_sql_schema(db, clock)
      kr = try app_keyring(env)
      cfg = try web_config(rf, env)
      fields = try Form.parse_urlencoded(req).map_error(fn(e) BadInput(reason: "\#{e}") end)
      slug = (Form.field(fields, "slug") or "").trim.ascii_lowercase
      name = (Form.field(fields, "name") or slug).trim
      if not Orgs.valid_slug?(slug) or name.empty?
        return Ok(Web.redirect_with_errors("/", rng, kr, cfg, {"slug": ["invalid workspace slug"]}))
      end
      _ins = try db.execute("INSERT OR REPLACE INTO app_orgs (slug, name) VALUES (?, ?)", [Sqlite.String(slug), Sqlite.String(name)]).map_error(fn(e) ServerFailed(reason: "\#{e}") end)
      res = Web.redirect_with_notice("/", rng, kr, cfg, "Workspace \#{slug} created")
      Ok(Live.invalidate_inertia(res, [Live.resource_topic("app", "#{n.app_name}")], ["orgs", "active_org"], Some("org.create")))
    end
    """
  end
end

fn render_mcp_section(n: NewArgs) : Text
  return "" if not n.mcp?
  has_auth? = n.auth != "none"
  member_arg = if has_auth?: "member: Member, " else: ""
  csrf_check = if has_auth?
    "return Error(Forbidden) if not Auth.require_csrf(req, member.session)"
  else
    ""
  end
  actor_expr = if has_auth?
    "Action.context_for_member(member.id, Some(member.email), None, [\"app:read\"], None, None, clock.now)"
  else
    "Action.context_for_member(\"local-dev\", None, None, [\"app:read\"], None, None, clock.now)"
  end
  """
  struct PingInput
    message: Text
  end

  struct PingOutput
    echo: Text
    app_name: Text
  end

  fn validate_ping(input: PingInput) : Changeset.Changeset(PingInput)
    Changeset.new(input).require_non_empty("message", input.message)
  end

  fn ping_action() : Action.ActionSpec(PingInput)
    Action.define("app.ping", "Echo a health message from #{n.app_name}", validate_ping)
      .with_scope("app:read")
      .with_read_only(true)
  end

  fn post_mcp(req: Api.Request, #{member_arg}clock: Clock) : Result(Api.Response, AppError)
    #{csrf_check}
    srv = Mcp.ServerInfo(name: "#{n.app_name}-mcp", version: "0.1.0", protocol_version: Mcp.default_protocol_version, instructions: None)
    spec = ping_action()
    case Mcp.dispatch(req, srv, [Action.to_mcp_tool(spec)], [])
      Mcp.Respond(res): Ok(res)
      Mcp.ReadResource(id: rpc_id, uri: u): Ok(Mcp.tool_error(rpc_id, "unknown resource \#{u}"))
      Mcp.CallTool(id: rpc_id, name: tool_name, arguments: args):
        if tool_name != "app.ping"
          return Ok(Mcp.tool_error(rpc_id, "unknown tool \#{tool_name}"))
        end
        ctx = #{actor_expr}
        case Action.prepare_json(spec, ctx, args)
          Error(err): Ok(Action.mcp_error(rpc_id, err))
          Ok(prep):
            out = PingOutput(echo: prep.input.message, app_name: "#{n.app_name}")
            Ok(Action.mcp_success(spec, rpc_id, "pong: \#{prep.input.message}", out, []))
        end
    end
  end
  """
end

fn render_dev_dash_section(n: NewArgs) : Text
  has_auth? = n.auth != "none"
  member_arg = if has_auth?: "_member: Member, " else: ""
  if n.db == "modb"
    main_db = if n.auth == "full": "auth_db_path" else: "sessions_db_path"
    """
    fn dev_dashboard(req: Api.Request, #{member_arg}rf: ReadFiles, rng: SecureRandom, env: Env) : Api.Response
      dev_on? = (env.get("ARVO_DEV") or "0") == "1"
      mbox = env.get("ARVO_DEV_MAILBOX") or ".arvo/mailbox"
      dcfg = DevDashboard.default_config("#{n.app_name}", dev_on?, Some(mbox))
      if not dev_on?
        return DevDashboard.handle(req, rf, rng, dcfg, DevDashboard.empty_snapshot("modb"))
      end
      var icfg = Inspector.default_config(#{main_db})
      icfg.sessions_db_path = Some(sessions_db_path)
      snap = case Inspector.collect_snapshot(rf, icfg)
        Ok(s): s
        Error(_): DevDashboard.empty_snapshot("modb")
      end
      DevDashboard.handle(req, rf, rng, dcfg, snap)
    end
    """
  else
    """
    fn dev_dashboard(req: Api.Request, #{member_arg}rf: ReadFiles, rng: SecureRandom, env: Env) : Api.Response
      dev_on? = (env.get("ARVO_DEV") or "0") == "1"
      mbox = env.get("ARVO_DEV_MAILBOX") or ".arvo/mailbox"
      dcfg = DevDashboard.default_config("#{n.app_name}", dev_on?, Some(mbox))
      DevDashboard.handle(req, rf, rng, dcfg, DevDashboard.empty_snapshot("sqlite"))
    end
    """
  end
end

fn render_main_mo(n: NewArgs) : Text
  modb? = n.db == "modb"
  full? = n.auth == "full"
  has_auth? = n.auth != "none"

  api_auth_routes = if full?
    """
      get "/login" Routes.show_login
      post "/login" Routes.post_login
      get "/register" Routes.show_register
      post "/register" Routes.post_register
      get "/verify-email" Routes.verify_email
      post "/logout" Routes.post_logout
    """
  else if n.auth == "allowlist"
    """
      get "/login" Routes.show_login
      post "/login" Routes.post_login
      post "/logout" Routes.post_logout
    """
  else
    ""
  end

  app_start = if modb?
    "app = ApiTest.start(Main, files, clock, rng, env)"
  else
    "sql = Sqlite.in_memory()\n  app = ApiTest.start(Main, sql, clock, files, env, rng)"
  end

  test_flow = if full?
    """
      (s1, reg_res) = WebTest.post_form(
        s0,
        app,
        "/register",
        [("email", "ada@example.local"), ("password", "correct-horse-battery"), ("display_name", "Ada")]
      )
      _ = WebTest.expect_redirect(reg_res, "/")
      (s2, home_res) = WebTest.follow_redirect(s1, app)
      _ = WebTest.expect_status(home_res, 200)
      hp = WebTest.expect_inertia[Routes.HomeProps](home_res, "Home")
      assert hp.app_name == "#{n.app_name}"
      assert hp.auth_mode == "full"

      mails = case Mail.list_dev_mailbox(files.read_only, ".arvo/mailbox")
        Ok(ms): ms
        Error(_): stop "mailbox"
      end
      assert mails.size == 1
      verify_url = (Mail.extract_urls((mails.first or stop "mail").message.text_body)).first or stop "verify url"
      token = (verify_url.split("token=").get(1)) or stop "token"
      (s3, ver_res) = WebTest.get(s2, app, "/verify-email?token=\#{token}")
      _ = WebTest.expect_redirect(ver_res, "/")
    """
  else if n.auth == "allowlist"
    """
      (s1, guest_home) = WebTest.get(s0, app, "/")
      _ = WebTest.expect_redirect(guest_home, "/login")
      (s2, login_res) = WebTest.post_form(
        s1,
        app,
        "/login",
        [("email", "ada@example.local"), ("password", "horse-staple-battery")]
      )
      _ = WebTest.expect_redirect(login_res, "/")
      (s3, home_res) = WebTest.follow_redirect(s2, app)
      _ = WebTest.expect_status(home_res, 200)
      hp = WebTest.expect_inertia[Routes.HomeProps](home_res, "Home")
      assert hp.app_name == "#{n.app_name}"
    """
  else
    """
      (s3, home_res) = WebTest.get(s0, app, "/")
      _ = WebTest.expect_status(home_res, 200)
      hp = WebTest.expect_inertia[Routes.HomeProps](home_res, "Home")
      assert hp.app_name == "#{n.app_name}"
    """
  end

  client_var = "s3"
  extra_mcp_test = if n.mcp?
    """
      (_, mcp_res) = WebTest.post_json(
        #{client_var},
        app,
        "/mcp",
        Json.Object({
          "jsonrpc": Json.String("2.0"),
          "id": Json.int(1),
          "method": Json.String("tools/call"),
          "params": Json.Object({
            "name": Json.String("app.ping"),
            "arguments": Json.Object({"message": Json.String("hello arvo")})
          })
        })
      )
      assert mcp_res.status == 200 and mcp_res.text.contains?("pong: hello arvo")
    """
  else
    ""
  end

  extra_orgs_test = if n.orgs?
    """
      (_, org_res) = WebTest.post_form(#{client_var}, app, "/orgs", [("slug", "acme"), ("name", "Acme Corp")])
      _ = WebTest.expect_redirect(org_res, "/")
    """
  else
    ""
  end

  main_uses_list = [
    if full?: Some("use Arvo.Mail") else: None,
    Some("use Arvo.WebTest"),
    Some("use Json"),
    Some("use Routes")
  ].filter_map(fn(x) x end).join("\n")

  api_routes_section = [
    if not modb?: Some("  sqlite db from \"app.sqlite\"") else: None,
    if has_auth?: Some("  auth Routes.Member via Routes.authenticate") else: None,
    if not api_auth_routes.empty?: Some(api_auth_routes) else: None,
    Some("  get \"/\" Routes.home"),
    Some("  get \"/live\" Routes.live_stream"),
    Some("  get \"/__arvo\" Routes.dev_dashboard"),
    Some("  get \"/__arvo/mailbox\" Routes.dev_dashboard"),
    Some("  get \"/__arvo/storage.json\" Routes.dev_dashboard"),
    if n.orgs?: Some("  post \"/orgs\" Routes.create_org") else: None,
    if n.mcp?: Some("  post \"/mcp\" Routes.post_mcp") else: None
  ].filter_map(fn(x) x end).join("\n")

  extra_tests = [
    if not extra_orgs_test.empty?: Some(extra_orgs_test) else: None,
    if not extra_mcp_test.empty?: Some(extra_mcp_test) else: None
  ].filter_map(fn(x) x end).join("\n")

  """
  ## Generated Arvo application entrypoint for `#{n.app_name}`.
  module Main
  #{main_uses_list}

  api
    port 8080
    static "/assets" from "public/assets"
  #{api_routes_section}

    status Routes.Unauthenticated = 401
    status Routes.Forbidden = 403
    status Routes.BadInput(_) = 422
    status Routes.ServerFailed(_) = 500
  end

  ## Supports `mo run main.mo --arvo-contracts` for `arvo contracts`.
  fn main(args: Args, console: Console) : Int
    if args.list.contains?("--arvo-contracts")
      console.print(Json.encode(Routes.contracts()))
      0
    else
      console.print("Start server with: mo serve main.mo")
      0
    end
  end

  test "#{n.app_name} end-to-end smoke flow, /live, /__arvo fail-closed, and optional features"
    manifest = "{\\"src/main.tsx\\":{\\"file\\":\\"assets/main.js\\",\\"css\\":[],\\"isEntry\\":true}}"
    files = Files.in_memory({
      "public/manifest.json": manifest,
      "public/assets/main.js": "console.log('#{n.app_name}');"
    })
    rng = SecureRandom.seeded(42)
    clock = Clock.fixed(Time.parse("2026-11-28T00:00:00Z") or stop "clock")
    env = Env.of({
      "ARVO_SECRET_KEY": "1111111111111111111111111111111122222222222222222222222222222222",
      "ARVO_ALLOWLIST": "ada@example.local",
      "ARVO_SEED_PASSWORD": "horse-staple-battery",
      "ARVO_INSECURE_COOKIES": "1"
    })
    #{app_start}
    s0 = WebTest.start().with_header("Host", "localhost:8080")
  #{test_flow}
    (_, dash_404) = WebTest.get(#{client_var}, app, "/__arvo")
    _ = WebTest.expect_status(dash_404, 404)
    (_, live_res) = WebTest.get(#{client_var}, app, "/live")
    assert live_res.status == 200 and live_res.text.contains?("event: live.connected")
  #{extra_tests}
  end
  """
end

fn render_feature_md(n: NewArgs) : Text
  """
  # #{n.app_name} Home Workspace

  Core landing workflow for `#{n.app_name}` (`#{n.db}`, auth=`#{n.auth}`).

  ## Sub-features

  - `home-render`: renders `Home` Inertia props cleanly.
  - `live-stream`: delivers `/live` SSE invalidation frames.

  ## How to get to it (user POV)

  - Open `/` (after signing in when auth is enabled).

  ## Scenarios

  ```gherkin
  Feature: #{n.app_name} workspace
    @smoke
    Scenario: User loads the Home dashboard
      Given I visit "/"
      Then the Inertia component is "Home"
  ```

  ## Gotchas

  - Keep `/__arvo` disabled unless `ARVO_DEV=1`.
  """
end

fn render_frontend_pkg(n: NewArgs) : Text
  """
  {
    "name": "#{n.app_name}-frontend",
    "private": true,
    "version": "0.1.0",
    "type": "module",
    "scripts": {
      "dev": "vite --host 127.0.0.1 --port 5173",
      "build": "tsc -b && vite build",
      "test": "vitest run"
    },
    "dependencies": {
      "@inertiajs/react": "^2.0.0",
      "react": "^19.0.0",
      "react-dom": "^19.0.0"
    },
    "devDependencies": {
      "@tailwindcss/vite": "^4.0.0",
      "@types/react": "^19.0.0",
      "@types/react-dom": "^19.0.0",
      "@vitejs/plugin-react": "^4.3.4",
      "tailwindcss": "^4.0.0",
      "typescript": "^5.7.0",
      "vite": "^6.0.0",
      "vitest": "^4.1.12"
    }
  }
  """
end

fn render_tsconfig() : Text
  """
  {
    "compilerOptions": {
      "target": "ES2022",
      "useDefineForClassFields": true,
      "lib": ["ES2022", "DOM", "DOM.Iterable"],
      "module": "ESNext",
      "skipLibCheck": true,
      "moduleResolution": "bundler",
      "allowImportingTsExtensions": true,
      "isolatedModules": true,
      "moduleDetection": "force",
      "noEmit": true,
      "jsx": "react-jsx",
      "strict": true
    },
    "include": ["src"]
  }
  """
end

fn render_vite_config() : Text
  """
  import tailwindcss from "@tailwindcss/vite";
  import react from "@vitejs/plugin-react";
  import { defineConfig } from "vite";

  export default defineConfig({
    plugins: [react(), tailwindcss()],
    server: {
      host: "127.0.0.1",
      port: 5173,
      strictPort: true,
      origin: "http://127.0.0.1:5173",
    },
    build: {
      outDir: "../public",
      emptyOutDir: true,
      manifest: "manifest.json",
      assetsDir: "assets",
      rollupOptions: { input: "src/main.tsx" },
    },
  });
  """
end

fn render_main_tsx() : Text
  """
  import "./index.css";
  import { createInertiaApp } from "@inertiajs/react";
  import { createRoot } from "react-dom/client";

  createInertiaApp({
    resolve: (name) => {
      const pages = import.meta.glob("./pages/**/*.tsx", { eager: true });
      return pages[`./pages/${name}.tsx`];
    },
    setup({ el, App, props }) {
      createRoot(el).render(<App {...props} />);
    },
  });
  """
end

fn render_use_arvo_live_ts() : Text
  """
  import { router } from "@inertiajs/react";
  import { useEffect, useState } from "react";

  export function useArvoLive(url = "/live", enabled = true) {
    const [connected, setConnected] = useState(false);

    useEffect(() => {
      if (!enabled || typeof EventSource === "undefined") return;
      const es = new EventSource(url, { withCredentials: true });
      es.addEventListener("live.connected", () => setConnected(true));
      es.addEventListener("inertia.reload", (ev: MessageEvent) => {
        try {
          const parsed = JSON.parse(String(ev.data)) as { only?: string[] };
          router.reload({
            only: Array.isArray(parsed.only) && parsed.only.length > 0 ? parsed.only : undefined,
          });
        } catch {
          router.reload();
        }
      });
      es.onerror = () => setConnected(false);
      return () => es.close();
    }, [url, enabled]);

    return { connected };
  }
  """
end

fn render_home_tsx(n: NewArgs) : Text
  signout_btn = if n.auth != "none"
    """
            {auth && (
              <button
                type="button"
                onClick={() => router.post("/logout")}
                className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium"
              >
                Sign out
              </button>
            )}
    """
  else
    ""
  end
  """
  import { router } from "@inertiajs/react";
  import type { HomePageProps } from "../arvo.gen";
  import { useArvoLive } from "../hooks/useArvoLive";

  export default function Home({
    app_name,
    db_engine,
    auth_mode,
    active_org,
    orgs,
    auth,
    flash,
  }: HomePageProps) {
    const { connected } = useArvoLive("/live", true);

    return (
      <main className="mx-auto max-w-2xl space-y-6 p-6 text-slate-900">
        <header className="flex items-center justify-between gap-4 border-b border-slate-200 pb-4">
          <div>
            <h1 className="text-2xl font-semibold">{app_name}</h1>
            <p className="text-sm text-slate-600">
              Backend: {db_engine} · Auth: {auth_mode} · Live: {connected ? "online" : "connecting"}
            </p>
          </div>
  #{signout_btn}
        </header>
        {flash.notice && (
          <p role="status" className="rounded bg-emerald-50 p-3 text-sm text-emerald-900">
            {flash.notice}
          </p>
        )}
        {flash.alert && (
          <p role="alert" className="rounded bg-red-50 p-3 text-sm text-red-800">
            {flash.alert}
          </p>
        )}
        <section className="rounded border border-slate-200 p-4 text-sm">
          <p>Signed in as: {auth?.display_name ?? "Guest"}</p>
          <p>Active workspace: {active_org ?? "None"}</p>
          {orgs.length > 0 && <p>Workspaces: {orgs.join(", ")}</p>}
        </section>
      </main>
    );
  }
  """
end

fn render_login_tsx(n: NewArgs) : Text
  reg_link = if n.auth == "full"
    "      <p className=\"text-sm text-slate-600\">Need an account? <a className=\"underline\" href=\"/register\">Register</a></p>\n"
  else
    ""
  end
  """
  import { useForm } from "@inertiajs/react";
  import type { FormEvent } from "react";
  import type { LoginPageProps } from "../arvo.gen";

  export default function Login({ hint, errors, flash }: LoginPageProps) {
    const form = useForm({ email: "", password: "" });

    function submit(e: FormEvent) {
      e.preventDefault();
      form.post("/login", { headers: { "Content-Type": "application/x-www-form-urlencoded" } });
    }

    return (
      <main className="mx-auto max-w-sm space-y-4 p-6 text-slate-900">
        <h1 className="text-2xl font-semibold">Sign in</h1>
        <p className="text-sm text-slate-600">{hint}</p>
        {flash.alert && <p role="alert" className="rounded bg-red-50 p-2 text-sm text-red-800">{flash.alert}</p>}
        <form onSubmit={submit} className="space-y-3">
          <div>
            <label htmlFor="email" className="block text-sm font-medium">Email</label>
            <input
              id="email"
              type="email"
              value={form.data.email}
              onChange={(e) => form.setData("email", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
            />
            {errors.email && <p role="alert" className="mt-1 text-xs text-red-700">{errors.email}</p>}
          </div>
          <div>
            <label htmlFor="password" className="block text-sm font-medium">Password</label>
            <input
              id="password"
              type="password"
              value={form.data.password}
              onChange={(e) => form.setData("password", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
            />
            {errors.password && <p role="alert" className="mt-1 text-xs text-red-700">{errors.password}</p>}
          </div>
          <button type="submit" disabled={form.processing} className="w-full rounded bg-slate-900 py-2 font-medium text-white">
            Sign in
          </button>
        </form>
  #{reg_link}    </main>
    );
  }
  """
end

fn render_register_tsx() : Text
  """
  import { useForm } from "@inertiajs/react";
  import type { FormEvent } from "react";
  import type { RegisterPageProps } from "../arvo.gen";

  export default function Register({ hint, errors }: RegisterPageProps) {
    const form = useForm({ email: "", display_name: "", password: "" });

    function submit(e: FormEvent) {
      e.preventDefault();
      form.post("/register", { headers: { "Content-Type": "application/x-www-form-urlencoded" } });
    }

    return (
      <main className="mx-auto max-w-sm space-y-4 p-6 text-slate-900">
        <h1 className="text-2xl font-semibold">Create account</h1>
        <p className="text-sm text-slate-600">{hint}</p>
        <form onSubmit={submit} className="space-y-3">
          <div>
            <label htmlFor="email" className="block text-sm font-medium">Email</label>
            <input
              id="email"
              type="email"
              value={form.data.email}
              onChange={(e) => form.setData("email", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
            />
            {errors.email && <p role="alert" className="mt-1 text-xs text-red-700">{errors.email}</p>}
          </div>
          <div>
            <label htmlFor="display_name" className="block text-sm font-medium">Name</label>
            <input
              id="display_name"
              type="text"
              value={form.data.display_name}
              onChange={(e) => form.setData("display_name", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
            />
          </div>
          <div>
            <label htmlFor="password" className="block text-sm font-medium">Password</label>
            <input
              id="password"
              type="password"
              value={form.data.password}
              onChange={(e) => form.setData("password", e.target.value)}
              className="mt-1 w-full rounded border border-slate-300 px-3 py-2"
            />
            {errors.password && <p role="alert" className="mt-1 text-xs text-red-700">{errors.password}</p>}
          </div>
          <button type="submit" disabled={form.processing} className="w-full rounded bg-slate-900 py-2 font-medium text-white">
            Create account
          </button>
        </form>
      </main>
    );
  }
  """
end

## Returns all relative file `(path, contents)` pairs generated for `nargs`.
fn plan_app_files(nargs: NewArgs) : List((Text, Text))
  gen_ts = Codegen.generate_ts(build_contracts(nargs), None)
  var list = [
    ("mo.toml", render_mo_toml(nargs)),
    ("arvo.toml", render_arvo_toml(nargs)),
    (".env.example", render_env_example(nargs)),
    ("routes.mo", render_routes_mo(nargs)),
    ("main.mo", render_main_mo(nargs)),
    ("specs/features/home.feature.md", render_feature_md(nargs)),
    ("frontend/package.json", render_frontend_pkg(nargs)),
    ("frontend/tsconfig.json", render_tsconfig()),
    ("frontend/vite.config.ts", render_vite_config()),
    ("frontend/src/index.css", "@import \"tailwindcss\";\n"),
    ("frontend/src/main.tsx", render_main_tsx()),
    ("frontend/src/hooks/useArvoLive.ts", render_use_arvo_live_ts()),
    ("frontend/src/arvo.gen.ts", gen_ts),
    ("frontend/src/pages/Home.tsx", render_home_tsx(nargs))
  ]
  if nargs.auth != "none"
    list = list.append(("frontend/src/pages/Login.tsx", render_login_tsx(nargs)))
  end
  if nargs.auth == "full"
    list = list.append(("frontend/src/pages/Register.tsx", render_register_tsx()))
  end
  list
end

fn parent_dir(path: Text) : Text
  parts = path.split("/")
  if parts.size <= 1: "." else: parts.take(parts.size - 1).join("/")
end

## Scaffolds a new Arvo application according to `nargs`.
fn run_new(nargs: NewArgs, files: Files, console: Console) : Int
  if nargs.help?
    console.print(new_usage())
    return 0
  end

  target_dir = (nargs.dir or nargs.app_name).trim.drop_suffix("/") or
    (nargs.dir or nargs.app_name).trim
  if not nargs.force? and files.read_only.exists?("#{target_dir}/mo.toml")
    console.error("arvo new: '#{target_dir}/mo.toml' already exists (pass --force to overwrite)")
    return 1
  end

  planned = plan_app_files(nargs)
  for (rel, content) in planned
    full = if target_dir == ".": rel else: "#{target_dir}/#{rel}"
    pdir = parent_dir(full)
    if pdir != "."
      if files.make_folder(pdir) is Error(e)
        console.error("arvo new: failed creating folder '#{pdir}': #{e}")
        return 1
      end
    end
    if files.write_text(full, content) is Error(e)
      console.error("arvo new: failed writing '#{full}': #{e}")
      return 1
    end
  end

  console.print(
    "Created Arvo app '#{nargs.app_name}' at #{target_dir} (db=#{nargs.db}, auth=#{nargs.auth})"
  )
  console.print("Next steps:")
  console.print("  cd #{target_dir}")
  console.print("  mo test main.mo")
  console.print("  arvo dev")
  0
end

test "NewCmd validates app names, scaffolds MoDB/SQLite presets with exact arvo.gen.ts, and guards overwrite"
  assert parse_new_args(["--help"]) is Ok(h) and h.help?
  assert parse_new_args([]) is Error(_)
  assert parse_new_args(["../bad"]) is Error(_)
  assert parse_new_args(["BadCaps"]) is Error(_)
  assert parse_new_args(["my-app", "--db", "postgres"]) is Error(_)
  assert parse_new_args(["my-app", "--auth", "magic"]) is Error(_)

  assert parse_new_args([
    "acme-bills",
    "--db",
    "modb",
    "--auth",
    "full",
    "--orgs",
    "--mcp",
    "--arvo-path",
    "../../arvo",
    "--modb-path",
    "../../modb"
  ]) is
    Ok(n_modb)
  assert n_modb.db == "modb" and n_modb.auth == "full" and n_modb.orgs? and n_modb.mcp?

  files = Files.in_memory({})
  assert run_new(n_modb, files, Console.fake()) == 0
  assert files.exists?("acme-bills/mo.toml")
  assert files.exists?("acme-bills/arvo.toml")
  assert files.exists?("acme-bills/routes.mo")
  assert files.exists?("acme-bills/main.mo")
  assert files.exists?("acme-bills/frontend/src/arvo.gen.ts")
  assert files.exists?("acme-bills/frontend/src/pages/Login.tsx")
  assert files.exists?("acme-bills/frontend/src/pages/Register.tsx")
  assert files.exists?("acme-bills/frontend/src/pages/Home.tsx")
  assert files.exists?("acme-bills/specs/features/home.feature.md")

  assert files.read_text("acme-bills/mo.toml") is Ok(mt) and mt.contains?("arvo-modb")
  assert files.read_text("acme-bills/routes.mo") is Ok(rm) and
    rm.contains?("Arvo.Modb.AuthStore") and
    rm.contains?("post_mcp") and
    rm.contains?("create_org")

  # Refuses overwrite without --force, permits with --force
  assert run_new(n_modb, files, Console.fake()) == 1
  assert parse_new_args(["acme-bills", "--force"]) is Ok(n_forced)
  assert run_new(n_forced, files, Console.fake()) == 0

  assert parse_new_args([
    "lite-app",
    "--db",
    "sqlite",
    "--auth",
    "allowlist",
    "--dir",
    "out/lite-app"
  ]) is
    Ok(n_sql)
  assert run_new(n_sql, files, Console.fake()) == 0
  assert files.exists?("out/lite-app/main.mo")
  assert not files.exists?("out/lite-app/frontend/src/pages/Register.tsx")
  assert files.read_text("out/lite-app/routes.mo") is Ok(srm) and
    srm.contains?("Arvo.Sqlite.Sessions")
end
