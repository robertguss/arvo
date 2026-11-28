## Explicit zero-macro code generators (`arvo gen <kind> <Name> [field:type ...]`)
## producing idiomatic Mo resources, Auth v2 wiring, Inertia pages + React components,
## durable jobs, and `Arvo.Action` MCP tools across both MoDB and SQLite backends.
module GenCmd
expose GenKind(..),
FieldDef(..),
GenArgs(..),
gen_usage,
valid_gen_name?,
to_pascal,
to_snake,
to_kebab,
parse_gen_args,
plan_files,
run_gen
use Json

## Generator target kind.
enum GenKind
  ResourceKind
  AuthKind
  PageKind
  JobKind
  McpToolKind
end

## Parsed field specification (`name:Type`).
struct FieldDef
  name: Text
  mo_type: Text
  ts_type: Text
end

## Parsed arguments for `arvo gen`.
struct GenArgs
  kind: GenKind
  name: Text
  fields: List(FieldDef)
  db: Text
  dry_run?: Bool
  force?: Bool
  help?: Bool
end

## Usage text for `arvo gen`.
fn gen_usage() : Text
  """
    usage: arvo gen <kind> <Name> [field:type ...] [--app DIR] [--db modb|sqlite] [--dry-run] [--force]

    Explicit, zero-macro generators producing inspectable Mo + React + Feature Map code.

    Kinds:
      resource   Mo module (Record, Input, Changeset, Policy, Action, DB store), React page, Feature Map
      auth       Auth v2 wiring module (Auth, AuthKit, Totp, Mail, Modb/Sqlite AuthStore)
      page       Typed Inertia PageProps + PageContract module + React TSX component
      job        Idempotent Arvo.Modb.Jobs or Arvo.Sqlite.Jobs background handler module
      mcp-tool   Typed Arvo.Action + Changeset + MCP tool + OpenAPI spec module

    Supported field types: Text, Int, Float, Bool, Time, Option(Text), Option(Int)

    Flags:
      --app DIR          Target application subdirectory (default: `.`)
      --db modb|sqlite   Persistence backend for generated Mo code (default: modb)
      --dry-run          Print planned file paths as JSON without writing files
      --force            Overwrite existing generated files
      -h, --help         Show this help
    """
end

## Validates identifier characters (`^[A-Za-z][A-Za-z0-9_-]{0,63}$`).
fn valid_gen_name?(raw: Text) : Bool
  t = raw.trim
  return false if t.empty? or t.byte_count > 64
  first = t.chars.first or ' '
  return false if not first.ascii_letter?
  t.chars.all?(fn(c) c.ascii_letter? or c.ascii_digit? or c == '_' or c == '-' end)
end

fn ascii_upper?(ch: Char) : Bool
  c = ch.code
  c >= 65 and c <= 90
end

fn ascii_lower?(ch: Char) : Bool
  c = ch.code
  c >= 97 and c <= 122
end

fn split_name_words(raw: Text) : List(Text)
  var words = []
  var cur = []
  var prev_lower? = false
  for ch in raw.trim.chars
    if ch == '-' or ch == '_' or ch == ' '
      if not cur.empty?
        words = words.append(Text.from_chars(cur).ascii_lowercase)
        cur = []
      end
      prev_lower? = false
    else if ascii_upper?(ch) and prev_lower? and not cur.empty?
      words = words.append(Text.from_chars(cur).ascii_lowercase)
      cur = [ch]
      prev_lower? = false
    else
      cur = cur.append(ch)
      prev_lower? = ascii_lower?(ch)
    end
  end
  if not cur.empty?
    words = words.append(Text.from_chars(cur).ascii_lowercase)
  end
  words
end

fn capitalize_word(w: Text) : Text
  chars = w.chars
  case chars.first
    None: ""
    Some(c): Text.from_chars([c.ascii_uppercase].concat(chars.drop(1)))
  end
end

## Converts `raw` (e.g. `pay-invoice`, `PayInvoice`, `pay_invoice`) to `PascalCase`.
fn to_pascal(raw: Text) : Text
  split_name_words(raw).map(capitalize_word).join("")
end

## Converts `raw` to `snake_case`.
fn to_snake(raw: Text) : Text
  split_name_words(raw).join("_")
