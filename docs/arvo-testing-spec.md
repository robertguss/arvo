# Arvo Verification & Testing Technical Specification

Companion implementation spec to [arvo-testing-plan.md](arvo-testing-plan.md).  
Every Mo signature below follows Mo `0.3.0`'s actual language rules (`mo guide --reference`): explicit capability parameters, no macros, no user-defined abilities, anonymous functions cannot capture capabilities, and fakes are constructed only inside `test`, `examples`, or `promise` blocks (passed onward as capability handles).

---

## Part 1: Targeted Upstream Mo Runtime & Compiler Additions (Phase 0)

Five focused additions to `mo` unlock clean pure-Mo testing libraries and a pure-Mo `arvo` CLI without introducing framework logic into the Mo core.

### 1.1 First-Class `ApiTest.App` Handle

Today `ApiTest.send(Main, req, sql, clock, files, env, rng)` requires a static module selector and can only be invoked directly inside `test`/`examples`/`promise` blocks. Mirroring `Simulation.start(Module, at) : Simulation`, `ApiTest.start` creates an opaque test-only capability handle that helper functions can receive and drive:

```mo
## Spec-only constructor (valid only in test / examples / promise blocks).
## Synthesizes empty fakes for any capability omitted, matching ApiTest.send.
ApiTest.start(Module, ...caps) : ApiTest.App

## Route metadata exposed statically from Module's `api ... end` block.
struct ApiTest.RouteSpec
  method: Text              # "GET" | "POST" | "PUT" | "PATCH" | "DELETE"
  path_template: Text       # Flattened after enclosing `scope` blocks, e.g. "/bills/:id/pay"
  auth_mode: Text           # "none" | "optional" | "required"
  has_json_body?: Bool
  job_names: List(Text)     # Declared `job` names on the api block
end

## Operations callable from any helper holding `app: ApiTest.App`:
app.send(req: Api.Request) : Api.Response
app.run_job(name: Text, payload: Json) : Result(Unit, Text)
app.routes() : List(ApiTest.RouteSpec)
app.openapi_json() : Text
```

**Design rules:**
- `ApiTest.App` is an opaque capability (no abilities, cannot be stored in `service`/`actor` state or `main`), following `Simulation` rules exactly.
- Copies of `app` share the underlying `Sqlite`, `Clock`, `Actor`, and `SecureRandom` handles passed to `ApiTest.start`, so calling `clock.sleep(15.minutes)` advances time for subsequent `app.send` and `app.run_job` calls.

---

### 1.2 Fault-Injecting `Network.fake_scripted`

Extends Mo's static `Network.fake(peers)` with deterministic ordered response/fault sequences for simulation and retry testing:

```mo
enum Network.FakeReply
  Respond(response: Http.Response)
  Fail(error: NetworkError)         # e.g. Network.TimedOut, Network.Refused(...)
  TruncateAfter(bytes: Int)         # Simulates mid-body disconnect -> Http.BadResponse
end

struct Network.RecordedCall
  method: Text
  url: Text
  headers: List((Text, Text))
  body: Bytes
end

## Spec-only constructor: matches requests by `(method, url_prefix)` in queue order;
## the final entry repeats if exhausted unless `Exhausted` returns Network.Refused.
Network.fake_scripted(
  scripts: List((Text, Text, List(Network.FakeReply)))
) : Network

## Spec-only read-only inspector on fake Network handles:
Network.recorded_calls(net: Network) : List(Network.RecordedCall)
```

---

### 1.3 `Sqlite` Test Query Instrumentation (N+1 Budgets)

Spec-only counters attached to `Sqlite.in_memory()` / `Sqlite.fake()` connections (zero overhead on real production connections):

```mo
struct Sqlite.QueryStats
  query_count: Int
  exec_count: Int
  statements: List(Text)    # Parameterized SQL templates only (no bound secrets)
end

## Valid only inside test / examples / promise (or helpers called from them on fake DBs).
db.stats() : Sqlite.QueryStats
db.reset_stats() : Unit
```

---

### 1.4 `Command` Loopback, Supervised Processes & `mo serve` Test Flags

Today Mo's `Command.run` is synchronous and blocks network sockets on Linux via Landlock/seccomp. To let a pure-Mo `arvo` CLI spawn isolated `mo serve` servers and invoke Playwright against `127.0.0.1`:

```mo
## Narrows/configures Command to permit loopback-only TCP (127.0.0.1 / ::1) in children
## while keeping external internet access blocked by default.
command.allow_loopback() : Command

## Supervised child process handle (killed automatically when dropped if still running).
command.spawn(program: Text, args: List(Text)) : Result(Command.Process, Command.CommandError)
proc.pid : Int
proc.alive? : Bool
proc.kill() : Result(Unit, Command.CommandError)
proc.wait(within: Duration) : Result(Command.Output, Command.CommandError)
```

