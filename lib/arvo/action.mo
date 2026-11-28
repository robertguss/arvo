## Unified Human + Agent Action Engine (`Arvo.Action`): define a typed action once
## with `Json.schema[I]()`, `Arvo.Changeset` validation, `Arvo.Policy` governance
## (auth, bearer scope, org role, MFA, sudo), automatic `Arvo.Live` Inertia reload
## signaling, and project it identically to Inertia forms, JSON APIs, OpenAPI, and MCP.
## Pure Mo and storage-agnostic (`E0091`-safe zero-closure-capture design).
module Arvo.Action
expose ActionSpec(..),
ActionContext(..),
ActionError(..),
ActionPrepared(..),
define,
context_for_member,
guest_context,
with_scope,
with_min_role,
with_sudo,
with_mfa,
with_read_only,
with_rate_limit,
with_audit_action,
with_live_topics,
with_reload_props,
to_mcp_tool,
to_openapi_operation,
authorize,
prepare_input,
prepare_json,
error_to_text,
inertia_success,
inertia_error,
json_success,
json_error,
mcp_success,
mcp_error
use Api
use Arvo.Changeset
use Arvo.Inertia
use Arvo.Keyring
use Arvo.Live
use Arvo.Mcp
use Arvo.Orgs
use Arvo.Policy
use Arvo.RateLimit
use Arvo.Security
use Arvo.Sse
use Arvo.Web
use Json

## Declarative specification shared by Inertia handlers, JSON endpoints, OpenAPI, and MCP tools.
struct ActionSpec(I)
  name: Text
  description: Text
  input_schema: Json
  required_scope: Option(Text)
  min_role: Option(Orgs.OrgRole)
  require_sudo_max_age_seconds: Option(Int)
  require_mfa?: Bool
  read_only?: Bool
  rate_limit: Option((Text, RateLimit.LimitRule))
  audit_action: Option(Text)
  live_topics: List(Text)
  reload_props: List(Text)
  validate: fn(I) : Changeset.Changeset(I)
end

## Request-scoped security principal and timestamps evaluated by `authorize` and `prepare_*`.
struct ActionContext
  authenticated?: Bool
  actor_id: Text
  actor_email: Option(Text)
  actor_role: Option(Orgs.OrgRole)
  granted_scopes: List(Text)
  mfa_verified_at: Option(Time)
  reauthenticated_at: Option(Time)
  now: Time
end

## Unified authorization, decoding, throttling, or Changeset validation failure.
enum ActionError
  Unauthenticated
  Forbidden(reason: Text)
  RateLimited(retry_after_seconds: Int)
  ValidationFailed(errors: Map(Text, List(Text)))
  InvalidInput(message: Text)
end

## Validated and authorized action payload plus audit/live metadata passed to the route handler.
struct ActionPrepared(I)
  input: I
  audit_action: Text
  live_topics: List(Text)
  reload_props: List(Text)
end

## Defines a typed `ActionSpec(I)` with compiler-derived `Json.schema[I]()` and `validate`.
fn define(name: Text, description: Text, validate: fn(I) : Changeset.Changeset(I)) : ActionSpec(I)
  where I: Json
  clean_name = name.trim
  audit_name = if clean_name.empty?: None else: Some(clean_name)
  ActionSpec(
    name: clean_name,
    description: description.trim,
    input_schema: Json.schema[I](),
    required_scope: None,
    min_role: None,
    require_sudo_max_age_seconds: None,
    require_mfa?: false,
    read_only?: false,
    rate_limit: None,
    audit_action: audit_name,
    live_topics: [],
    reload_props: [],
    validate: validate
  )
end

## Constructs an authenticated `ActionContext` for a signed-in user or scoped agent token.
fn context_for_member(
  actor_id: Text,
  actor_email: Option(Text),
  actor_role: Option(Orgs.OrgRole),
  granted_scopes: List(Text),
  mfa_verified_at: Option(Time),
  reauthenticated_at: Option(Time),
  now: Time
) : ActionContext
  clean_id = actor_id.trim
  ActionContext(
    authenticated?: not clean_id.empty?,
    actor_id: clean_id,
    actor_email: actor_email,
    actor_role: actor_role,
    granted_scopes: granted_scopes,
    mfa_verified_at: mfa_verified_at,
    reauthenticated_at: reauthenticated_at,
    now: now
  )
end