end

## Converts `raw` to `kebab-case` matching Mo `E0035` module filename conventions.
fn to_kebab(raw: Text) : Text
  split_name_words(raw).join("-")
end

fn valid_field_name?(raw: Text) : Bool
  t = raw.trim
  return false if t.empty?
  first = t.chars.first or ' '
  return false if not (ascii_lower?(first) or first == '_')
  t.chars.all?(fn(c) ascii_lower?(c) or c.ascii_digit? or c == '_' end)
end

fn parse_field_def(token: Text) : Result(FieldDef, Text)
  parts = token.split(":")
  if parts.size != 2
    return Error("expected field specification '<name>:<Type>', got '#{token}'")
  end
  fname = (parts.get(0) or "").trim
  if not valid_field_name?(fname)
    return Error("invalid snake_case field name '#{fname}' in '#{token}'")
  end
  raw_ty = (parts.get(1) or "").trim
  (mo_ty, ts_ty) = if raw_ty == "Text" or raw_ty == "string"
    ("Text", "string")
  else if raw_ty == "Int" or raw_ty == "int" or raw_ty == "number"
    ("Int", "number")
  else if raw_ty == "Float" or raw_ty == "float"
    ("Float", "number")
  else if raw_ty == "Bool" or raw_ty == "bool" or raw_ty == "boolean"
    ("Bool", "boolean")
  else if raw_ty == "Time" or raw_ty == "time"
    ("Time", "string")
  else if raw_ty == "Option(Text)"
    ("Option(Text)", "string | null")
  else if raw_ty == "Option(Int)"
    ("Option(Int)", "number | null")
  else
    return Error(
      "unsupported field type '#{raw_ty}' in '#{token}' (supported: Text, Int, Float, Bool, Time, Option(Text), Option(Int))"
    )
  end
  Ok(FieldDef(name: fname, mo_type: mo_ty, ts_type: ts_ty))
end

fn parse_kind(raw: Text) : Result(GenKind, Text)
  k = raw.trim.ascii_lowercase
  if k == "resource"
    Ok(ResourceKind)
  else if k == "auth"
    Ok(AuthKind)
  else if k == "page"
    Ok(PageKind)
  else if k == "job"
    Ok(JobKind)
  else if k == "mcp-tool"
    Ok(McpToolKind)
  else
    Error("unknown generator kind '#{raw}' (expected resource, auth, page, job, or mcp-tool)")
  end
end

