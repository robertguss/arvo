# Arvo Verification & Testing Architecture & Roadmap

> **Built for AI-authored software with minimal human review:** when agents write almost all of the code, tests can no longer be an afterthought or a rubber stamp. Verification must be **fast in the inner loop**, **adversarial against weak tests**, **honest about which surface it proved**, and **readable by a human in under two minutes**.

**Companion Spec:** [arvo-testing-spec.md](arvo-testing-spec.md)  
**Companion Framework Docs:** [arvo-plan.md](arvo-plan.md) · [arvo-spec.md](arvo-spec.md)  
**Status:** Settled design (`2026-11-25`) — ready for Phase 0/1 execution.  
**Architectural Split:** Arvo-first (pure Mo libraries + pure Mo `arvo` CLI + bundled agent skills), paired with 5 small, high-leverage upstream Mo runtime/compiler additions.

---

## 1. The Core Problem: Why Standard Testing Fails When AI Writes the Code

Traditional testing assumes a human author who understands intent, writes conservative code, and reviews every PR line by line. When AI agents write both implementation and tests and human review is minimal, five failure modes dominate:

1. **Circular validation (tautological tests):** An agent writes buggy code, then writes tests that mirror the implementation rather than the contract. Everything turns green while the feature is broken.
2. **Spec and snapshot tampering:** When a test or snapshot fails, an agent under pressure weakens an assertion, edits a `.feature` step, or updates a golden snapshot to get a green check.
3. **Wrong-surface verification:** Passing unit tests or a clean compile get reported as "verified" when the real UI is broken, a form label is missing, a session cookie fails under `Secure`, or an Inertia prop renders `NaN`.
4. **Cross-boundary drift (where grep stops):** Mo backend (`Inertia.render` JSON maps, SQLite columns, HTTP error codes) silently drifts from React/TypeScript (`interface HomeProps`, form field names, error bags) while both `mo check` and `tsc` pass independently.
5. **Rare interleaving & concurrency bugs:** Optimistic locking races between two users, stale `arvo_jobs` locks, mid-transaction crashes, retry storms, expired sessions, and out-of-order external API faults live on paths hand-written example tests rarely reach.

### Six Non-Negotiable Design Rules

Synthesizing Mo's capability discipline, Arvo's explicitness, and the verification principles proven in `pstack`:

1. **Fix mistake classes at the highest level (`Architecture > Types > Lint > Test > Docs`).** Eliminate drift with compiler-checked types (`Json.schema[T]()` → `arvo.gen.ts`) and fail-closed defaults before writing a single test. Docs and rules are last because nothing fails when an agent skips them.
2. **Every check must be proven able to fail.** A test, property, security check, or formal model you have never seen catch a broken variant proves nothing. We enforce this structurally via `mo test --mutants`, `mo test --strength`, web-semantic mutants, Stryker TS mutation, and failing-before regression tests.
3. **Match proof to the surface.** Compilation is not runtime proof; a unit test is not UI proof; a UI toast is not persistence proof (reopen from the list *and* read back SQLite / `arvo_events`).
4. **Tamper-evident human-owned contracts.** Human-readable Executable Feature Maps (`.feature.md`), `promise` invariants, `--strength` wrong versions, and golden snapshots are tracked separately from implementation diffs. Any AI edit to them raises a top-level **Contract Changed** banner for human approval.
5. **Universal Control Adapter built into the framework.** Because Arvo owns `mo serve`, `Migrations`, `Session`, `Inertia`, and `Audit`, every Arvo app gets isolated ephemeral launch, `doctor`, ARIA-first browser driving, read-only DB/Audit inspection, surviving-cleanup evidence, and safe teardown out of the box—no hand-rolled per-repo control scripts.
6. **Independent verification & visual-first human briefings.** Separate the author from the verifier, log every claim to an append-only `decisions.tsv` evidence trail, and hand humans a scannable **Verification Dossier** (screenshots, recordings, Mermaid statecharts, adversarial scorecards, tamper alerts)—never a wall of raw logs.

---

## 2. System Architecture Overview

