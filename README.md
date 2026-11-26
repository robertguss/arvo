# Arvo

**Arvo** (named after composer Arvo Pärt) is a calm, batteries-included web framework for [**Mo**](https://github.com/robertguss/mo), inspired by Phoenix, Ash, and Inertia.js.

Build full-stack, single-binary web applications with **Inertia v2** (`@inertiajs/react` + React 19 + TypeScript + Vite + Tailwind CSS v4), **zero hand-rolled cryptography** (all crypto delegates to Mo's OpenSSL 3 `libcrypto` `Crypto` module), and **your choice of storage backend**: **SQLite** (built-in, zero external dependencies), [**MoDB**](https://github.com/robertguss/modb) (pure-Mo CoW B+Tree + hash-chained ledger + agent coordination), or a **hybrid** of both.

---

## Philosophy

- **Quiet & Explicit:** No hidden ORM magic, no ambient global mutable state, and no separate Node runtime in production. `mo serve` serves both your Inertia HTML/JSON routes and immutable hashed Vite assets from one binary.
- **Storage-Agnostic Web Core:** Cookies, AEAD session tokens, double-submit CSRF, scrypt auth, flash bags, multipart forms, changesets, Inertia v2, and `WebTest` share zero database coupling.
- **Fail-Closed Security by Default:**
  - Encrypted, revocable sessions (`AES-256-GCM` sealed cookies with `HttpOnly`, `Secure`, `SameSite=Lax`; SHA-256 token digests on disk).
  - Double-submit `XSRF-TOKEN` / `X-XSRF-TOKEN` CSRF protection verified in constant time.
  - Password hashing via OpenSSL 3 `EVP_PBE_scrypt` (`N=32768, r=8, p=1`).
  - Capability-confined outbound HTTP (`network.allow_hosts([...])`), symlink-confined static mounts (`openat2(RESOLVE_BENEATH)`), and least-privilege `ReadFiles` reads when using MoDB.
- **Testable Without Flakes:** Every route, cookie jar, CSRF token, Inertia page prop, multipart upload, migration, audit log, and scheduled background job runs deterministically in memory with `Arvo.WebTest`, `ApiTest.send`, and `ApiTest.run_job`.

---

## Choosing a Storage Backend

1. **SQLite (`Arvo.Sqlite.*`, zero external deps — default):** Best for relational schemas (joins, foreign keys, `GROUP BY` aggregates), `mo serve`'s built-in `sqlite` pooling and `arvo_jobs` runner, and external `sqlite3` / Litestream tooling.
2. **MoDB (`packages/arvo-modb` + [`robertguss/modb`](https://github.com/robertguss/modb)):** Best for pure-Mo memory safety (zero C DB code), host-enforced `ReadFiles`-only `GET` routes, per-page SHA-256 integrity, tamper-evident hash-chained `Modb.Ledger` audits, selective-undo `Modb.Replay`, and multi-agent `Grants`/`Claims`/`Worlds`/`Views`.
3. **Hybrid:** Keep high-churn ephemeral sessions and `mo serve`-polled `arvo_jobs` in SQLite while keeping your audited, agent-accessible domain data in `Modb.Ledger`.

---

## Modules

In Mo, `use Arvo.<...>.<Name>` binds the final segment `<Name>`.

### Core Web Modules (`lib/arvo/*.mo`, DB-agnostic)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Id` | `Id` | Lexicographically time-ordered 26-character Crockford Base32 ULID generator (`Id.ulid`). |
| `Arvo.Cookie` | `Cookie` | RFC 6265 cookie parsing & safe `Set-Cookie` emission (`HttpOnly`, `Secure`, `SameSite`, `Max-Age`). |
| `Arvo.Session` | `Session` | Storage-agnostic `Session` / `SessionConfig` types, `AES-256-GCM` cookie sealing/unsealing, and constant-time hash/expiry verification. |
| `Arvo.Csrf` | `Csrf` | Constant-time double-submit `XSRF-TOKEN` / `X-XSRF-TOKEN` verification. |
| `Arvo.Auth` | `Auth` | Email allowlist helpers, scrypt hashing/verification, `login_response` / `logout_response`, `require_csrf`. |
| `Arvo.Flash` | `Flash` | Single-hop AES-256-GCM encrypted flash cookie carrying `notice`, `alert`, and validation error bags. |
| `Arvo.Form` | `Form` | Bounded `application/x-www-form-urlencoded` and `multipart/form-data` parsers (for CSV/file uploads). |
| `Arvo.Changeset` | `Changeset` | Composable pure validation pipelines producing Inertia-ready field error maps. |
| `Arvo.Inertia` | `Inertia` | Full Inertia v2 server protocol: HTML shell + `data-page` escaping, XHR JSON, Vite manifest & dev HMR, `409` version check, partial reloads (`X-Inertia-Partial-Data`), typed `render_page` / `PageContract` manifest helpers, `303` redirects. |
| `Arvo.Oidc` | `Oidc` | OpenID Connect / OAuth 2.0 Authorization Code + PKCE (`S256`) client, discovery, AEAD state cookies, and domain allowlists. |
| `Arvo.S3` | `S3` | Pure-Mo AWS Signature Version 4 presigned URLs (`PUT`/`GET`/`DELETE`) and signed requests for S3, R2, and MinIO. |
| `Arvo.WebTest` | `WebTest` | DB-agnostic in-memory browser & fluent `ApiTest.App` test harness with automatic cookie jar, `X-XSRF-TOKEN` injection, `data-page` / Inertia JSON parser, and Vitest fixture export (`record_inertia_fixture`). |
| `Arvo.Snapshot` | `Snapshot` | Tamper-guarded golden snapshot testing (`Snapshot.expect_json` / `expect_text`) with `ARVO_UPDATE_SNAPSHOTS` gate and automatic secret redaction. |
| `Arvo.Props` | `Props` | Property-based testing helpers (`forall`, shrinking generators) integrating directly with `mo test`. |

### SQLite Backend (`lib/arvo/sqlite/*.mo`, zero external deps)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Sqlite.Sessions` | `Sessions` | Revocable `arvo_sessions` SQLite table + transactional `Sessions.rotate`. |
| `Arvo.Sqlite.Migrations` | `Migrations` | Forward-only transactional SQLite schema migrations (`_arvo_migrations`) with SHA-256 checksum drift detection. |
| `Arvo.Sqlite.Audit` | `Audit` | Append-only `arvo_events` audit trail (`actor`, `action`, `before_json`, `after_json`, `undo_json`) and optimistic concurrency helper (`ensure_updated`). |
| `Arvo.Sqlite.Jobs` | `Jobs` | Durable SQLite `arvo_jobs` queue: transaction-composable `enqueue` / `enqueue_at`, atomic `BEGIN IMMEDIATE` `claim_next`, exponential backoff retries, stale-lock recovery (polled automatically by `mo serve`). |

### Testing & Verification Modules (`lib/arvo/testing/*.mo`, SQLite-backed)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Testing.SqliteTest` | `SqliteTest` | Per-route SQLite query-count budget assertions (`check_max_queries`, `expect_max_queries`). |
| `Arvo.Testing.Seed` | `Seed` | Deterministic seed profile registry shared across `Sqlite.in_memory()` tests, `Arvo.Testing.Sim`, `arvo control`, and local dev. |
| `Arvo.Testing.SecurityMatrix` | `SecurityMatrix` | Zero-config fail-closed route auditor checking auth, CSRF, XSS, open redirects, Inertia versions, strict JSON, SQLite `PRAGMA foreign_keys`, migration tamper, and N+1 budgets. |
| `Arvo.Testing.Feature` | `Feature` | Unified Executable Feature Map (`.feature.md`) parser, in-memory `WebTest` runner, and `@browser` JSON manifest exporter for Playwright execution. |
| `Arvo.Testing.Sim` | `Sim` | Deterministic Web Simulation Testing (DST) engine driving real `ApiTest.App` routes, fake `Clock`, `Arvo.Sqlite.Jobs` retries/crashes, session rotation/replay, invariants, and delta-shrinking. |
| `Arvo.Testing.Statechart` | `Statechart` | Pure-Mo bounded BFS statechart explorer with Mermaid `stateDiagram-v2` output and built-in formal models + real-code replay for `Arvo.Sqlite.Jobs`, `Arvo.Sqlite.Sessions`, and `Arvo.Session`. |
| `Arvo.Testing.Replay` | `Replay` | Offline sanitized failure capture (stripping cookies, `Authorization`, CSRF tokens, and secret env vars) and standalone regression test generator. |

### MoDB Companion Package (`packages/arvo-modb/`, requires sibling `modb`)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Modb.Sessions` | `Sessions` | Layer 2 `Modb.Table` `_arvo_sessions` store with lock-free `ReadFiles`-only `load_read_only` for `GET` routes, throttled `last_seen_at` updates in `load`, and atomic `rotate`. |
| `Arvo.Modb.Jobs` | `Jobs` | Layer 2 `Modb.Table` `_arvo_jobs` queue with indexed `(state, run_at)` due-job claims, `WriteTx`-composable `tx_enqueue` (works inside `Modb.Ledger.transact`), exponential backoff retries, and stale recovery. |

*(Migrations, hash-chained audits, commit-time invariants, selective-undo replay, and agent grants/worlds/views use native `Modb.Ledger`, `Modb.Replay`, and MoDB Layer 4 directly.)*

---

## Quick Start

Requires [**Mo 0.3.0+**](https://github.com/robertguss/mo).

### Option A: SQLite Backend (`examples/arvo-starter`)

Add `arvo` in `mo.toml`:

```toml
[package]
name = "my-app"
version = "0.2.0"

[dependencies]
arvo = { path = "../arvo" }
```

Declare your `api` server:

```mo
module Main
use Api
use Routes

api
  port 8080
  sqlite db from "data/app.db"
  static "/assets" from "public/assets"
  auth Routes.Member via Routes.authenticate

  job "sync.refresh" Jobs.Sync.run every 15.minutes

  get "/login" Routes.show_login
  post "/login" Routes.post_login
  post "/logout" Routes.post_logout
  get "/" Routes.home

  scope "/items"
    post "" Routes.create_item
  end
end
```

### Option B: MoDB Backend (`examples/arvo-modb-starter`)

Add `arvo`, `arvo-modb`, and [`modb`](https://github.com/robertguss/modb) in `mo.toml`:

```toml
[package]
name = "my-modb-app"
version = "0.2.0"

[dependencies]
arvo = { path = "../arvo" }
arvo-modb = { path = "../arvo/packages/arvo-modb" }
modb = { path = "../modb" }
```

Declare your `api` server with **no `sqlite` clause** (`GET` routes only need `ReadFiles`):

```mo
module Main
use Api
use Routes

api
  port 8080
  static "/assets" from "public/assets"
  auth Routes.Member via Routes.authenticate

  job "arvo.jobs.drain" Routes.drain_jobs every 10.seconds

  get "/login" Routes.show_login
  post "/login" Routes.post_login
  post "/logout" Routes.post_logout
  get "/" Routes.home
end
```

### Run the Inertia v2 Starters

See [`examples/arvo-starter`](examples/arvo-starter/README.md) (SQLite) or [`examples/arvo-modb-starter`](examples/arvo-modb-starter/README.md) (MoDB).

**Development (Vite HMR + `mo serve --watch`):**
```bash
# Terminal 1
cd examples/arvo-starter/frontend && npm install && npm run dev

# Terminal 2
cd examples/arvo-starter
VITE_DEV_URL="http://127.0.0.1:5173" \
ARVO_INSECURE_COOKIES=1 \
mo serve main.mo --bind 127.0.0.1 --port 8080 --watch
```

**Production (Single-Binary `mo serve`):**
```bash
cd examples/arvo-starter/frontend && npm run build
cd ..
ARVO_SECRET_KEY="$(openssl rand -hex 32)" \
mo serve main.mo --bind 127.0.0.1 --port 8080
```

---

## Verification & Testing (`arvo` CLI & `.arvo/skills/`)

Arvo ships a pure-Mo verification CLI ([`cmd/arvo/main.mo`](cmd/arvo/main.mo)) and bundled workflow skills under [`.arvo/skills/`](.arvo/skills/):

```bash
mo run cmd/arvo/main.mo
# Or install the executable and invoke it from the repo root
mo install --name arvo cmd/arvo/main.mo
arvo verify --app examples/arvo-starter --tier fast
```

Key CLI subcommands:
- `arvo verify [--app DIR] [--tier fast|feature|full] [--json] [--base REF]` — run tiered verification checks + tamper checks and write `.arvo/dossier/verify.jsonl`
- `arvo contracts [--app DIR] [--check]` — generate or verify `frontend/src/arvo.gen.ts` from `Json.schema[T]()`
- `arvo feature [--app DIR] [--validate] [--manifest OUT] [DIR]` — validate `.feature.md` Executable Feature Maps and export `@browser` manifests
- `arvo sim [--app DIR] [--entry FILE] [--only NAME]` — run `Arvo.Testing.Sim` deterministic simulation tests
- `arvo control <sha|launch|doctor|inspect|reset|drive|screenshot|record|cleanup> [--app DIR]` — manage isolated runtime instances and capture browser evidence for verification and debugging
- `arvo statechart [check|render] [--app DIR] [--out DIR]` — explore/replay `Arvo.Sqlite.Jobs` and `Arvo.Sqlite.Sessions` / `Arvo.Session` statecharts and check sync commits
- `arvo replay <capture|gen> [--app DIR]` — capture sanitized failure bundles and generate standalone regression tests
- `arvo bench --baseline-cmd A --candidate-cmd B` — alternating `A/B/A/B` benchmark harness
- `arvo dossier [--app DIR] [--open]` — render the static HTML Verification Dossier and `<150`-word `pr-summary.md`
- `arvo log [--app DIR] --phase P --decision D ...` — append a sanitized decision row to `.arvo/dossier/decisions.tsv`

Bundled agent workflows in [`.arvo/skills/`](.arvo/skills/): `arvo-verify`, `arvo-maintain-specs`, `arvo-statechart`, `arvo-bug-repro`, and `arvo-correct`.

---

## Running the Test Suite

```bash
# Core + SQLite + Testing + examples/arvo-starter (automatically runs MoDB suite if ../modb exists)
./scripts/test.sh

# Explicitly select a MoDB checkout, overriding any sibling checkout
MODB_PATH=/path/to/modb ./scripts/test.sh
```

This enforces that core `lib/arvo/*.mo` modules remain SQLite-free, checks and tests all core `lib/arvo/*.mo`, SQLite backend `lib/arvo/sqlite/*.mo`, SQLite testing `lib/arvo/testing/*.mo`, fixture `lib/arvo/fixtures/*.mo`, `cmd/arvo/main.mo`, and `examples/arvo-starter/main.mo` targets, validates starter Executable Feature Maps (`arvo feature --validate`), contract sync (`arvo contracts --check`), statechart models (`arvo statechart check`), and `arvo replay capture/gen` codegen, executes all 9 `--strength` intent suites (requiring `kill_rate == 1` and `0` survived mutants), and (when `modb` is available) runs `packages/arvo-modb/lib/arvo/modb/*.mo` and `examples/arvo-modb-starter/main.mo`.

---

## Documentation

- [Architecture & Roadmap](docs/arvo-plan.md)
- [Framework Specification](docs/arvo-spec.md)
- [Testing & Verification Architecture](docs/arvo-testing-plan.md)
- [Testing & Verification Specification](docs/arvo-testing-spec.md)
- [SQLite Starter App Guide](examples/arvo-starter/README.md)
- [MoDB Starter App Guide](examples/arvo-modb-starter/README.md)

## License

[MIT](LICENSE)