fn need_val(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("`#{flag}` requires a value. Run `arvo gen --help`.")
  else
    Ok(v)
  end
end

## Parses arguments after `arvo gen`.
fn parse_gen_args(rest: List(Text)) : Result(GenArgs, Text)
  var db = "modb"
  var dry_run? = false
  var force? = false
  var positionals = []
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(
        GenArgs(
          kind: ResourceKind,
          name: "",
          fields: [],
          db: db,
          dry_run?: dry_run?,
          force?: force?,
          help?: true
        )
      )
    else if a == "--dry-run"
      dry_run? = true
    else if a == "--force"
      force? = true
    else if a == "--db"
      v = (try need_val(rest, i, "--db")).trim.ascii_lowercase
      if v != "modb" and v != "sqlite"
        return Error("invalid --db '#{v}'; expected 'modb' or 'sqlite'")
      end
      db = v
      i += 1
    else if a.starts_with?("-")
      return Error("unknown flag '#{a}' for `arvo gen`. Run `arvo gen --help`.")
    else
      positionals = positionals.append(a)
    end
    i += 1
  end

  if positionals.size < 2
    return Error("usage: arvo gen <kind> <Name> [field:type ...]. Run `arvo gen --help`.")
  end
  kind = try parse_kind(positionals.get(0) or "")
  name = (positionals.get(1) or "").trim
  if not valid_gen_name?(name)
    return Error("invalid name '#{name}'; expected ^[A-Za-z][A-Za-z0-9_-]*$")
  end
  var fields = []
  for tok in positionals.drop(2)
    fields = fields.append(try parse_field_def(tok))
  end
  if fields.empty? and (kind is ResourceKind or kind is McpToolKind)
    fields = [FieldDef(name: "title", mo_type: "Text", ts_type: "string")]
  end
  Ok(
    GenArgs(
      kind: kind,
      name: name,
      fields: fields,
      db: db,
      dry_run?: dry_run?,
      force?: force?,
      help?: false
    )
  )
end

fn changeset_checks(fields: List(FieldDef)) : Text
  var chain = ""
  for f in fields
    if f.mo_type == "Text"
      chain = "#{chain}.require_non_empty(\"#{f.name}\", input.#{f.name})"
    else if f.mo_type == "Int"
      chain = "#{chain}.require_non_negative_int(\"#{f.name}\", input.#{f.name})"
    end
  end
  chain
end

fn render_struct_fields(fields: List(FieldDef), indent: Text) : Text
  fields.map(fn(f) "#{indent}#{f.name}: #{f.mo_type}" end).join("\n")
end

fn render_ctor_assigns(fields: List(FieldDef), src_var: Text, indent: Text) : Text
  fields.map(fn(f) "#{indent}#{f.name}: #{src_var}.#{f.name}" end).join(",\n")
end

fn render_resource_mo(g: GenArgs) : Text
  pascal = to_pascal(g.name)
  snake = to_snake(g.name)
  fields_mo = render_struct_fields(g.fields, "  ")
  assigns = render_ctor_assigns(g.fields, "input", "    ")
  checks = changeset_checks(g.fields)

  if g.db == "modb"
    """
    ## Generated MoDB resource module for `#{pascal}` (`_#{snake}` table + `Arvo.Action`).
    module #{pascal}
    expose #{pascal}Record(..),
    #{pascal}Input(..),
    #{snake}_table,
    validate_input,
    create_action,
    save_record,
    list_records
    use Arvo.Action
    use Arvo.Changeset
    use Arvo.Orgs
    use Modb
    use Modb.Table

    struct #{pascal}Record
      id: Text
    #{fields_mo}
      created_at: Time
    end

    struct #{pascal}Input
    #{fields_mo}
    end

    fn #{snake}_table() : Table.Table(Text, #{pascal}Record)
      Table.text_key[#{pascal}Record]("_#{snake}")
    end

    fn validate_input(input: #{pascal}Input) : Changeset.Changeset(#{pascal}Input)
      Changeset.new(input)#{checks}
    end

    fn create_action() : Action.ActionSpec(#{pascal}Input)
      Action.define("#{snake}.create", "Create #{pascal} record", validate_input)
        .with_scope("#{snake}:write")
        .with_min_role(Orgs.Member)
        .with_live_topics(["resource:#{snake}"])
        .with_reload_props(["#{snake}_list"])
    end

    fn save_record(
      files: Files,
      db_path: Text,
      rng: SecureRandom,
      clock: Clock,
      input: #{pascal}Input
    ) : Result(#{pascal}Record, Text)
      now = clock.now
      rec = #{pascal}Record(
        id: "#{snake}_\#{rng.bytes(8).to_hex}",
    #{assigns},
        created_at: now
      )
      tbl = #{snake}_table()
      Modb.with_exclusive_lock(files, db_path, fn(e) e.to_text end, fn(s)
        tx = Modb.begin_write(s)
        tx1 = try Table.put(tx, tbl, rec.id, rec).map_error(fn(e) e.to_text end)
        _next = try Modb.commit(tx1).map_error(fn(e) e.to_text end)
        Ok(rec)
      end)
    end

    fn list_records(rf: ReadFiles, db_path: Text) : Result(List(#{pascal}Record), Text)
      return Ok([]) if not rf.exists?(db_path)
      Modb.with_shared_lock(rf, db_path, fn(e) e.to_text end, fn(s)
        rows = try Table.all(s, #{snake}_table()).map_error(fn(e) e.to_text end)
        Ok(rows.map(fn(p) p.1 end))
      end)
    end
    """
  else
    """
    ## Generated SQLite resource module for `#{pascal}` (`#{snake}` table + `Arvo.Action`).
    module #{pascal}
    expose #{pascal}Record(..),
    #{pascal}Input(..),
    schema_sql,
    init_schema,
    validate_input,
    create_action
    use Arvo.Action
    use Arvo.Changeset
    use Arvo.Orgs

    struct #{pascal}Record
      id: Text
    #{fields_mo}
      created_at: Text
    end

    struct #{pascal}Input
    #{fields_mo}
    end

    fn schema_sql() : Text
      "CREATE TABLE IF NOT EXISTS #{snake} (id TEXT PRIMARY KEY, payload_json TEXT NOT NULL, created_at TEXT NOT NULL) STRICT"
    end

    fn init_schema(db: Sqlite.Database) : Result(Unit, SqliteError)
      db.run(schema_sql(), [])
    end

    fn validate_input(input: #{pascal}Input) : Changeset.Changeset(#{pascal}Input)
      Changeset.new(input)#{checks}
    end

    fn create_action() : Action.ActionSpec(#{pascal}Input)
      Action.define("#{snake}.create", "Create #{pascal} record", validate_input)
        .with_scope("#{snake}:write")
        .with_min_role(Orgs.Member)
        .with_live_topics(["resource:#{snake}"])
        .with_reload_props(["#{snake}_list"])
    end
    """
  end
end

fn render_resource_tsx(g: GenArgs) : Text
  pascal = to_pascal(g.name)
  snake = to_snake(g.name)
  props_fields = g.fields.map(fn(f) "  #{f.name}: #{f.ts_type};" end).join("\n")
  first_field = (g.fields.first.map(fn(f) f.name end)) or "id"
  """
  import type { ReactElement } from "react";

  export interface #{pascal}Item {
    id: string;
  #{props_fields}
  }

  export interface #{pascal}IndexProps {
    items: #{pascal}Item[];
  }

  export default function #{pascal}Index({ items }: #{pascal}IndexProps): ReactElement {
    return (
      <main className="mx-auto max-w-2xl space-y-4 p-6 text-slate-900">
        <header>
          <h1 className="text-2xl font-semibold">#{pascal}s</h1>
          <p className="text-sm text-slate-600">{items.length} #{snake} records</p>
        </header>
        <ul className="divide-y rounded border border-slate-300">
          {items.map((item) => (
            <li key={item.id} className="flex items-center justify-between p-3 text-sm">
              <span>{String(item.#{first_field})}</span>
              <span className="font-mono text-xs text-slate-500">{item.id}</span>
            </li>
          ))}
        </ul>
      </main>
    );
  }
  """
end

fn render_resource_feature(g: GenArgs) : Text
  pascal = to_pascal(g.name)
  kebab = to_kebab(g.name)
  """
  # #{pascal} management

  Signed-in members can create and list #{pascal} records with Changeset validation and Policy governance.

  ## Sub-features

  - `#{kebab}-create`: validates input fields before persisting.
  - `#{kebab}-list`: lists persisted #{pascal} records cleanly.

  ## How to get to it (user POV)

  - Sign in at `/login` and visit `/#{kebab}`.

  ## Scenarios

  ```gherkin
  Feature: #{pascal} management
    @smoke
    Scenario: Authenticated member views #{pascal} list
      Given I visit "/#{kebab}"
      Then the Inertia component is "#{pascal}Index"
  ```

  ## Gotchas

  - Never bypass `Action.authorize` when invoking resource mutations over HTTP or MCP.
  """
end

fn render_auth_mo(g: GenArgs) : Text
  pascal = to_pascal(g.name)
  if g.db == "modb"
    """
    ## Generated Auth v2 helper module (`#{pascal}Auth`) backed by `Arvo.Modb.AuthStore` + `Arvo.Modb.Sessions`.
    module #{pascal}Auth
    expose build_flow_config, register_member, authenticate_member
    use Arvo.Auth
    use Arvo.AuthKit
    use Arvo.Modb.AuthStore

    fn build_flow_config(app_name: Text, base_url: Text, from_email: Text, secure?: Bool) : AuthKit.AuthFlowConfig
      AuthKit.default_flow_config(app_name, base_url, from_email, secure?)
    end

    fn register_member(
      files: Files,
      db_path: Text,
      rng: SecureRandom,
      clock: Clock,
      cfg: AuthKit.AuthFlowConfig,
      email: Text,
      password: Text,
      display_name: Option(Text)
    ) : Result((Auth.User, Text), AuthStore.AuthError)
      user = try AuthStore.create_user_with_password(
        files,
        db_path,
        rng,
        clock,
        email,
        password,
        cfg.password_policy,
        display_name,
        false
      )
      issued = try AuthStore.issue_and_store_token(
        files,
        db_path,
        rng,
        clock,
        Some(user.id),
        Auth.EmailVerify,
        user.email,
        86400
      )
      msg = AuthKit.build_verification_email(cfg, user.email, issued.raw_token)
      _ = msg
      Ok((user, issued.raw_token))
    end

    fn authenticate_member(
      files: Files,
      db_path: Text,
      clock: Clock,
      email: Text,
      password: Text
    ) : Result(Option(Auth.User), AuthStore.AuthError)
      AuthStore.authenticate_password(files, db_path, clock, email, password)
    end
    """
  else
    """
    ## Generated Auth v2 helper module (`#{pascal}Auth`) backed by `Arvo.Sqlite.AuthStore` + `Arvo.Sqlite.Sessions`.
    module #{pascal}Auth
    expose build_flow_config, register_member, authenticate_member
    use Arvo.Auth
    use Arvo.AuthKit
    use Arvo.Sqlite.AuthStore

    fn build_flow_config(app_name: Text, base_url: Text, from_email: Text, secure?: Bool) : AuthKit.AuthFlowConfig
      AuthKit.default_flow_config(app_name, base_url, from_email, secure?)
    end

    fn register_member(
      db: Sqlite.Database,
      rng: SecureRandom,
      clock: Clock,
      cfg: AuthKit.AuthFlowConfig,
      email: Text,
      password: Text,
      display_name: Option(Text)
    ) : Result((Auth.User, Text), AuthStore.AuthStoreError)
      user = try AuthStore.create_user_with_password(
        db,
        rng,
        clock,
        email,
        password,
        cfg.password_policy,
        display_name,
        false
      )
      issued = try AuthStore.issue_and_store_token(
        db,
        rng,
        clock,
        Some(user.id),
        Auth.EmailVerify,
        user.email,
        86400
      )
      Ok((user, issued.raw_token))
    end

    fn authenticate_member(db: Sqlite.Database, email: Text, password: Text) : Result(
      Option(Auth.User),
      AuthStore.AuthStoreError
    )
      AuthStore.authenticate_password(db, email, password)
    end
    """
  end
end

fn render_page_mo(g: GenArgs) : Text
  pascal = to_pascal(g.name)
  kebab = to_kebab(g.name)
  fields = if g.fields.empty?
    "  heading: Text"
  else
    render_struct_fields(g.fields, "  ")
  end
  """
  ## Generated Inertia v2 page contract module for `#{pascal}`.
  module #{pascal}Page
  expose #{pascal}Props(..), contract
  use Arvo.Inertia

  struct #{pascal}Props
  #{fields}
  end

  fn contract(shared: Inertia.SchemaTag(S)) : Inertia.PageContract
    where S: Json
    Inertia.page_contract[#{pascal}Props, S]("#{pascal}", ["/#{kebab}"], Inertia.Of, shared)
  end
  """
end

fn render_page_tsx(g: GenArgs) : Text
  pascal = to_pascal(g.name)
  """
  import type { ReactElement } from "react";

  export interface #{pascal}Props {
    heading?: string;
  }

  export default function #{pascal}(props: #{pascal}Props): ReactElement {
    return (
      <main className="mx-auto max-w-2xl p-6 text-slate-900">
        <h1 className="text-2xl font-semibold">{props.heading ?? "#{pascal}"}</h1>
      </main>
    );
  }
  """
end

fn render_job_mo(g: GenArgs) : Text
  pascal = to_pascal(g.name)
  snake = to_snake(g.name)
  fields = if g.fields.empty?
    "  target_id: Text"
  else
    render_struct_fields(g.fields, "  ")
  end
  if g.db == "modb"
    """
    ## Generated MoDB background job module for `Jobs.#{pascal}`.
    module Jobs.#{pascal}
    expose #{pascal}Payload(..), job_name, enqueue, drain
    use Arvo.Modb.Jobs

    job_name = "app.#{snake}"

    struct #{pascal}Payload
    #{fields}
    end

    fn enqueue(
      files: Files,
      db_path: Text,
      rng: SecureRandom,
      clock: Clock,
      payload: #{pascal}Payload
    ) : Result(Text, Text)
      Jobs.enqueue(files, db_path, rng, clock, job_name, payload.to_json).map_error(
        fn(e) e.to_text end
      )
    end

    fn drain(files: Files, db_path: Text, clock: Clock) : Result(Int, Text)
      var count = 0
      var more? = true
      while more?
        claimed = try Jobs.claim_next(files, db_path, clock, [job_name]).map_error(
          fn(e) e.to_text end
        )
        case claimed
          None: more? = false
          Some(job):
            try Jobs.complete(files, db_path, clock, job.id, job.attempts).map_error(
              fn(e) e.to_text end
            )
            count += 1
        end
      end
      Ok(count)
    end
    """
  else
    """
    ## Generated SQLite background job module for `Jobs.#{pascal}`.
    module Jobs.#{pascal}
    expose #{pascal}Payload(..), job_name, enqueue, drain
    use Arvo.Sqlite.Jobs

    job_name = "app.#{snake}"

    struct #{pascal}Payload
    #{fields}
    end

    fn enqueue(
      db: Sqlite.Database,
      rng: SecureRandom,
      clock: Clock,
      payload: #{pascal}Payload
    ) : Result(Text, Text)
      Jobs.enqueue(db, rng, clock, job_name, payload.to_json).map_error(fn(e) "\#{e}" end)
    end

    fn drain(db: Sqlite.Database, clock: Clock) : Result(Int, Text)
      var count = 0
      var more? = true
      while more?
        claimed = try Jobs.claim_next(db, clock, [job_name]).map_error(fn(e) "\#{e}" end)
        case claimed
          None: more? = false
          Some(job):
            try Jobs.complete(db, clock, job.id).map_error(fn(e) "\#{e}" end)
            count += 1
        end
      end
      Ok(count)
    end
    """
  end
end

fn render_mcp_tool_mo(g: GenArgs) : Text
  pascal = to_pascal(g.name)
  snake = to_snake(g.name)
  fields_mo = render_struct_fields(g.fields, "  ")
  checks = changeset_checks(g.fields)
  """
  ## Generated unified `Arvo.Action` + MCP tool module for `Actions.#{pascal}`.
  module Actions.#{pascal}
  expose #{pascal}Input(..), #{pascal}Output(..), validate_input, spec, to_mcp_tool, prepare_mcp
  use Arvo.Action
  use Arvo.Changeset
  use Arvo.Mcp
  use Json

  struct #{pascal}Input
  #{fields_mo}
  end

  struct #{pascal}Output
    ok?: Bool
    action: Text
  end

  fn validate_input(input: #{pascal}Input) : Changeset.Changeset(#{pascal}Input)
    Changeset.new(input)#{checks}
  end

  fn spec() : Action.ActionSpec(#{pascal}Input)
    Action.define("#{snake}", "Execute #{pascal} action", validate_input)
      .with_scope("#{snake}:write")
  end

  fn to_mcp_tool() : Mcp.ToolDef
    Action.to_mcp_tool(spec())
  end

  fn prepare_mcp(ctx: Action.ActionContext, raw_args: Json) : Result(
    Action.ActionPrepared(#{pascal}Input),
    Action.ActionError
  )
    Action.prepare_json(spec(), ctx, raw_args)
  end
  """
end

## Returns deterministic `(relative_path, content)` file pairs for `g`.
fn plan_files(g: GenArgs) : List((Text, Text))
  kebab = to_kebab(g.name)
  pascal = to_pascal(g.name)
  case g.kind
    ResourceKind: [
      ("lib/#{kebab}.mo", render_resource_mo(g)),
      ("frontend/src/pages/#{pascal}Index.tsx", render_resource_tsx(g)),
      ("specs/features/#{kebab}.feature.md", render_resource_feature(g))
    ]
    AuthKind: [("lib/#{kebab}-auth.mo", render_auth_mo(g))]
    PageKind: [
      ("lib/#{kebab}-page.mo", render_page_mo(g)),
      ("frontend/src/pages/#{pascal}.tsx", render_page_tsx(g))
    ]
    JobKind: [("lib/jobs/#{kebab}.mo", render_job_mo(g))]
    McpToolKind: [("lib/actions/#{kebab}.mo", render_mcp_tool_mo(g))]
  end
end

fn parent_dir(path: Text) : Text
  parts = path.split("/")
  if parts.size <= 1: "." else: parts.take(parts.size - 1).join("/")
end

## Executes `arvo gen` against `app_files`.
fn run_gen(gargs: GenArgs, app_files: Files, console: Console) : Int
  if gargs.help?
    console.print(gen_usage())
    return 0
  end

  planned = plan_files(gargs)
  if gargs.dry_run?
    out = Json.Object({
      "dry_run": Json.Boolean(true),
      "files": Json.Array(planned.map(fn(p) Json.String(p.0) end))
    })
    console.print(out.to_text)
    return 0
  end

  if not gargs.force?
    for (rel, _content) in planned
      if app_files.read_only.exists?(rel)
        console.error("arvo gen: '#{rel}' already exists (pass --force to overwrite)")
        return 1
      end
    end
  end

  for (rel, content) in planned
    pdir = parent_dir(rel)
    if pdir != "."
      if app_files.make_folder(pdir) is Error(e)
        console.error("arvo gen: failed creating directory '#{pdir}': #{e}")
        return 1
      end
    end
    if app_files.write_text(rel, content) is Error(e)
      console.error("arvo gen: failed writing '#{rel}': #{e}")
      return 1
    end
    console.print("  wrote #{rel}")
  end
  0
end

test "GenCmd parses all 5 generator kinds, validates fields, checks collisions, and generates Mo + TSX"
  assert parse_gen_args(["--help"]) is Ok(h) and h.help?
  assert parse_gen_args(["unknown", "Foo"]) is Error(_)
  assert parse_gen_args(["resource", "../bad"]) is Error(_)
  assert parse_gen_args(["resource", "Invoice", "BadField:Text"]) is Error(_)
  assert parse_gen_args(["resource", "Invoice", "x:BadType"]) is Error(_)
  assert parse_gen_args(["resource", "Invoice", "--db", "bad"]) is Error(_)

  assert to_pascal("pay-invoice") == "PayInvoice"
  assert to_snake("PayInvoice") == "pay_invoice"
  assert to_kebab("PayInvoice") == "pay-invoice"

  files = Files.in_memory({})
  assert parse_gen_args(["resource", "Invoice", "title:Text", "amount_cents:Int", "--db", "modb"]) is
    Ok(res_args)
  assert run_gen(res_args, files, Console.fake()) == 0
  assert files.exists?("lib/invoice.mo")
  assert files.exists?("frontend/src/pages/InvoiceIndex.tsx")
  assert files.exists?("specs/features/invoice.feature.md")

  # Refuses overwrite without --force
  assert run_gen(res_args, files, Console.fake()) == 1

  # --dry-run does not touch disk or fail on existing
  assert parse_gen_args(["mcp-tool", "PayInvoice", "invoice_id:Int", "--dry-run"]) is Ok(dry_args)
  c_dry = Console.fake()
  assert run_gen(dry_args, files, c_dry) == 0
  assert (c_dry.printed.first or "").contains?("lib/actions/pay-invoice.mo")
  assert not files.exists?("lib/actions/pay-invoice.mo")

  for raw in [
    ["auth", "MemberAccount", "--db", "sqlite"],
    ["page", "BillingSettings", "plan:Text"],
    ["job", "SendDigest", "user_id:Text", "--db", "modb"],
    ["job", "PruneAudit", "days:Int", "--db", "sqlite"],
    ["mcp-tool", "PayInvoice", "invoice_id:Int"]
  ]
    assert parse_gen_args(raw) is Ok(ga)
    assert run_gen(ga, files, Console.fake()) == 0
  end
  assert files.exists?("lib/member-account-auth.mo")
  assert files.exists?("lib/billing-settings-page.mo")
  assert files.exists?("frontend/src/pages/BillingSettings.tsx")
  assert files.exists?("lib/jobs/send-digest.mo")
  assert files.exists?("lib/jobs/prune-audit.mo")
  assert files.exists?("lib/actions/pay-invoice.mo")
end