```mermaid
flowchart TD
  Specs["Human-Owned Contracts<br/>(Executable Feature Maps .feature.md, promises, golden snapshots, --strength)"]
  CLI["Pure-Mo arvo CLI<br/>(arvo verify | control | contracts | sim | statechart | bench | replay)"]

  subgraph T0["Tier 0: Inner Loop (1-3s, every edit)"]
    MoCheck["mo check + examples + promise"]
    ContractGen["Json.schema[T]() -> arvo.gen.ts + page check + tsc"]
    WebFast["Arvo.WebTest v2 + SecurityMatrix fast + N+1 query budget"]
    VitestFast["Vitest targeted (real Mo Inertia fixtures)"]
  end

  subgraph T1["Tier 1: Feature Complete (15-60s)"]
    FeatInMem["Feature Maps (in-memory WebTest driver)"]
    SimShort["Arvo.Sim Web DST (200 seeds, clock/jobs/faults)"]
    MutInc["mo test --mutants (changed modules)"]
    PwSmoke["Playwright via arvo control (ARIA + axe-core + DB read-back + screenshots)"]
  end

  subgraph T2["Tier 2: Ship / PR Gate (deep / CI)"]
    MutFull["Full mo test --mutants + --strength + Web-Semantic Mutants"]
    Stryker["Stryker TS Mutation (frontend)"]
    SimDeep["Deep Arvo.Sim DST (5,000+ seeds + shrinker)"]
    Statechart["Arvo.Statechart (Mo BFS / TLA+ TLC -> Mermaid + code replay + sync commit)"]
    PwFull["Full Playwright Sweep (phone + desktop, video, visual parity, full Feature Map)"]
  end

  AgentOut["verify.jsonl<br/>(shrunk traces, seeds, surviving mutants, replay cmds)"]
  Dossier["Human Verification Dossier<br/>(Static HTML + PR Markdown: Tamper Banner, Visuals, Statecharts, Scorecards, decisions.tsv)"]

  Specs --> CLI
  CLI --> T0
  T0 --> T1
  T1 --> T2
  T0 --> AgentOut
  T1 --> AgentOut
  T2 --> AgentOut
  T2 --> Dossier
```

---

## 3. Complete Methodology Matrix (Unit to E2E & Everything In Between)

Every layer catches a distinct class of failure that adjacent layers miss:

| # | Methodology | Mechanism in Arvo / Mo | What It Proves (and Catches) |
| --- | --- | --- | --- |
| 1 | **Static & Cross-Stack Contracts** | Mo typecheck + exhaustive `api` `status` + typed `Inertia.Page[P]` → `Json.schema[T]()` → `arvo.gen.ts` + `src/pages/*.tsx` check + `tsc --noEmit` | Eliminates Mo ↔ React prop drift, missing page components, unmapped errors, and invalid query/body decoding at compile time. |
| 2 | **Examples & Unit Tests** | Native Mo `examples` & `test` blocks | Concrete specification-by-example living directly atop pure functions. |
| 3 | **Property-Based Testing** | Native Mo `promise` (boundary extremes, vacuity check, `allows`/`forbids` anchors, shrinking) + `Arvo.Props` patterns | Catches overflow, date clamping, encoding edge cases, algebraic violations (conservation, idempotency, round-trip, monotonicity) across generated inputs. |
| 4 | **Full-Stack In-Memory Web Tests** | `Arvo.WebTest` v2 + `ApiTest.App` + `Arvo.Seed` + `Sqlite.in_memory()` | Sub-second end-to-end HTTP, cookie jar, CSRF, Inertia HTML/JSON, partial reloads, flash bags, multipart uploads, redirects, and DB persistence with zero sockets. |
| 5 | **Zero-Config Adversarial Web Audits** | `Arvo.SecurityMatrix` derived automatically from `api` routes / `/openapi.json` | Fail-closed verification of every route for guest auth rejection (`401`/`303`), missing/forged CSRF (`403`), XSS in `data-page`, open-redirect blocking, `409` Inertia version mismatch, `422` strict JSON, optimistic lock `409`, and migration idempotency/checksum/FK integrity. |
| 6 | **Mutation Testing & Intent Strength (Both Stacks)** | Mo `mo test --mutants` (7 operators) + mandatory `mo test --strength` wrong-version suites + **Web-Semantic Mutants** (CSRF/auth/lock/escape bypasses) + **Stryker** on frontend TS/React | Defeats AI tautological tests: proves both backend and frontend suites actually fail when logic or security invariants break. |
| 7 | **Deterministic Simulation Testing (Web DST)** | `Arvo.Sim` driving real `api` handlers + multiple concurrent users + advancing `Clock` (`clock.sleep`) + `Arvo.Jobs` retries/crashes/stale-locks + `Network.fake_scripted` faults + shrinking | Finds multi-step races, optimistic-lock bugs, duplicate side effects, stale locks, expired-session leaks, and ledger/audit invariant violations directly against real code (zero model drift). |
| 8 | **Formal Verification & Statecharts** | `Arvo.Statechart` (pure-Mo bounded BFS explorer + optional TLA+/TLC bridge) + Mermaid renderer + real-code replay + sync-commit tracking | Exhaustively checks 100% of small-scope interleavings for high-stakes state machines (`Jobs`, `Session`, domain workflows), renders plain-English Mermaid statecharts for humans, and guarantees models never silently drift from code. |
| 9 | **Unified Executable Feature Maps (BDD + `pstack`)** | Human-owned `.feature.md` files (`Sub-features`, `User POV`, `Executable Given/When/Then`, `Gotchas`) runnable via **dual drivers** (`WebTest` in-memory + Playwright live) + `arvo-maintain-specs` audit loop | Gives humans plain-English behavioral contracts, exercises every documented entry point, requires DB/Audit cross-checks alongside UI state, and separates doc drift vs. harness gap vs. product regression. |
| 10 | **Frontend Component, A11y & Visual Parity** | Vitest + React Testing Library fed **real Mo-emitted Inertia JSON fixtures** + Stryker + `@axe-core/playwright` + baseline pixel-diff (`visual-parity`) | Tests React rendering/interactions against real backend payloads, enforces WCAG accessibility (which simultaneously guarantees stable ARIA handles), and catches unintended visual regressions pixel-for-pixel. |
| 11 | **Real-Browser E2E & Universal Control Adapter** | `arvo control` (`launch`, `doctor`, `drive`, `inspect`, `screenshot`, `record`, `reset`, `cleanup`) + Playwright across phone (`390×844`) and desktop (`1280×800`) against real `mo serve` | Proves the actual compiled binary + Vite production bundle + real browser DOM/JS/CSS work end to end with zero console errors, zero 5xxs, isolated parallel instances, and surviving proof artifacts. |
| 12 | **Snapshots, Query/Perf Budgets & Failure Replay** | `Arvo.Snapshot` (tamper-guarded), SQLite test query counter (N+1 budgets), `arvo bench` (7-question `benchmark-checklist`), and `Arvo.Replay` (prod failure bundle → regression test) | Locks down complex outputs, prevents accidental N+1 regressions, prevents bogus perf claims, and turns real production bugs into permanent deterministic tests. |

---

## 4. What Mo Already Gives Us vs. Targeted Upstream Mo Additions

Mo `0.3.0` already ships an extraordinary testing foundation: `examples`, `promise` (with vacuity checks, anchors, and shrinking), deterministic capability fakes (`Sqlite.in_memory()`, `Clock.fixed` with zero-real-time `clock.sleep`, `SecureRandom.seeded`, `Files.in_memory`, `Network.fake`, `Env.of`), `Simulation` for `service`/`actor` blocks, `ApiTest.send`/`run_job`, `Json.schema[T]()`, `mo test --mutants`, `mo test --strength`, `mo diff`, and `mo replay`.

However, inspecting Mo `0.3.0` exposed **five specific constraints** that block either ergonomics or pure-Mo orchestration:

1. **`ApiTest.send(Main, ...)` takes a static module name and can only run directly inside `test` blocks** → prevents pure-Mo helper libraries (`Arvo.WebTest`, `Arvo.SecurityMatrix`, `Arvo.Sim`) from driving an app cleanly without copy-pasting 10 arguments per request.
   - **Fix:** `ApiTest.start(Main, ...)` returning a first-class capability handle `ApiTest.App` (exact same pattern as `Simulation.start(Module, at)`!) with `app.send(req)`, `app.run_job(name, payload)`, and `app.routes()`.
2. **`Network.fake` is a static `Map`** → cannot express ordered retry/fault sequences (e.g., `TimedOut` on call 1, `502` on call 2, `200` on call 3) needed by `Arvo.Sim`.
   - **Fix:** `Network.fake_scripted(...)` with per-target response/fault queues and recorded request inspection.
3. **No test-mode SQLite query counter** → cannot enforce N+1 / query-count budgets inside `WebTest`.
   - **Fix:** Spec-only `db.stats()` / `db.reset_stats()` returning `query_count`, `exec_count`, and SQL text on in-memory/fake `Sqlite.Database`.
4. **`Command.run` is synchronous and blocks network sockets on Linux (Landlock/seccomp)** → blocks a pure-Mo `arvo` CLI from launching a background `mo serve` process and letting Playwright connect to `127.0.0.1`.
   - **Fix:** `Command.allow_loopback()` + supervised `Command.spawn(...) : Result(Process, CommandError)` (`alive?`, `kill`, `wait`), plus `mo serve --port 0 --ready-file PATH`.
5. **Mutant/strength reporting & parallelism** → `mo test --mutants` / `--strength` need structured `--json` events and multi-core `--jobs N` execution so `arvo verify` can run fast and feed scorecards into the Verification Dossier.

> [!NOTE]
> **Incremental path:** Arvo does not need to wait on all 5 Mo additions to start delivering value. Typed `Inertia.Page[P]`, `Json.schema[T]()` contract generation, `Arvo.Seed`, `Arvo.Snapshot`, `Arvo.Props`, pure-Mo `Arvo.Statechart`, `.feature.md` parsing, `WebTest` assertion/builder upgrades, and `--strength` wrong-version suites work on Mo `0.3.0` immediately.

---

## 5. The Three-Tier Execution Ladder

Agents iterate fast in Tier 0, verify completed features in Tier 1, and gate PRs/releases with Tier 2:

| Tier | Command | Target Latency | Scope | Blocking? |
| --- | --- | --- | --- | --- |
| **Tier 0 — Inner Loop** | `arvo verify --tier fast` | **1–3 s** | `mo check`, `examples`, `promise`, changed-module `WebTest` + fast `SecurityMatrix`, `arvo contracts --check`, `tsc --noEmit`, targeted Vitest | Every edit loop |
| **Tier 1 — Feature Complete** | `arvo verify --tier feature` | **15–60 s** | Full `WebTest` + N+1 budgets, all `.feature.md` (in-memory driver), short `Arvo.Sim` (200 seeds), incremental `mo test --mutants` on changed modules, full Vitest, Playwright changed/smoke features (`@smoke`) with ARIA + axe-core + DB read-back + screenshot | Before declaring any task done |
| **Tier 2 — Ship / PR Gate** | `arvo verify --tier full` | **2–10 min** (parallel / background) | Full `mo test --mutants` + mandatory `--strength` + Web-Semantic Mutants, Stryker TS mutation, deep `Arvo.Sim` (5,000+ seeds), `Arvo.Statechart` + real-code replay + sync-commit check, full Playwright sweep (phone + desktop, video, visual parity, full Feature Map), emits **Verification Dossier** | Required before human review / merge |

---

## 6. Human Trust Surface & Bundled Agent Skills

### The Verification Dossier (`arvo verify --tier full`)
Emitted in three synchronized views from one run:
1. **`.arvo/dossier/verify.jsonl`** — compact NDJSON for agents (exact failing seeds, shrunk counterexamples, surviving mutant `file:line`, replay commands).
2. **`.arvo/dossier/index.html`** — self-contained static HTML dossier (no server needed) with:
   - **Tamper Alert Banner:** highlights any change to `.feature.md`, snapshots, `promise` bodies, `--strength` files, or `[testing]` config.
   - **Visual-First Proof Strip:** inline phone & desktop screenshots, videos, ARIA diffs, and Mermaid statecharts.
   - **Adversarial Scorecard:** Mo mutant kill %, TS Stryker kill %, `--strength` kill %, DST seeds/steps/invariants, route-by-route `SecurityMatrix` & query-budget table, contract sync status.
   - **Decision & Evidence Trail (`decisions.tsv`):** append-only claim → artifact pointer log + independent verifier `Attention` flags.