## Constructs an unauthenticated guest `ActionContext`.
fn guest_context(now: Time) : ActionContext
  ActionContext(
    authenticated?: false,
    actor_id: "",
    actor_email: None,
    actor_role: None,
    granted_scopes: [],
    mfa_verified_at: None,
    reauthenticated_at: None,
    now: now
  )
end

## Requires callers (especially API/agent tokens) to hold `scope`.
fn with_scope(spec: ActionSpec(I), scope: Text) : ActionSpec(I)
  var next = spec
  clean = scope.trim
  next.required_scope = if clean.empty?: Some("") else: Some(clean)
  next
end

## Requires an organization membership role at least as privileged as `role`.
fn with_min_role(spec: ActionSpec(I), role: Orgs.OrgRole) : ActionSpec(I)
  var next = spec
  next.min_role = Some(role)
  next
end

## Requires recent interactive step-up authentication within `max_age_seconds`.
fn with_sudo(spec: ActionSpec(I), max_age_seconds: Int) : ActionSpec(I)
  var next = spec
  next.require_sudo_max_age_seconds = Some(max_age_seconds)
  next
end

## Requires an MFA-verified session (`mfa_verified_at` present).
fn with_mfa(spec: ActionSpec(I), required?: Bool) : ActionSpec(I)
  var next = spec
  next.require_mfa? = required?
  next
end

## Marks the action read-only (propagated to MCP `readOnlyHint` and OpenAPI metadata).
fn with_read_only(spec: ActionSpec(I), read_only?: Bool) : ActionSpec(I)
  var next = spec
  next.read_only? = read_only?
  next
end

## Attaches a named rate-limit rule (`key_prefix`, `rule`) to the action metadata.
fn with_rate_limit(spec: ActionSpec(I), key_prefix: Text, rule: RateLimit.LimitRule) : ActionSpec(I)
  var next = spec
  next.rate_limit = Some((key_prefix.trim, rule))
  next
end

## Overrides the default audit action name recorded when persisting mutations.
fn with_audit_action(spec: ActionSpec(I), action_name: Text) : ActionSpec(I)
  var next = spec
  clean = action_name.trim
  next.audit_action = if clean.empty?: None else: Some(clean)
  next
end

## Sets default `Arvo.Live` SSE topics invalidated when the action succeeds.
fn with_live_topics(spec: ActionSpec(I), topics: List(Text)) : ActionSpec(I)
  var next = spec
  next.live_topics = topics
  next
end

## Sets Inertia prop keys signaled for partial reload (`inertia.reload`) on mutation success.
fn with_reload_props(spec: ActionSpec(I), props: List(Text)) : ActionSpec(I)
  var next = spec
  next.reload_props = props
  next
end

## Projects `spec` into an `Arvo.Mcp.ToolDef` preserving schema and `readOnlyHint`.
fn to_mcp_tool(spec: ActionSpec(I)) : Mcp.ToolDef
  Mcp.ToolDef(
    name: spec.name,
    description: spec.description,
    input_schema: spec.input_schema,
    read_only?: spec.read_only?
  )
end

## Projects `spec` into an OpenAPI 3.1 operation object JSON value.
fn to_openapi_operation(spec: ActionSpec(I), method: Text, path: Text) : Json
  var op = {
    "operationId": Json.String(spec.name),
    "summary": Json.String(spec.description),
    "method": Json.String(method.trim.ascii_uppercase),
    "path": Json.String(path.trim),
    "requestBody": Json.Object({
      "required": Json.Boolean(true),
      "content": Json.Object({"application/json": Json.Object({"schema": spec.input_schema})})
    }),
    "x-arvo-read-only": Json.Boolean(spec.read_only?)
  }
  if spec.required_scope is Some(sc)
    op = op.set("x-arvo-scope", Json.String(sc))
  end
  if spec.require_sudo_max_age_seconds is Some(win)
    op = op.set("x-arvo-sudo-seconds", Json.int(win))
  end
  if spec.require_mfa?
    op = op.set("x-arvo-mfa", Json.Boolean(true))
  end
  Json.Object(op)
end