**Companion `mo serve` flags:**
- `--port 0` binds an ephemeral free OS port (avoiding port collisions across parallel agents).
- `--ready-file PATH` atomically writes JSON once migrations/startup finish and the listener is actually accepting connections:
  ```json
  {
    "url": "http://127.0.0.1:41983",
    "port": 41983,
    "pid": 91842,
    "data_dir": "/tmp/arvo-verify-7f3a",
    "build_sha": "sha256:...",
    "seed_profile": "baseline",
    "started_at": "2026-11-25T15:00:00Z"
  }
  ```

---

### 1.5 Parallel & NDJSON Output for `mo test --mutants` & `--strength`

- Add `--jobs N` (default `nproc`) to `mo test` for parallel mutant and `--strength` execution.
- Emit structured NDJSON events under `mo test --json --mutants` and `--strength DIR`:
  - `{"event":"mutant_killed","module":"Arvo.Jobs","fn":"backoff_seconds","line":91,"kind":"boundary","killed_by":"Arvo.Jobs.backoff_seconds.promise.1","ms":4}`
  - `{"event":"mutant_survived","module":"Routes","fn":"pay_bill","line":483,"kind":"negate","change":"=="}`
  - `{"event":"mutant_summary","total":142,"killed":141,"survived":1,"uncovered_fns":0,"kill_rate":0.993}`
  - `{"event":"strength_case","file":"strength/jobs/wrong_no_lock.mo","killed":true,"killed_by":"..."}`

---

## Part 2: Pure-Mo Arvo Testing Modules (`lib/arvo/*.mo`)

All framework testing primitives live in pure Mo under `lib/arvo/` and expose clean, composable types.

### 2.1 Typed `Arvo.Inertia` Pages & Contract Manifest

Upgrades `lib/arvo/inertia.mo` to eliminate untyped `Map(Text, Json)` prop drift (keeping `Inertia.render` backwards-compatible while making typed `render_page` the default):

```mo
module Arvo.Inertia
## Renders an Inertia v2 page from concrete `Json`-deriving page & shared prop structs.
fn render_page(
  req: Api.Request,
  cfg: InertiaConfig,
  component: Text,
  props: P,
  shared: S
) : Api.Response where P: Json, S: Json

## Contract descriptor emitted by an app's `contracts()` manifest for `arvo contracts`.
struct PageContract
  component: Text          # Must resolve to `frontend/src/pages/<component>.tsx`
  route_examples: List(Text)
  props_schema: Json       # Compiler-derived `Json.schema[P]()`
  shared_schema: Json      # Compiler-derived `Json.schema[S]()`
end

fn page_contract[P, S](component: Text, route_examples: List(Text)) : PageContract
  where P: Json, S: Json
```

Because Mo derives `Json.schema[P]()` directly from the compiler's type metadata, renaming or changing any field in a Mo `struct` immediately updates the emitted JSON Schema and breaks `arvo contracts --check` + `tsc --noEmit` before a test even runs.

---

### 2.2 `Arvo.WebTest` v2 (Fluent Stateful Browser Harness)

Replaces 350 lines of manual `ApiTest.send` / `WebTest.prepare` / `WebTest.absorb` plumbing with a concise, typed, query-budget-aware harness:

```mo
module Arvo.WebTest

struct Session
  client: Client
  last_response: Option(Api.Response)
  history: List((Api.Request, Api.Response))
end

## Core fluent flow (uses ApiTest.App once Phase 0 lands; also exposes pure
## `prepare`/`absorb` shims compatible with raw `ApiTest.send` on Mo 0.3.0).
fn start() : Session
fn with_inertia(s: Session, version: Text) : Session
fn without_inertia(s: Session) : Session
fn with_header(s: Session, name: Text, value: Text) : Session

fn get(s: Session, app: ApiTest.App, path: Text) : (Session, Api.Response)
fn post_form(s: Session, app: ApiTest.App, path: Text, fields: List((Text, Text))) : (Session, Api.Response)
fn post_json[T](s: Session, app: ApiTest.App, path: Text, body: T) : (Session, Api.Response) where T: Json
fn post_multipart(s: Session, app: ApiTest.App, path: Text, fields: List((Text, Text)), files: List(TestFile)) : (Session, Api.Response)
fn post_without_csrf(s: Session, app: ApiTest.App, path: Text, body: Bytes, content_type: Text) : (Session, Api.Response)
fn follow_redirect(s: Session, app: ApiTest.App) : (Session, Api.Response)   # Follows 3xx up to 5 hops

## Typed assertions (fail with rich context: method, path, status, body excerpt)
fn expect_status(res: Api.Response, code: Int) : Api.Response
fn expect_redirect(res: Api.Response, location: Text) : Api.Response
fn expect_inertia[P](res: Api.Response, component: Text) : P where P: Json
fn expect_flash_notice(res: Api.Response, expected: Text) : Unit
fn expect_validation_error(res: Api.Response, field: Text, contains: Text) : Unit
fn expect_max_queries(db: Sqlite.Database, max_queries: Int, label: Text) : Unit

## Exports a verified Inertia response payload as a JSON fixture for Vitest + RTL.
fn record_inertia_fixture(files: Files, name: Text, res: Api.Response) : Result(Unit, Text)
```

---

### 2.3 `Arvo.Seed` (Shared Deterministic Seed Profiles)

