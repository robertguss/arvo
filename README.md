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
| `Arvo.Inertia` | `Inertia` | Full Inertia v2 server protocol: HTML shell + `data-page` escaping, XHR JSON, Vite manifest & dev HMR, `409` version check, partial reloads (`X-Inertia-Partial-Data`), `303` redirects. |
| `Arvo.WebTest` | `WebTest` | In-memory browser test harness with automatic cookie jar, `X-XSRF-TOKEN` injection, and `data-page` / Inertia JSON parser. |

### SQLite Backend (`lib/arvo/sqlite/*.mo`, zero external deps)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Sqlite.Sessions` | `Sessions` | Revocable `arvo_sessions` SQLite table + transactional `Sessions.rotate`. |
| `Arvo.Sqlite.Migrations` | `Migrations` | Forward-only transactional SQLite schema migrations (`_arvo_migrations`) with SHA-256 checksum drift detection. |
| `Arvo.Sqlite.Audit` | `Audit` | Append-only `arvo_events` audit trail (`actor`, `action`, `before_json`, `after_json`, `undo_json`) and optimistic concurrency helper (`ensure_updated`). |
| `Arvo.Sqlite.Jobs` | `Jobs` | Durable SQLite `arvo_jobs` queue: transaction-composable `enqueue` / `enqueue_at`, atomic `BEGIN IMMEDIATE` `claim_next`, exponential backoff retries, stale-lock recovery (polled automatically by `mo serve`). |

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

## Running the Test Suite

```bash
# Core + SQLite + examples/arvo-starter (automatically runs MoDB suite if ../modb exists)
./scripts/test.sh

# Explicitly select a MoDB checkout, overriding any sibling checkout
MODB_PATH=/path/to/modb ./scripts/test.sh
```

This checks and tests all core `lib/arvo/*.mo` modules, all `lib/arvo/sqlite/*.mo` modules, `examples/arvo-starter/main.mo`, and (when `modb` is available) `packages/arvo-modb/lib/arvo/modb/*.mo` plus `examples/arvo-modb-starter/main.mo`.

---

## Documentation

- [Architecture & Roadmap](docs/arvo-plan.md)
- [Framework Specification](docs/arvo-spec.md)
- [SQLite Starter App Guide](examples/arvo-starter/README.md)
- [MoDB Starter App Guide](examples/arvo-modb-starter/README.md)

## License

[MIT](LICENSE)