fn check_policy_gates(
  required_scope: Option(Text),
  min_role: Option(Orgs.OrgRole),
  require_sudo_max_age_seconds: Option(Int),
  require_mfa?: Bool,
  ctx: ActionContext
) : Policy.Decision
  promise "unauthenticated context or missing required MFA always denies"
    (not ctx.authenticated? or (require_mfa? and ctx.mfa_verified_at is None)) implies
      not Policy.allowed?(result)
  end

  var rules = [Policy.require_authenticated(ctx.authenticated?)]
  if required_scope is Some(scope)
    rules = rules.append(Policy.require_scope(ctx.granted_scopes, scope))
  end
  if min_role is Some(role)
    rules = rules.append(Policy.require_role(ctx.actor_role, role))
  end
  if require_mfa?
    rules = rules.append(Policy.require_mfa(ctx.mfa_verified_at))
  end
  if require_sudo_max_age_seconds is Some(max_age)
    rules = rules.append(Policy.require_sudo(ctx.reauthenticated_at, ctx.now, max_age))
  end
  Policy.all_of(rules)
end

## Evaluates all declarative authorization gates on `spec` against `ctx` (fail-closed).
fn authorize(spec: ActionSpec(I), ctx: ActionContext) : Policy.Decision
  check_policy_gates(
    spec.required_scope,
    spec.min_role,
    spec.require_sudo_max_age_seconds,
    spec.require_mfa?,
    ctx
  )
end

fn authorize_to_error(spec: ActionSpec(I), ctx: ActionContext) : Option(ActionError)
  return Some(Unauthenticated) if not ctx.authenticated?
  case authorize(spec, ctx)
    Policy.Allow: None
    Policy.Deny(reason: r): Some(Forbidden(reason: r))
  end
end

fn make_prepared(spec: ActionSpec(I), input: I) : ActionPrepared(I)
  audit_name = spec.audit_action or spec.name
  ActionPrepared(
    input: input,
    audit_action: audit_name,
    live_topics: spec.live_topics,
    reload_props: spec.reload_props
  )
end

## Authorizes `ctx` and validates pre-decoded typed `input` through `spec.validate`.
fn prepare_input(spec: ActionSpec(I), ctx: ActionContext, input: I) : Result(
  ActionPrepared(I),
  ActionError
)
  if authorize_to_error(spec, ctx) is Some(err)
    return Error(err)
  end
  cs = spec.validate(input)
  if Changeset.valid?(cs)
    Ok(make_prepared(spec, cs.data))
  else
    Error(ValidationFailed(errors: cs.errors))
  end
end

## Authorizes `ctx` FIRST (fail closed), then decodes strict JSON into `I` and validates via `spec.validate`.
fn prepare_json(spec: ActionSpec(I), ctx: ActionContext, raw_input: Json) : Result(
  ActionPrepared(I),
  ActionError
)
  where I: Json
  if authorize_to_error(spec, ctx) is Some(err)
    return Error(err)
  end
  decoded = case Json.decode_strict[I](raw_input.to_text)
    Ok(v): v
    Error(de): return Error(InvalidInput(message: "invalid action input: #{de.to_text}"))
  end
  cs = spec.validate(decoded)
  if Changeset.valid?(cs)
    Ok(make_prepared(spec, cs.data))
  else
    Error(ValidationFailed(errors: cs.errors))
  end
end

fn first_error_summary(errs: Map(Text, List(Text))) : Text
  var parts = []
  for (field, msgs) in errs.entries
    first = msgs.first or "invalid"
    parts = parts.append("#{field}: #{first}")
  end
  if parts.empty?: "validation failed" else: parts.join("; ")
end

## Formats an `ActionError` into a human-readable diagnostic message.
fn error_to_text(err: ActionError) : Text
  case err
    Unauthenticated: "authentication_required"
    Forbidden(reason: r): r
    RateLimited(retry_after_seconds: s): "rate_limited (retry after #{s}s)"
    ValidationFailed(errors: errs): first_error_summary(errs)
    InvalidInput(message: msg): msg
  end
end

fn merged_topics(spec: ActionSpec(I), extra_topics: List(Text)) : List(Text)
  var out = []
  for t in spec.live_topics.concat(extra_topics)
    c = t.trim
    if not c.empty? and not out.contains?(c)
      out = out.append(c)
    end
  end
  out
end

fn attach_live(res: Api.Response, spec: ActionSpec(I), extra_topics: List(Text)) : Api.Response
  topics = merged_topics(spec, extra_topics)
  if topics.empty? or spec.reload_props.empty?
    res
  else
    reason = spec.audit_action or spec.name
    Live.invalidate_inertia(
      res,
      topics,
      spec.reload_props,
      if reason.empty?: None else: Some(reason)
    )
  end
end