One single typed Mo seed registry drives `Sqlite.in_memory()` tests, `Arvo.Sim`, `arvo control launch --seed <name>`, and local development:

```mo
module Arvo.Seed

struct SeedContext
  now: Time
  seed: Int
  env_overrides: Map(Text, Text)
end

struct SeedProfile
  name: Text                     # e.g. "empty", "baseline", "overdue_bills", "multi_user"
  description: Text
  apply: fn(Sqlite.Database, SecureRandom, Clock, Env) : Result(Unit, Text)
end

fn run_profile(
  profiles: List(SeedProfile),
  name: Text,
  db: Sqlite.Database,
  rng: SecureRandom,
  clock: Clock,
  env: Env
) : Result(Unit, Text)
```

---

### 2.4 `Arvo.SecurityMatrix` (Zero-Config Adversarial Route Auditor)

Reads `app.routes()` (or `/openapi.json`) and audits **every single route fail-closed**. Newly added routes are automatically audited—forgetting to list a route in `public_routes` causes the audit to enforce authentication and CSRF by default:

```mo
module Arvo.SecurityMatrix

struct AuditConfig
  public_routes: List((Text, Text))       # Explicit allowlist: [("GET", "/login"), ("POST", "/login")]
  csrf_exempt_routes: List((Text, Text))  # Explicit allowlist (should normally be empty or signed webhooks)
  param_samples: Map(Text, Text)          # Sample valid IDs for `:param` templates, e.g. {"id": "1"}
  inertia_version: Text
  host_header: Text
  max_queries_per_get: Int                # Default N+1 guard, e.g. 10
end

enum AuditCheckKind
  UnauthAccessRejected       # Guest gets 401 or 303 -> /login on every non-public route
  CsrfMissingRejected        # Authenticated unsafe method without X-XSRF-TOKEN gets 403
  CsrfForgedRejected         # Authenticated unsafe method with wrong X-XSRF-TOKEN gets 403
  InertiaVersionConflict     # GET with X-Inertia: true + stale version gets 409 + X-Inertia-Location
  InertiaHtmlEscaped         # data-page never contains raw <script> or unescaped quotes
  OpenRedirectBlocked        # Referer: https://evil.test or //evil.test never leaks into Location
  StrictJsonRejected         # Malformed JSON or unknown fields on JSON routes return 422
  SessionRevocationHonored   # Replayed cookie after logout rejected across protected routes
  ForeignKeysEnabled         # PRAGMA foreign_keys == 1
  MigrationIdempotent        # Re-running Migrations.run returns Ok(0)
  QueryBudgetRespected       # GET routes stay within max_queries_per_get
end

struct AuditFinding
  check: AuditCheckKind
  method: Text
  path: Text
  expected: Text
  actual: Text
  repro_curl: Text
end

struct AuditReport
  routes_checked: Int
  checks_run: Int
  findings: List(AuditFinding)
end

fn run(
  app: ApiTest.App,
  db: Sqlite.Database,
  authed_session: WebTest.Session,
  cfg: AuditConfig
) : AuditReport
```

**Web-Semantic Mutants ("Able to Fail"):**
In Tier 2, `arvo verify` additionally runs a small suite of **semantic mutant probes** on a temporary copy of the project (or via `--strength`) to prove the app's test suite catches:
1. Stripping `Auth.require_csrf` in a mutation handler,
2. Changing a required `Principal` route parameter to `Option(Principal)` without redirect,
3. Dropping `AND version = ?` from an optimistic-lock `UPDATE`,
4. Removing `Inertia.escape_html` on `data-page`,
5. Turning off `PRAGMA foreign_keys`.
If the test suite stays green under any semantic mutant, Tier 2 fails with `E_SEMANTIC_MUTANT_SURVIVED`.

---

### 2.5 `Arvo.Sim` (Deterministic Web Simulation Testing — DST)

Drives real `api` routes, multiple concurrent user sessions, advancing `Clock`, `Arvo.Jobs` workers, and `Network.fake_scripted` fault injection, checking global domain + ledger + audit invariants after **every step**, and shrinking any failing sequence to a minimal deterministic reproducer:

```mo
module Arvo.Sim

## Built-in simulation faults mixed alongside app-defined actions.
enum SystemEvent
  AdvanceClock(duration: Duration)
  RunNextJob(job_names: List(Text))
  CrashRunningJob                          # Leaves job in 'running' state without completing
  RequeueStaleJobs(stale_seconds: Int)
  ExpirePruneSessions
  RotateActorSession(actor_idx: Int)
  ReplayStaleSessionCookie(actor_idx: Int) # Verifies revoked cookie cannot authenticate
  InjectNetworkFault(target: Text, fault: Network.FakeReply)
end

enum SimStep(A)
  AppAction(actor_idx: Int, action: A)
  System(event: SystemEvent)
end

struct Invariant(W)
  name: Text
  check: fn(W, Sqlite.Database, Clock) : Result(Unit, Text)
end

struct SimConfig
  base_seed: Int
  seed_count: Int              # e.g. 200 in Tier 1, 5000 in Tier 2
  max_steps: Int               # e.g. 64
  shrink_budget: Int           # e.g. 200 replay runs
  fault_probability_pct: Int   # e.g. 15% system/fault events
end

struct SimFailure(A)
  seed: Int
  invariant_name: Text
  reason: Text
  original_len: Int
  shrunk_steps: List(SimStep(A))
  failing_step_index: Int
  state_summary: Json
end

## Runs `seed_count` deterministic simulations; on first failure shrinks the trace
## (1. delta-delete steps, 2. shorten clock advances, 3. simplify actor/action args)
## and verifies the shrunk trace reproduces the exact same invariant violation.
fn run[W, A](
  cfg: SimConfig,
  init_world: fn(Int) : (W, Sqlite.Database, Clock, SecureRandom, ApiTest.App),
  next_step: fn(Random, W) : SimStep(A),
  apply_step: fn(W, SimStep(A), Sqlite.Database, Clock, ApiTest.App) : Result(W, Text),
  invariants: List(Invariant(W))
) : Result(SimSummary, SimFailure(A)) where A: Json
```

**Built-in Arvo Framework Invariants (`Arvo.Sim.default_invariants`):**
- Every `arvo_sessions` row has non-empty `token_hash` (never raw token) and monotonic `last_seen_at >= created_at`.
- Revoked/rotated sessions never authenticate on subsequent steps.
- No `arvo_jobs` row exceeds `max_attempts` while remaining `pending`, and no completed job is claimed twice.
- `arvo_events` is strictly append-only (count never decreases; IDs strictly ULID-ordered with `clock`).
- SQLite `PRAGMA integrity_check` and `PRAGMA foreign_key_check` return zero violations after every seed.

---

### 2.6 `Arvo.Statechart` (Exhaustive State-Space Explorer & Formal Bridge)

Adapts `pstack`'s `/statechart` and `/create-formal-verification-skill` directly into Arvo so critical state machines (`Arvo.Jobs`, `Arvo.Session`, bill/order/payment lifecycles) are exhaustively checked and visualized in plain user words:

```mo
module Arvo.Statechart

struct Transition(S, A)
  action: A
  label: Text                 # Plain user words, e.g. "partner taps 'I just paid this'"
  next_state: S
end

struct StateInvariant(S)
  name: Text                  # Plain sentence, e.g. "A bill is never Paid without a settled payment"
  holds?: fn(S) : Bool
end

struct ChartSpec(S, A)
  title: Text
  covered_files: List(Text)   # e.g. ["lib/arvo/jobs.mo:claim_next,fail_or_retry,requeue_stale_running"]
  sync_commit: Text           # Git SHA where model was last verified true to code
  max_states: Int             # Bound, e.g. 50000
  initial_states: List(S)
  step_fn: fn(S) : List(Transition(S, A))
  view_state: fn(S) : Text    # Maps model state -> plain-English state label
  view_group: fn(S) : Option(Text)
  invariants: List(StateInvariant(S))
end

struct Counterexample(S, A)
  invariant_name: Text
  steps: List((Text, A, S))   # Shortest BFS path from initial state to violating state
end

struct ChartReport(S, A)
  states_explored: Int
  transitions_explored: Int
  violations: List(Counterexample(S, A))
  mermaid_mmd: Text           # stateDiagram-v2 with `breaks` / `mayBreak` classes
end

fn explore[S, A](spec: ChartSpec(S, A)) : ChartReport(S, A) where S: Equal, S: Hash
```

**Mandatory Code-Replay & Anti-Drift Rules:**
1. **TLA+ / TLC Bridge:** For concurrent multi-process protocols better expressed in TLA+ (with `SYMMETRY` / `VIEW` / fairness / liveness), `arvo statechart run specs/formal/<name>.tla --view <view>.json` invokes TLC, produces the exact same `ChartReport` (`chart.mmd` + shortest counterexamples + `report.md`), and embeds it in the Verification Dossier.
2. **Real-Code Replay:** Every counterexample path (and a sample of reachable paths) MUST be replayed step-by-step against the real Mo code (`Arvo.Jobs` / `WebTest`). A model counterexample that does not reproduce in real code is flagged as `MODEL_DRIFT` rather than reported as a product bug.
3. **Sync-Commit Check:** `arvo verify` checks `git diff <sync_commit>..HEAD -- <covered_files>`. If covered code changed without updating and re-proving the statechart (including proving it still fails on a scratch broken variant), Tier 2 flags `STALE_FORMAL_CHECK`.

---

### 2.7 `Arvo.Snapshot` (Tamper-Guarded Golden Snapshots)

```mo
module Arvo.Snapshot

struct SnapshotOptions
  redact_keys: List(Text)     # e.g. ["id", "created_at", "updated_at", "csrf_token"]
  sort_object_keys?: Bool     # Default true for deterministic diffs
end

## Compares canonicalized `value` against `snapshots/<name>.snap.json`.
## Fails on mismatch unless `ARVO_UPDATE_SNAPSHOTS=1` is explicitly set.
fn assert_json[T](files: Files, env: Env, name: Text, value: T, opts: SnapshotOptions) : Unit
  where T: Json

fn assert_text(files: Files, env: Env, name: Text, value: Text) : Unit
```

