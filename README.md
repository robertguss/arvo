# Arvo

**Arvo** (named after composer Arvo Pärt) is a calm, batteries-included web framework for [**Mo**](https://github.com/robertguss/mo), inspired by Phoenix, Ash, and Inertia.js.

Build full-stack, single-binary web applications backed by **SQLite** (WAL mode + `FOREIGN KEY` enforcement + typed `Sqlite.decode[T]`), **Inertia v2** (`@inertiajs/react` + React 19 + TypeScript + Vite + Tailwind CSS v4), **capability-confined durable background jobs**, and **zero hand-rolled cryptography** (all crypto delegates to Mo's OpenSSL 3 `libcrypto` `Crypto` module).

---

## Philosophy

- **Quiet & Explicit:** No hidden ORM magic, no ambient global mutable state, and no separate Node runtime in production. `mo serve` serves both your Inertia HTML/JSON routes and immutable hashed Vite assets from one binary.
- **Fail-Closed Security by Default:**
  - Encrypted, revocable SQLite-backed sessions (`AES-256-GCM` sealed cookies with `HttpOnly`, `Secure`, `SameSite=Lax`).
  - Double-submit `XSRF-TOKEN` / `X-XSRF-TOKEN` CSRF protection verified in constant time.
  - Password hashing via OpenSSL 3 `EVP_PBE_scrypt` (`N=32768, r=8, p=1`).
  - Capability-confined outbound HTTP (`network.allow_hosts([...])`), symlink-confined static mounts (`openat2(RESOLVE_BENEATH)`), and parameterized SQL queries.
- **Testable Without Flakes:** Every route, cookie jar, CSRF token, Inertia page prop, multipart upload, database migration, and scheduled background job runs deterministically in memory with `Arvo.WebTest`, `ApiTest.run_job`, and `Arvo.Sim`, backed by `Arvo.SecurityMatrix`, `Arvo.Statechart`, and the pure-Mo `arvo` verification CLI (`arvo verify`, `arvo dossier`).

---

## Modules (`lib/arvo/*.mo`)

All 20 `lib/arvo/*.mo` modules (12 core framework modules and 8 testing, simulation & formal verification modules). In Mo, `use Arvo.<Name>` binds the final segment `<Name>`:

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Cookie` | `Cookie` | RFC 6265 cookie parsing & safe `Set-Cookie` emission (`HttpOnly`, `Secure`, `SameSite`, `Max-Age`). |
| `Arvo.Session` | `Session` | AES-256-GCM encrypted cookies + revocable `arvo_sessions` SQLite table + session rotation (`Session.rotate`). |
| `Arvo.Csrf` | `Csrf` | Constant-time double-submit `XSRF-TOKEN` / `X-XSRF-TOKEN` verification. |
| `Arvo.Auth` | `Auth` | Email allowlist helpers, scrypt hashing/verification, `login_response` / `logout_response`, `require_csrf`. |
| `Arvo.Flash` | `Flash` | Single-hop AES-256-GCM encrypted flash cookie carrying `notice`, `alert`, and validation error bags. |
| `Arvo.Form` | `Form` | Bounded `application/x-www-form-urlencoded` and `multipart/form-data` parsers (for CSV/file uploads). |
| `Arvo.Changeset` | `Changeset` | Composable pure validation pipelines producing Inertia-ready field error maps. |
| `Arvo.Inertia` | `Inertia` | Full Inertia v2 server protocol: HTML shell + `data-page` escaping, XHR JSON, Vite manifest & dev HMR, `409` version check, partial reloads (`X-Inertia-Partial-Data`), `303` redirects. |
| `Arvo.Migrations` | `Migrations` | Forward-only transactional SQLite schema migrations (`arvo_migrations`) with SHA-256 checksum drift detection. |
| `Arvo.Audit` | `Audit` | ULID event IDs, append-only `arvo_events` audit trail (`actor`, `action`, `before_json`, `after_json`, `undo_json`), and optimistic concurrency helper (`ensure_updated`). |
| `Arvo.Jobs` | `Jobs` | Durable SQLite `arvo_jobs` queue: transaction-composable `enqueue` / `enqueue_at`, atomic `BEGIN IMMEDIATE` `claim_next`, exponential backoff retries, stale-lock recovery (polled automatically by `mo serve`). |
| `Arvo.WebTest` | `WebTest` | In-memory browser test harness with automatic cookie jar, `X-XSRF-TOKEN` injection, and `data-page` / Inertia JSON parser. |
| `Arvo.Seed` | `Seed` | Deterministic seed profile registry shared across `Sqlite.in_memory()` tests, `Arvo.Sim`, `arvo control launch --seed`, and local development. |
| `Arvo.Snapshot` | `Snapshot` | Tamper-guarded golden JSON and text snapshot assertions with deterministic key sorting and volatile-field redaction (`ARVO_UPDATE_SNAPSHOTS=1` to update baselines). |
| `Arvo.Props` | `Props` | Reusable algebraic property helpers (`round_trip?`, `idempotent?`, `involution?`, etc.) composable inside Mo `promise` and `test` blocks. |
| `Arvo.SecurityMatrix` | `SecurityMatrix` | Zero-config fail-closed adversarial route auditor deriving route, auth, CSRF, XSS, open-redirect, Inertia version, strict JSON, FK, migration, and N+1 checks from `app.routes()` and `app.openapi_json()`. |
| `Arvo.Sim` | `Sim` | Deterministic Web Simulation Testing (DST) engine driving real `ApiTest.App` routes, fake `Clock`, `Arvo.Jobs` retries/crashes, session rotation/replay, per-step invariants, and delta-shrinking. |
| `Arvo.Feature` | `Feature` | Unified Executable Feature Map (`.feature.md`) parser, in-memory `WebTest` runner, and `@browser` JSON manifest exporter for Playwright execution. |
| `Arvo.Statechart` | `Statechart` | Pure-Mo bounded BFS statechart explorer with Mermaid `stateDiagram-v2` output and built-in formal models + real-code replay for `Arvo.Jobs` and `Arvo.Session`. |
| `Arvo.Replay` | `Replay` | Offline sanitized failure capture (stripping cookies, `Authorization`, CSRF tokens, and secret env vars) and standalone regression test generator. |

---

## Quick Start

### 1. Add Arvo via `mo.toml`

Requires [**Mo 0.3.0+**](https://github.com/robertguss/mo):

```toml
[package]
name = "my-app"
version = "0.1.0"

[dependencies]
arvo = { path = "../arvo" }
```

### 2. Declare Your `api` Server

```mo
module Main
use Api
use Arvo.Inertia
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

### 3. Run the Included Inertia v2 Starter

See [`examples/arvo-starter`](examples/arvo-starter/README.md) for a complete working React 19 + TypeScript + Vite + Tailwind CSS v4 + Arvo app.

**Development (Vite HMR + `mo serve --watch`):**
```bash
# Terminal 1
cd examples/arvo-starter/frontend && npm install && npm run dev

# Terminal 2
cd examples/arvo-starter
ARVO_VITE_DEV_URL="http://127.0.0.1:5173" \
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
mo run cmd/arvo/main.mo --help
# Or install/invoke `arvo` directly once built
arvo verify --app examples/arvo-starter --tier fast|feature|full
```

Key CLI subcommands:
- `arvo verify [--app DIR] [--tier fast|feature|full] [--json] [--base REF]` — run tiered verification checks + tamper checks and write `.arvo/dossier/verify.jsonl`
- `arvo contracts [--app DIR] [--check]` — generate or verify `frontend/src/arvo.gen.ts` from `Json.schema[T]()`
- `arvo feature [--app DIR] [--validate] [--manifest OUT] [DIR]` — validate `.feature.md` Executable Feature Maps and export `@browser` manifests
- `arvo sim [--app DIR] [--entry FILE] [--only NAME]` — run `Arvo.Sim` deterministic simulation suites
- `arvo control <sha|launch|doctor|inspect|reset|drive|screenshot|record|cleanup> [--app DIR]` — manage isolated runtime instances and capture browser evidence for verification and debugging
- `arvo statechart [check|render] [--app DIR] [--out DIR]` — explore/replay `Arvo.Jobs` and `Arvo.Session` statecharts and check sync commits
- `arvo replay <capture|gen> [--app DIR]` — capture sanitized failure bundles and generate standalone regression tests
- `arvo bench --baseline-cmd A --candidate-cmd B` — alternating `A/B/A/B` benchmark harness
- `arvo dossier [--app DIR] [--open]` — render the static HTML Verification Dossier and `<150`-word `pr-summary.md`
- `arvo log [--app DIR] --phase P --decision D ...` — append a sanitized decision row to `.arvo/dossier/decisions.tsv`

Bundled agent workflows in [`.arvo/skills/`](.arvo/skills/): `arvo-verify`, `arvo-maintain-specs`, `arvo-statechart`, `arvo-bug-repro`, and `arvo-correct`.

---

## Running the Test Suite

```bash
./scripts/test.sh
```

This runs `mo check` and `mo test` across all 20 `lib/arvo/*.mo` modules, `mo check` on `lib/arvo/fixtures/*.mo`, `cmd/arvo/main.mo`, and `examples/arvo-starter/main.mo`, validates Executable Feature Maps (`arvo feature --validate`), contract sync (`arvo contracts --check`), statechart models (`arvo statechart check`), and executes all 9 `--strength` intent-mutation suites (requiring `kill_rate == 1` and `0` survived mutants).

---

## Documentation

- [Architecture & Roadmap](docs/arvo-plan.md)
- [Framework Specification](docs/arvo-spec.md)
- [Testing & Verification Architecture](docs/arvo-testing-plan.md)
- [Testing & Verification Specification](docs/arvo-testing-spec.md)
- [Starter App Guide](examples/arvo-starter/README.md)

## License

[MIT](LICENSE)