## Shapes a successful Inertia action result into a `303 See Other` flash redirect plus SSE reload signal.
fn inertia_success(
  spec: ActionSpec(I),
  target: Text,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  cfg: Web.WebConfig,
  notice: Text,
  extra_topics: List(Text)
) : Api.Response
  redir = Web.redirect_with_notice(target, rng, keyring, cfg, notice)
  attach_live(redir, spec, extra_topics)
end

## Shapes an `ActionError` for Inertia browser form submissions (`303` to `login_path` or `fallback`).
fn inertia_error(
  err: ActionError,
  _req: Api.Request,
  rng: SecureRandom,
  keyring: Keyring.Keyring,
  cfg: Web.WebConfig,
  fallback: Text,
  login_path: Text
) : Api.Response
  case err
    Unauthenticated: Web.redirect_with_alert(
      login_path,
      rng,
      keyring,
      cfg,
      "Please sign in to continue"
    )
    Forbidden(reason: r): Web.redirect_with_alert(fallback, rng, keyring, cfg, r)
    RateLimited(retry_after_seconds: s): Web.redirect_with_alert(
      fallback,
      rng,
      keyring,
      cfg,
      "Too many requests; retry in #{s}s"
    )
    ValidationFailed(errors: errs): Web.redirect_with_errors(fallback, rng, keyring, cfg, errs)
    InvalidInput(message: m): Web.redirect_with_alert(fallback, rng, keyring, cfg, m)
  end
end

## Shapes a successful JSON API action result with security headers, `no-store`, and SSE reload signal.
fn json_success(
  spec: ActionSpec(I),
  status: Int,
  data: O,
  cfg: Web.WebConfig,
  extra_topics: List(Text)
) : Api.Response
  where O: Json
  base = if status == 201
    Web.json_created(data, cfg)
  else if status == 200
    Web.json_ok(data, cfg)
  else
    Security.apply_headers(
      Api.encoded_json_response(status, data.to_json).with_header("Cache-Control", "no-store"),
      cfg.headers
    )
  end
  attach_live(base, spec, extra_topics)
end

## Shapes an `ActionError` into a standard HTTP JSON error response (`401`/`403`/`429`/`422`/`400`).
fn json_error(err: ActionError, cfg: Web.WebConfig) : Api.Response
  case err
    Unauthenticated: Web.json_error(401, "unauthenticated", "Authentication required", cfg)
    Forbidden(reason: r): Web.json_error(403, "forbidden", r, cfg)
    RateLimited(retry_after_seconds: s): Web.json_error(
      429,
      "rate_limited",
      "Too many requests; retry in #{s}s",
      cfg
    ).with_header("Retry-After", "#{s}")
    ValidationFailed(errors: errs):
      body = Json.Object({
        "error": Json.String("validation_failed"),
        "message": Json.String(first_error_summary(errs)),
        "errors": Changeset.error_map_json(errs)
      })
      Security.apply_headers(
        Api.encoded_json_response(422, body).with_header("Cache-Control", "no-store"),
        cfg.headers
      )
    InvalidInput(message: m): Web.json_error(400, "invalid_input", m, cfg)
  end
end

## Shapes a successful MCP `tools/call` response carrying structured JSON + SSE live reload signal.
fn mcp_success(
  spec: ActionSpec(I),
  id: Mcp.RpcId,
  summary_text: Text,
  structured: O,
  extra_topics: List(Text)
) : Api.Response
  where O: Json
  res = Mcp.tool_ok(id, summary_text, Some(structured.to_json))
  attach_live(res, spec, extra_topics)
end

## Shapes an `ActionError` into an MCP tool-level JSON-RPC `isError: true` response.
fn mcp_error(id: Mcp.RpcId, err: ActionError) : Api.Response
  Mcp.tool_error(id, error_to_text(err))
end

struct DemoPayInput
  bill_id: Int
  amount_cents: Int
  note: Option(Text)
end

struct DemoPayOutput
  bill_id: Int
  status: Text
end

fn validate_demo_pay(i: DemoPayInput) : Changeset.Changeset(DemoPayInput)
  Changeset.new(i).require_positive_int("bill_id", i.bill_id).require_positive_int(
    "amount_cents",
    i.amount_cents
  )
end