Any modified `.snap.json` / `.snap.txt` file in `git status` is automatically flagged in the Verification Dossier's **Tamper Alert Banner** with a concise inline diff.

---

### 2.8 `Arvo.Props` & Mandatory `--strength` Wrong-Version Suites

```mo
module Arvo.Props

## Standard algebraic property helpers composable inside `promise` or `test` blocks:
fn round_trip?[A, B](x: A, encode: fn(A) : B, decode: fn(B) : Option(A)) : Bool where A: Equal
fn idempotent?[A](x: A, f: fn(A) : A) : Bool where A: Equal
fn conserves_sum?(before: List(Int), after: List(Int)) : Bool
```

**Mandatory `--strength` Layout:**
Every critical domain or framework module maintains a sibling `strength/<module>/` folder containing deliberately wrong implementations (each with a 1-line comment naming the subtle bug it plants—e.g., off-by-one boundary, dropped constant-time check, swallowed error, skipped tenant filter, broken rollover clamping):
```text
strength/
  arvo_jobs/
    wrong_no_backoff_cap.mo
    wrong_stale_cutoff_sign.mo
  arvo_session/
    wrong_accepts_expired.mo
    wrong_skips_aad.mo
  budget_safe_to_spend/
    wrong_double_counts_in_flight.mo
```
`arvo verify --tier full` runs `mo test --strength strength/<module> <module>.mo` and requires a **100% kill rate** (every wrong version caught).

---

### 2.9 `Arvo.Replay` (Production Failure Bundle → Regression Test)

```mo
module Arvo.Replay

## Sanitized offline failure artifact (secrets, cookies, auth headers redacted at capture).
struct FailureBundle
  id: Text
  captured_at: Time
  app_commit: Text
  kind: Text                          # "http_500" | "job_failed" | "invariant_breach"
  request: Option(Api.Request)        # Redacted headers
  job_record: Option(Jobs.JobRecord)
  recent_events: List(Audit.AuditEntry)
  sqlite_snapshot_path: Option(Text)  # Sanitized copy of SQLite state
  error_message: Text
end

## Generates a standalone Mo `test "..."` regression snippet pinned to this FailureBundle.
fn generate_regression_test(bundle: FailureBundle) : Text
```

---

## Part 3: Unified Executable Feature Map Format (`.feature.md`)

Unifies BDD Given/When/Then scenarios with `pstack`'s Feature Map contract. Every feature lives in `specs/features/<slug>.feature.md` with an index at `specs/features/README.md`.

### Strict Structure Rules
1. Zero implementation details (no function names, CSS classes, or internal state flags—only user entry points, ARIA roles/accessible names, preconditions, and observable outcomes).
2. Exactly four required H2 headings:
   - `## Sub-features`
   - `## How to get to it (user POV)`
   - `## Scenarios` (executable Gherkin fenced blocks parsed by `Arvo.Feature` and run by **both** `WebTest` and Playwright!)
   - `## Gotchas`
3. Proof tags control required verification artifacts: `@browser` (must run in real Playwright), `@mobile` (must capture `390×844` phone viewport), `@aria` (ARIA tree snapshot), `@screenshot` (before/after PNG), `@video` (screen recording), `@db-check` (read-only SQLite / `arvo_events` cross-check—proving persistence beyond a UI toast), `@smoke` (included in Tier 1).

### Worked Example (`specs/features/pay-bill.feature.md`)

````markdown
# Mark a bill as paid in flight

Household members can tap "I just paid this" on any due bill so neither partner pays the same bill twice, while optimistic concurrency prevents silent overwrites.

## Sub-features

- `bill-pay-happy`: marks a due bill `in_flight` and records who paid it in the audit trail.
- `bill-pay-conflict`: rejects a stale concurrent update with a clear conflict response.
- `bill-pay-unauth`: blocks unauthenticated or CSRF-less attempts.

## How to get to it (user POV)

- Sign in at `/login`, open `/` (Paycheck Bills list), and choose the `Mark paid` button beside a due bill.
- Submit `POST /bills/:id/pay` with an active session and valid `X-XSRF-TOKEN`.

## Scenarios

```gherkin
Feature: Mark a bill as paid in flight
  Background:
    Given seed profile "baseline"
    And signed in as "ada@household.local"

  @smoke @browser @mobile @aria @screenshot @db-check
  Scenario: Member marks a due bill in flight and persistence survives reload
    When I visit "/"
    Then I see heading "Ada & Household <Team>"
    And the bill "Electric & Gas <Utility>" shows status "due"
    When I click button "Mark paid" for bill "Electric & Gas <Utility>"
    Then the bill "Electric & Gas <Utility>" shows status "in_flight"
    When I reload the page
    Then the bill "Electric & Gas <Utility>" shows status "in_flight"
    And audit trail contains action "bill.mark_in_flight" by "ada@household.local" for "bills"

  @smoke
  Scenario: Stale version prevents double-marking a bill
    When actor "ada" marks bill 1 in flight with expected version 1
    Then the response status is 200
    When actor "grace" marks bill 1 in flight with expected version 1
    Then the response status is 409
```