3. **`.arvo/dossier/pr-summary.md`** — `ketchup`-style plain-words PR briefing (pictures first, zero jargon, only real calls waiting on the human).

### Bundled Agent Skills (`.arvo/skills/`)
Shipped directly inside Arvo so every AI coding agent gets the workflow structurally:
- **`arvo-verify`** — runs the right tier for the surface changed, enforces independent verifier separation and `decisions.tsv` evidence logging, and blocks claims without artifacts.
- **`arvo-maintain-specs`** — periodic drift audit (parallel read-only source readers + one live pass over every `.feature.md`), triaging **doc drift** vs. **harness gap** vs. **product regression** without touching product code or weakening specs.
- **`arvo-statechart`** — generates/updates formal statechart models for high-stakes state machines, renders plain-English Mermaid diagrams, replays bug paths against real code, and enforces sync commits.
- **`arvo-bug-repro`** — enforces `pstack`'s bug workflow: reproduce twice through `arvo control` / real path → failing regression test first → root-cause fix → prove fixed twice with before/after evidence + blast-radius proof.
- **`arvo-correct`** — turns recurring AI mistakes in an Arvo app into structural guards at the highest level (`Architecture > Types > Lint > Test > Docs`) and proves each new check fails on a past mistake.

---

## 7. Phased Execution Plan & Exit Gates

> [!IMPORTANT]
> Every phase lands in small, verifiable slices with `./scripts/test.sh` (and later `arvo verify`) green at every commit, proving each new check fails on a deliberate break before marking it done.

### Phase 0: Targeted Upstream Mo Additions (`mo`)
- **Deliverables:**
  1. `ApiTest.start` → `ApiTest.App` first-class handle (`send`, `run_job`, `routes`).
  2. `Network.fake_scripted` fault-injecting ordered reply/error queue + call log.
  3. Spec-only `Sqlite.Database.stats()` / `reset_stats()` query counter.
  4. `Command.allow_loopback()`, supervised `Command.spawn`, and `mo serve --port 0 --ready-file PATH`.
  5. Parallel `--jobs N` and NDJSON `--json` reporting for `mo test --mutants` and `--strength`.
- **Exit Gate:** Mo `ci/check.sh` green; each primitive verified with its own tests, fakes, and error-path checks.

### Phase 1: Pure-Mo Core Testing & Contract Modules (`lib/arvo/`)
- **Deliverables:**
  1. Typed `Arvo.Inertia` (`render_page[P, S]`, `PageSpec`, `ContractManifest` via `Json.schema[T]()`).
  2. `Arvo.WebTest` v2 (fluent session client, redirect follower, typed Inertia assertions, flash/error assertions, query-budget assertions, Vitest fixture recorder).
  3. `Arvo.Seed` (shared deterministic seed profile registry), `Arvo.Snapshot` (tamper-guarded golden snapshots with redaction), and `Arvo.Props` (property patterns).
  4. `Arvo.SecurityMatrix` (zero-config fail-closed route/auth/CSRF/XSS/open-redirect/Inertia/migration auditor).
  5. `Arvo.Sim` (multi-actor/clock/jobs/network-fault Web DST engine + deterministic shrinker + trace formatter).
- **Exit Gate:** All new modules pass `mo check`, `mo test`, `mo test --mutants` (100% kill rate on core modules), and each check in `SecurityMatrix` / `Sim` is proven to fail against deliberately broken starter routes.