test "Arvo.Action defines unified schema, enforces Policy gates fail-closed, and shapes Inertia/JSON/MCP + Live"
  t0 = Time.parse("2026-11-28T00:00:00Z") or stop "t0"
  rng = SecureRandom.seeded(101)
  kr = case Keyring.single("v1", rng.bytes(32))
    Ok(k): k
    Error(_): stop "keyring"
  end
  cfg = Web.default_config(
    Inertia.dev_config("App", "http://127.0.0.1:5173", "src/main.tsx", ""),
    false
  )

  spec = define("bills.pay", "Mark a bill paid", validate_demo_pay).with_scope("bills:write")
    .with_min_role(Orgs.Member).with_mfa(true).with_sudo(900).with_live_topics(["org:org_1"])
    .with_reload_props(["bills", "total_due_cents"])

  mcp_def = to_mcp_tool(spec)
  assert mcp_def.name == "bills.pay"
  assert not mcp_def.read_only?
  assert mcp_def.input_schema.path("properties.amount_cents") != None

  oa = to_openapi_operation(spec, "post", "/bills/pay")
  assert oa.text_at("operationId") == Some("bills.pay")
  assert oa.text_at("method") == Some("POST")
  assert oa.text_at("x-arvo-scope") == Some("bills:write")
  assert oa.int_at("x-arvo-sudo-seconds") == Some(900)

  # Fail closed on guest, missing scope, insufficient role, missing MFA, expired sudo
  assert prepare_input(
    spec,
    guest_context(t0),
    DemoPayInput(bill_id: 1, amount_cents: 500, note: None)
  ) ==
    Error(Unauthenticated)

  bad_scope_ctx = context_for_member(
    "u1",
    Some("ada@example.com"),
    Some(Orgs.Admin),
    ["bills:read"],
    Some(t0),
    Some(t0),
    t0 + 60.seconds
  )
  assert prepare_json(spec, bad_scope_ctx, Json.Object({"bad": Json.Boolean(true)})) ==
    Error(Forbidden(reason: "missing_scope:bills:write"))

  no_mfa_ctx = context_for_member(
    "u1",
    None,
    Some(Orgs.Member),
    ["bills:*"],
    None,
    Some(t0),
    t0 + 60.seconds
  )
  assert authorize(spec, no_mfa_ctx) == Policy.Deny(reason: "mfa_required")

  expired_sudo_ctx = context_for_member(
    "u1",
    None,
    Some(Orgs.Member),
    ["bills:*"],
    Some(t0),
    Some(t0),
    t0 + 900.seconds
  )
  assert authorize(spec, expired_sudo_ctx) == Policy.Deny(reason: "sudo_reauth_required")

  good_ctx = context_for_member(
    "u1",
    Some("ada@example.com"),
    Some(Orgs.Admin),
    ["bills:*"],
    Some(t0),
    Some(t0 + 30.seconds),
    t0 + 120.seconds
  )
  assert prepare_json(
    spec,
    good_ctx,
    Json.Object({"bill_id": Json.int(0), "amount_cents": Json.int(-5)})
  ) is
    Error(ValidationFailed(errors: _))

  prep = case prepare_json(
    spec,
    good_ctx,
    Json.Object({"bill_id": Json.int(7), "amount_cents": Json.int(4200)})
  )
    Ok(p): p
    Error(_): stop "expected prepared action"
  end
  assert prep.input.bill_id == 7 and prep.audit_action == "bills.pay"

  out = DemoPayOutput(bill_id: 7, status: "paid")
  i_ok = inertia_success(spec, "/bills", rng, kr, cfg, "Paid bill", ["bill:7"])
  assert i_ok.status == 303
  assert Sse.published_events(i_ok).size == 2

  j_ok = json_success(spec, 200, out, cfg, [])
  assert j_ok.status == 200 and j_ok.text.contains?("\"paid\"")
  assert Sse.published_events(j_ok).size == 1

  m_ok = mcp_success(spec, Mcp.IdInt(1), "Marked bill 7 paid", out, [])
  assert m_ok.status == 200 and m_ok.text.contains?("Marked bill 7 paid")
  assert Sse.published_events(m_ok).size == 1

  j_err = json_error(ValidationFailed(errors: {"amount_cents": ["must be greater than 0"]}), cfg)
  assert j_err.status == 422 and j_err.text.contains?("validation_failed")
  j_rl = json_error(RateLimited(retry_after_seconds: 12), cfg)
  assert j_rl.status == 429 and j_rl.header("Retry-After") == Some("12")
  assert mcp_error(Mcp.IdInt(2), Forbidden(reason: "mfa_required")).text.contains?(
    "\"isError\":true"
  )
  i_unauth = inertia_error(Unauthenticated, Api.get("/bills"), rng, kr, cfg, "/bills", "/login")
  assert i_unauth.header("Location") == Some("/login")
end