## Gotchas

- A toast or client-side optimistic update alone is insufficient proof; always reload `/` and cross-check `arvo_events`.
- Bill names contain `<` and `&` characters on purpose to verify HTML attribute escaping in `data-page`.
````

---

## Part 4: Pure-Mo `arvo` CLI & Universal Control Adapter

Installed cleanly via `mo install cmd/arvo/main.mo --name arvo` (single compiled Mo bytecode launcher).

### 4.1 Command Tree

| Command | Purpose |
| --- | --- |
| `arvo verify [--tier fast\|feature\|full] [--json] [--changed]` | Orchestrates the chosen verification tier, detects contract/snapshot tampering, writes `verify.jsonl`, and (in `full`) builds the Verification Dossier. |
| `arvo contracts [--check]` | Compiles app contract manifest (`Json.schema[T]()` + `/openapi.json`), generates `frontend/src/arvo.gen.ts`, verifies every Inertia component exists in `src/pages/*.tsx`. With `--check`, fails non-zero if out of date. |
| `arvo control launch [--seed NAME] [--run-id ID]` | Starts an isolated `mo serve --port 0 --ready-file ...` in a disposable `--data` dir with migrations + seed applied; prints JSON instance handle. |
| `arvo control doctor --run-id ID` | Read-only health check: verifies PID alive, port owned by this run, build SHA matches HEAD, migrations applied, auth probe succeeds. |
| `arvo control drive --run-id ID ...` | Runs Playwright actions / `.feature.md` scenarios against the isolated instance using ARIA role/name locators with zero-console-error, zero-5xx, and axe-core assertions. |
| `arvo control inspect --run-id ID (--aria \| --sql QUERY \| --audit \| --logs)` | Read-only inspection (never mutates state; SQL runs on a `mode=ro` connection). |
| `arvo control screenshot / record --run-id ID --out PATH` | Captures PNG screenshot or WebM/MP4 recording into `.arvo/evidence/<run-id>/` (outside git, surviving cleanup). |
| `arvo control reset --run-id ID [--seed NAME]` | Resets disposable SQLite state deterministically for independent second repro attempts. |
| `arvo control cleanup --run-id ID` | Kills ONLY PIDs recorded for `--run-id`, deletes disposable `--data` dir, and **verifies evidence files survived**. |
| `arvo feature [--driver webtest\|playwright\|both] [FILE]` | Parses and executes `.feature.md` specs. |
| `arvo sim [--seeds N] [--seed REPLAY_SEED] [--steps N]` | Runs `Arvo.Sim` DST suite or deterministically replays a single shrunk failure seed. |
| `arvo statechart [check\|render] [SPEC]` | Runs Mo BFS or TLA+/TLC statechart verification, replays bug paths against real code, checks sync commits, outputs `.mmd` + `report.md`. |
| `arvo bench --baseline REF --candidate REF --cmd CMD [--runs 7]` | Runs alternating A/B/A/B benchmarks and enforces `pstack`'s 7-question `/benchmark-checklist` (prints median, range, error count, work-happened check, limiter, and verdict: `faster \| slower \| no_difference \| inconclusive`). |
| `arvo replay capture\|gen BUNDLE` | Captures/sanitizes a production failure bundle or generates a deterministic Mo regression test from it. |
| `arvo dossier [--open]` | Renders `.arvo/dossier/index.html` and `.arvo/dossier/pr-summary.md` from the latest `verify.jsonl` and evidence directory. |

### 4.2 Configuration (`arvo.toml`)

```toml
[app]
entry = "main.mo"
frontend_dir = "frontend"
pages_dir = "frontend/src/pages"
contracts_out = "frontend/src/arvo.gen.ts"
features_dir = "specs/features"
strength_dir = "strength"

[testing]
public_routes = ["GET /login", "POST /login"]
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
axe_fail_impacts = ["critical", "serious"]

[testing.tamper_protected]
globs = [
  "specs/features/**/*.feature.md",
  "snapshots/**/*",
  "strength/**/*",
  "arvo.toml",
  "frontend/stryker.config.*",
]
```

---

## Part 5: Frontend Verification Spec (Contracts, Vitest, Stryker, Playwright, A11y, Visual Parity)

### 5.1 `Json.schema[T]()` → `frontend/src/arvo.gen.ts` Mapping

| Mo Type | Generated TypeScript Type |
| --- | --- |
| `Bool` | `boolean` |
| `Int`, `Byte`, `Float` | `number` |
| `Text`, `Char`, `Decimal`, `BigInt`, `Time`, `Date` | `string` (exact wire representation; never float for `Decimal`) |
| `Option(T)` | `T \| null` |
| `List(T)`, `Set(T)` | `T[]` |
| `Map(Text, V)` | `Record<string, V>` |
| `struct Name` | `export interface Name { ... }` |
| `enum Name` | Discriminated union matching Mo's `snake_case` JSON tags |
| Registered pages | `export interface ArvoPagePropsMap { Home: HomeProps & SharedProps; Login: LoginProps & SharedProps; }` |