### Phase 2: Pure-Mo `arvo` CLI & Executable Feature Maps (`cmd/arvo/`)
- **Deliverables:**
  1. Pure-Mo `arvo` CLI (`mo install cmd/arvo/main.mo --name arvo`) reading `arvo.toml`.
  2. `Arvo.Feature` parser & runner for `.feature.md` Executable Feature Maps (dual-mode: in-memory `WebTest` driver + Playwright driver manifest).
  3. `arvo contracts` generating `frontend/src/arvo.gen.ts` from `Json.schema[T]()` + `/openapi.json` and verifying every page component exists in `src/pages/*.tsx`.
  4. `arvo verify --tier fast|feature|full` orchestrator, tamper-diff detector, and `verify.jsonl` emitter.
- **Exit Gate:** `arvo verify --tier fast` runs in `<3s` on `examples/arvo-starter`; modifying a Mo prop or `.feature.md` triggers contract error / tamper alert deterministically.

### Phase 3: Universal Control Adapter, Playwright E2E, Vitest + Stryker & Starter Crucible
- **Deliverables:**
  1. `arvo control` implementing all 7 capabilities (`launch`, `doctor`, `drive`, `inspect`, `screenshot`/`record`, `reset`, `cleanup`) with isolated ports/dirs and parallel-run safety.
  2. Frontend test template in `examples/arvo-starter/frontend`: typed `arvo.gen.ts` props, accessible `<label htmlFor>` forms, Vitest + React Testing Library consuming Mo-recorded Inertia fixtures, Stryker mutation config, and Playwright (phone + desktop, zero console/5xx, axe-core a11y, ARIA snapshots, pixel-diff visual parity).
  3. Complete worked `.feature.md` Feature Map for `examples/arvo-starter` (`auth.feature.md`, `bills.feature.md`, `csv-import.feature.md`) running identically via `WebTest` and Playwright.
- **Exit Gate:** Two concurrent `arvo control` runs execute side-by-side without colliding; evidence survives cleanup; `arvo verify --tier feature` passes end-to-end on `examples/arvo-starter`; intentional UI, a11y, or prop-rename breaks are caught automatically.

### Phase 4: Formal Statecharts, Web-Semantic Mutants, `--strength`, Perf & Failure Replay
- **Deliverables:**
  1. `Arvo.Statechart` (pure-Mo bounded BFS explorer + optional TLA+/TLC runner → plain-English Mermaid `stateDiagram-v2` + shortest failing path + real-code replay + sync-commit checker), applied first to `Arvo.Jobs` and `Arvo.Session`.
  2. Mandatory `--strength` wrong-version suites for all critical Arvo modules (`Session`, `Csrf`, `Auth`, `Inertia`, `Migrations`, `Jobs`, `Audit`, `Changeset`) + automated Web-Semantic Mutants.
  3. `arvo bench` enforcing the 7-question `/benchmark-checklist` (alternating runs, median/range, error counts, work verification, limiter).
  4. `Arvo.Replay` / `arvo replay-capture` converting sanitized production SQLite + request/job/audit failure bundles into deterministic `WebTest` / `Arvo.Sim` tests.
- **Exit Gate:** `Arvo.Statechart` renders verified Mermaid statecharts for `Jobs` and `Session` and catches an injected stale-lock/double-claim bug with a replayed counterexample; all `--strength` wrong versions are 100% killed.

### Phase 5: Human Verification Dossier & Bundled Agent Skills
- **Deliverables:**
  1. `arvo dossier` emitting self-contained `.arvo/dossier/index.html` and `.arvo/dossier/pr-summary.md` (Tamper Alert Banner, Visual Proof Strip, Statecharts, Scorecards, Route Matrix, `decisions.tsv`).
  2. Bundled `.arvo/skills/` (`arvo-verify`, `arvo-maintain-specs`, `arvo-statechart`, `arvo-bug-repro`, `arvo-correct`) with concrete Arvo commands and zero placeholders.
  3. End-to-end Tier 2 (`arvo verify --tier full`) green run producing a live Verification Dossier for `examples/arvo-starter` and proving every skill once end-to-end before release.
- **Exit Gate:** A fresh agent reading only the bundled skills and `arvo --help` can build a new feature in `examples/arvo-starter`, run `arvo verify --tier full`, and hand back a complete Verification Dossier that a human can review in under two minutes.