`arvo contracts --check` fails immediately if:
1. Any registered `PageContract.component` has no matching `frontend/src/pages/<component>.tsx`,
2. `frontend/src/arvo.gen.ts` differs from the freshly generated output, or
3. `tsc --noEmit` fails against the generated interfaces.

### 5.2 Vitest + React Testing Library Fed Real Mo Fixtures + Stryker

- During Tier 0/1 `WebTest`, calling `WebTest.record_inertia_fixture` writes verified `InertiaPage` JSON responses to `.arvo/fixtures/<Component>/<case>.json`.
- Vitest tests render `<Home {...fixture.props} />` using **real backend-produced JSON**—never hand-typed mock props that drift from Mo.
- All interactive queries use `@testing-library/react` `getByRole` / `getByLabelText` (enforcing accessible DOM).
- **Stryker (`@stryker-mutator/core` + `@stryker-mutator/vitest-runner`):** runs in Tier 2 across `frontend/src/**/*.{ts,tsx}` (excluding `arvo.gen.ts`), enforcing `ts_stryker_min_kill_rate` and reporting surviving frontend mutants directly into `verify.jsonl` and the Verification Dossier.

### 5.3 Playwright E2E, Accessibility & Visual Parity

Every Playwright test launched through `arvo control drive` enforces these global fail-closed fixtures automatically:
1. **Zero console errors & zero uncaught page errors** (`page.on("console", ...)` / `page.on("pageerror", ...)`).
2. **Zero unexpected 5xx responses** and zero broken asset loads (`404` on `/assets/*`).
3. **ARIA-first locators only** (`getByRole`, `getByLabel`, `data-testid` only where no semantic role exists; lint rule forbids CSS-class / nth-child brittle selectors).
4. **Accessibility gate:** `@axe-core/playwright` runs on every visited Inertia page across both `mobile` (`390×844`) and `desktop` (`1280×800`) viewports, failing on any `critical` or `serious` violation.
5. **Dual-view persistence check:** For `@db-check` scenarios, after a UI mutation and page reload, Playwright calls `arvo control inspect --sql` / `--audit` to confirm the exact persisted SQLite row and `arvo_events` record.
6. **Visual parity (opt-in per component/page via `@visual-parity`):** Diffs screenshots against frozen baselines in `snapshots/visual/` with zero-pixel tolerance (or configured threshold). Baseline files are tamper-protected; agents cannot modify baselines silently.

---

## Part 6: Machine Output (`verify.jsonl`), Tamper Detection & Human Verification Dossier

### 6.1 Agent Machine Output (`.arvo/dossier/verify.jsonl`)

Every check emits one newline-delimited JSON event so coding agents diagnose failures without scraping prose logs:

```json
{"ts":"2026-11-25T15:02:01Z","tier":"full","phase":"contracts","status":"pass","pages_checked":2,"ms":180}
{"ts":"2026-11-25T15:02:04Z","tier":"full","phase":"security_matrix","status":"pass","routes":7,"checks":49,"ms":240}
{"ts":"2026-11-25T15:02:19Z","tier":"full","phase":"sim","status":"fail","suite":"BudgetSim","seed":1842,"invariant":"no_double_counting","shrunk_steps":4,"replay_cmd":"arvo sim --suite BudgetSim --seed 1842"}
{"ts":"2026-11-25T15:02:45Z","tier":"full","phase":"mo_mutants","status":"pass","total":218,"killed":218,"survived":0,"kill_rate":1.0}
{"ts":"2026-11-25T15:03:40Z","tier":"full","phase":"stryker","status":"pass","total":64,"killed":59,"survived":5,"kill_rate":0.922}
{"ts":"2026-11-25T15:04:12Z","tier":"full","phase":"tamper_check","status":"warn","modified_contracts":["specs/features/pay-bill.feature.md"]}
```

### 6.2 Contract & Test Tamper Detection

`arvo verify` inspects `git diff <base>..HEAD` and flags ANY modification to:
- `specs/features/**/*.feature.md` (BDD specs / Feature Maps),
- `snapshots/**/*` (golden JSON/text/ARIA/visual baselines),
- `strength/**/*` (wrong-version intent suites),
- `promise ... end` blocks inside `.mo` files (AST/line diff check),
- `arvo.toml` `[testing]` thresholds / `public_routes` / `csrf_exempt_routes`,
- `frontend/stryker.config.*`.

Tamper warnings do **not** block intentional spec changes, but they pin a high-contrast **Contract Changed — Human Review Required** section at the very top of both `index.html` and `pr-summary.md` showing the exact diff so no contract edit ever hides inside a large PR.

### 6.3 Human Verification Dossier Structure

1. **`.arvo/dossier/index.html`** (self-contained static HTML, inline CSS/Mermaid/base64-or-relative screenshots):
   - **Header Verdict:** `PASS | PASS WITH CONTRACT CHANGES | FAIL | INCONCLUSIVE`, commit SHA, tier, duration.
   - **1. Tamper Alert Banner:** exact contract/spec/snapshot/promise diffs (collapsed to a green "0 contract edits" pill when clean).
   - **2. Visual-First Proof Strip:** mobile (`390×844`) + desktop (`1280×800`) screenshots and recordings per Feature Map entry, with pass/fail badges and DB/Audit cross-check confirmations.
   - **3. Formal Statecharts:** rendered Mermaid `stateDiagram-v2` charts for every `Arvo.Statechart`, sync commit badge (`in sync` vs `stale`), state count, and shortest counterexample path if any rule broke.
   - **4. Adversarial & Mutation Scorecard:** Mo `--mutants`, Mo `--strength`, Web-Semantic Mutants, Stryker TS mutation, `Arvo.Sim` seeds/steps/faults, `arvo contracts` sync, axe-core violations.
   - **5. Route Security & Query-Budget Matrix:** every `api` route × (`Auth`, `CSRF`, `XSS`, `409`, `422`, `Queries/max`).
   - **6. Decision Trail (`decisions.tsv`) & Independent Verifier `Attention` Section:** append-only table (`ts`, `phase`, `decision`, `why`, `evidence`, `result`) plus reviewer model name and flagged risks/gaps.
2. **`.arvo/dossier/pr-summary.md`:** `ketchup`-style plain-words summary (under 150 words of prose + inline images + explicit list of any calls waiting on the human).

---

## Part 7: Bundled Arvo Agent Skills (`.arvo/skills/`)

Every Arvo installation ships five concise, cold-readable skills tailored to Arvo's real commands:

| Skill | Trigger | Core Protocol & Non-Negotiables |
| --- | --- | --- |
| `arvo-verify` | Completing any feature, refactor, or PR | Match proof to surface; run Tier 0 → Tier 1 → Tier 2; log decision checkpoints to `decisions.tsv`; require an independent verifier agent (never the author turn) to audit the Dossier and emit an `Attention` block; report `INCONCLUSIVE` if any required surface could not run. |
| `arvo-maintain-specs` | Daily/scheduled or after major churn | Parallel read-only source readers per `.feature.md` + one live `arvo control` pass exercising every feature; edit scope strictly confined to `specs/features/` (never product code); classify findings as **doc drift**, **harness gap**, or **product regression**; end in `clean \| changed \| blocked`. |
| `arvo-statechart` | Changing state machines, jobs, sessions, or concurrency | Run `arvo statechart`; render plain-English Mermaid chart; prove invariant fails on a scratch broken variant; replay every counterexample against real Mo code; update `sync_commit` only after confirming model-code fidelity. |
| `arvo-bug-repro` | Fixing any reported or production bug | Reproduce twice through `arvo control` (or `Arvo.Replay` bundle); add focused failing regression test first; fix root cause with smallest change; prove fixed twice with before/after artifacts + blast-radius proof of the one safety fact by running real code. |
| `arvo-correct` | Whenever an AI agent repeats a mistake class | Group repeated mistakes; fix at highest level (`Architecture > Types > Lint with fix > Test > Docs`); prove each new check fails on a real past mistake; keep rule → enforcer table in repo instructions. |

---

## Part 8: Crucible Upgrade Plan for `examples/arvo-starter`

`examples/arvo-starter` serves as the proving ground for Phases 1–5. Immediate concrete improvements identified by inspecting the current starter:

1. **Typed Inertia pages:** Replace untyped `Map(Text, Json)` in [examples/arvo-starter/routes.mo](../examples/arvo-starter/routes.mo) (`show_login`, `home`) with concrete `LoginProps`, `HomeProps`, and `SharedProps` structs + `Inertia.render_page` → auto-generate `frontend/src/arvo.gen.ts`.
2. **Accessible ARIA handles:** Wire `<label htmlFor>` to `<input id>` in [Login.tsx](../examples/arvo-starter/frontend/src/pages/Login.tsx) and add accessible labels + a real `Mark paid` button (`POST /bills/:id/pay`) in [Home.tsx](../examples/arvo-starter/frontend/src/pages/Home.tsx) so `@axe-core/playwright` passes cleanly and `arvo control drive` uses pure ARIA locators.
3. **Extract `Arvo.Seed` profiles:** Move `bootstrap_db` seeding out of `authenticate` into named `Arvo.Seed` profiles (`empty`, `baseline`, `many_bills`).
4. **Add full verification stack to starter:**
   - Rewrite [examples/arvo-starter/main.mo](../examples/arvo-starter/main.mo)'s 350-line manual test using `Arvo.WebTest` v2 + `Arvo.SecurityMatrix` + query budgets.
   - Add `specs/features/{auth,bills,csv-import}.feature.md` Executable Feature Maps.
   - Add `Arvo.Sim` multi-user concurrent bill-payment & session-revocation simulation.
   - Add `strength/` wrong-version suites for starter domain rules + core Arvo modules.
   - Add Vitest (using recorded Mo Inertia fixtures), Stryker config, and Playwright phone/desktop E2E.
