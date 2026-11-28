# Arvo

**Arvo** (named after composer Arvo Pärt) is a calm, batteries-included web framework for [**Mo**](https://github.com/robertguss/mo), inspired by Phoenix, Ash, and Inertia.js.

Build full-stack, single-binary web applications with **Inertia v2** (`@inertiajs/react` + React 19 + TypeScript + Vite + Tailwind CSS v4), **native batteries-included authentication** (`Arvo.Auth`, sessions, CSRF, WebAuthn passkeys, TOTP + recovery codes, API keys, organizations/RBAC, sudo mode), **pure-Mo/OpenSSL 3 cryptography**, and **your choice of storage backend**: **SQLite** (built-in, zero external dependencies), [**MoDB**](https://github.com/robertguss/modb) (pure-Mo CoW B+Tree + hash-chained ledger + BM25+/vector search + time-travel replay + speculative agent worlds), or a **hybrid** of both.

---

## Philosophy

- **Quiet & Explicit:** No hidden ORM magic, no ambient global mutable state, and no separate Node runtime in production. `mo serve` serves your Inertia HTML/JSON routes, real-time SSE streams, MCP endpoint, background jobs, and immutable hashed Vite assets from one binary.
- **Storage-Agnostic Web Core:** Cookies, AEAD/HMAC tokens, double-submit CSRF, scrypt/TOTP/WebAuthn auth, flash bags, multipart & presigned uploads, changesets, Inertia v2, live SSE, Dev Dashboard, and `WebTest` live in `lib/arvo/*.mo` with zero SQLite or MoDB coupling.
- **Fail-Closed Security by Default:**
  - `AES-256-GCM` sealed session cookies (`HttpOnly`, `Secure`, `SameSite=Lax`) backed by `SHA-256` token digests on disk and key-rotation `Arvo.Keyring`.
  - Constant-time double-submit `XSRF-TOKEN` / `X-XSRF-TOKEN` CSRF protection.
  - Password hashing via OpenSSL 3 `EVP_PBE_scrypt` (`N=32768, r=8, p=1`), hardware passkeys (`ES256`/`RS256` SPKI), RFC 6238 TOTP MFA + single-use recovery codes, and strict security headers (`Arvo.Security`).
  - Magic-byte file upload validation blocking disguised HTML/XSS & SVG payloads by default (`Arvo.Uploads`), plus fail-closed `/__arvo` Dev Dashboard (`404` unless `ARVO_DEV=1`).
- **Testable Without Flakes:** Every route, session, MFA ceremony, upload, migration, audit log, selective undo replay, and background job runs deterministically in memory with `Arvo.WebTest`, `ApiTest.send`, `Arvo.Testing.Sim`, and `Arvo.Testing.SecurityMatrix`.

---

## Choosing a Storage Backend

1. **SQLite (`Arvo.Sqlite.*`, zero external deps — default):** Best for relational joins, foreign keys, `GROUP BY` aggregates, and external `sqlite3` / Litestream tooling.
2. **MoDB (`packages/arvo-modb` + [`robertguss/modb`](https://github.com/robertguss/modb)):** Best for pure-Mo memory safety, lock-free `ReadFiles`-only `GET` routes, tamper-evident hash-chained `Modb.Ledger` audits, selective-undo time-travel (`Arvo.Modb.TimeTravel`), BM25+/vector search (`Arvo.Modb.Search`), reactive SSE feeds (`Arvo.Modb.LiveFeeds`), and encrypted S3 delta replication (`Arvo.Modb.Backup`).
3. **Hybrid:** Keep high-churn ephemeral state in SQLite while persisting audited domain records and agent workspaces in `Modb.Ledger`.

---

## Modules

In Mo, `use Arvo.<...>.<Name>` binds the final segment `<Name>`.

### Core Web & Auth Modules (`lib/arvo/*.mo`, DB-agnostic)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Id` | `Id` | Lexicographically time-ordered 26-character Crockford Base32 ULID generator (`Id.ulid`). |
| `Arvo.Cookie` | `Cookie` | RFC 6265 cookie parsing & safe `Set-Cookie` emission (`HttpOnly`, `Secure`, `SameSite`, `Max-Age`). |
| `Arvo.Keyring` | `Keyring` | Versioned `AES-256-GCM` key rotation, key derivation, and `ENV` secret parsing. |
| `Arvo.Session` | `Session` | `AES-256-GCM` sealed sessions, sliding expiry, MFA verified timestamps, and sudo mode helpers. |
| `Arvo.Csrf` | `Csrf` | Constant-time double-submit `XSRF-TOKEN` / `X-XSRF-TOKEN` verification. |
| `Arvo.Security` | `Security` | Fail-closed OWASP security headers, CSP script-nonce generation, HSTS, and `X-Frame-Options`. |
| `Arvo.Auth` | `Auth` | scrypt hashing, allowlists, email verification/reset tokens, sudo/MFA gates, and login/logout responses. |
| `Arvo.Totp` | `Totp` | RFC 6238 TOTP (`SHA-1`/`256`/`512`) provisioning URIs, replay windowing, and recovery codes. |
| `Arvo.Webauthn` | `Webauthn` | FIDO2/WebAuthn passkey registration/assertion ceremony verification (`ES256`/`RS256`). |
| `Arvo.ApiTokens` | `ApiTokens` | Prefix-identifiable bearer API keys with SHA-256 digests and scoped authorization checks. |
| `Arvo.Orgs` | `Orgs` | Multi-tenant organizations, workspace memberships, role hierarchies, and invite tokens. |
| `Arvo.Policy` | `Policy` | Declarative RBAC / resource authorization & fail-closed default-deny permission checks. |
| `Arvo.AuthKit` | `AuthKit` | Turnkey Inertia v2 auth, MFA, passkey, and security settings route/controller helpers. |
| `Arvo.Oidc` | `Oidc` | OpenID Connect / OAuth 2.0 Authorization Code + PKCE (`S256`) client and discovery. |
| `Arvo.RateLimit` | `RateLimit` | Storage-agnostic fixed-window rate-limiting evaluator and bucket key helpers. |
| `Arvo.Flash` | `Flash` | Single-hop `AES-256-GCM` encrypted flash cookie (`notice`, `alert`, validation error bags). |
| `Arvo.Form` | `Form` | Bounded `application/x-www-form-urlencoded` and binary `multipart/form-data` parsers. |
| `Arvo.Uploads` | `Uploads` | Magic-byte MIME sniffing, HTML/XSS & SVG rejection, per-owner quotas, confined local storage, safe download headers, and SigV4 S3 presigning. |
| `Arvo.Changeset` | `Changeset` | Composable pure validation pipelines producing Inertia-ready field error maps. |
| `Arvo.Pagination` | `Pagination` | Keyset cursor pagination contracts shared across SQLite and MoDB stores. |
| `Arvo.Inertia` | `Inertia` | Inertia v2 protocol: escaped HTML shell, Vite manifest/HMR, `409` reload, partial reloads, `PageContract` schemas. |
| `Arvo.Web` | `Web` | Ergonomic Inertia/JSON route helpers combining CSRF, rate limiting, flash, and CSP nonces. |
| `Arvo.Mail` | `Mail` | Transactional email across Resend, Postmark, AWS SES (SigV4), webhooks, and local `DevMailbox`. |
| `Arvo.S3` | `S3` | Pure-Mo AWS Signature Version 4 presigned `PUT`/`GET`/`DELETE` and signed `Http.Request` builder. |
| `Arvo.Sse` | `Sse` | Server-Sent Events encoder, field-injection sanitization, keepalives, and upstream `relay`. |
| `Arvo.Live` | `Live` | Real-time topics, `inertia.reload` broadcasts (`2xx` + `302`/`303`/`307`/`308`), and OpenAI/Anthropic/raw LLM SSE relays. |
| `Arvo.Action` | `Action` | Single-definition workflows executing across HTTP, background jobs, and MCP tools. |
| `Arvo.Mcp` | `Mcp` | Streamable HTTP MCP (`2025-03-26`) JSON-RPC 2.0 server with scope-checked tools and resources. |
| `Arvo.Webhooks` | `Webhooks` | Signed outbound HMAC-SHA256 webhooks with replay-window verification and backoff calculation. |
| `Arvo.Health` | `Health` | `/healthz` liveness and `/readyz` readiness probes. |
| `Arvo.DevDashboard` | `DevDashboard` | Fail-closed `/__arvo` UI & JSON inspector (overview, Dev Mailbox, Audit, and Replay tabs). |
| `Arvo.WebTest` | `WebTest` | In-memory HTTP/Inertia test browser with cookie jar, `X-XSRF-TOKEN`, and Vitest fixture export. |
| `Arvo.Snapshot` | `Snapshot` | Tamper-guarded golden JSON/text snapshots with `ARVO_UPDATE_SNAPSHOTS=1` gating and redaction. |
| `Arvo.Props` | `Props` | Property-based testing helpers (`forall`, shrinking generators) integrating with `mo test`. |
| `Arvo.SecurityMatrixCore` | `SecurityMatrixCore` | Storage-agnostic route security matrix auditor shared by SQLite and MoDB harnesses. |

### SQLite Backend (`lib/arvo/sqlite/*.mo`, zero external deps)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Sqlite.Sessions` | `Sessions` | Revocable `arvo_sessions` store + transactional session rotation. |
| `Arvo.Sqlite.AuthStore` | `AuthStore` | Auth v2 users, password resets, email verification, TOTP/recovery codes, WebAuthn credentials, API tokens, and org memberships. |
| `Arvo.Sqlite.Migrations` | `Migrations` | Forward-only transactional migrations (`_arvo_migrations`) with SHA-256 drift detection. |
| `Arvo.Sqlite.Audit` | `Audit` | Append-only `arvo_events` audit trail and optimistic concurrency helpers. |
| `Arvo.Sqlite.Jobs` | `Jobs` | Durable `arvo_jobs` queue with `BEGIN IMMEDIATE` claim, exponential backoff, and stale recovery. |
| `Arvo.Sqlite.RateLimit` | `RateLimit` | Durable `arvo_rate_limits` fixed-window counters and indexed expiry pruning. |
| `Arvo.Sqlite.Uploads` | `Uploads` | Durable `arvo_uploads` metadata, owner quota accounting, and orphan blob sweeping. |

### Testing & Verification Modules (`lib/arvo/testing/*.mo`, SQLite-backed)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Testing.SqliteTest` | `SqliteTest` | Per-route SQLite query-count budget assertions (`check_max_queries`, `expect_max_queries`). |
| `Arvo.Testing.Seed` | `Seed` | Deterministic seed profile registry shared across unit tests, `Sim`, `control`, and dev. |
| `Arvo.Testing.SecurityMatrix` | `SecurityMatrix` | Zero-config route security auditor across auth, CSRF, XSS, open redirects, headers, and N+1 budgets. |
| `Arvo.Testing.Feature` | `Feature` | `.feature.md` Executable Feature Map parser and Playwright `@browser` manifest exporter. |
| `Arvo.Testing.Sim` | `Sim` | Deterministic Web Simulation Testing driving real routes, fake clocks, crash/retry jobs, and shrinking. |
| `Arvo.Testing.Statechart` | `Statechart` | Bounded BFS statechart explorer + real-code replay for Jobs, Sessions, and Auth. |
| `Arvo.Testing.Replay` | `Replay` | Offline sanitized failure bundle capture and standalone regression test generator. |

### MoDB Companion Package (`packages/arvo-modb/`, requires sibling `modb`)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Modb.Sessions` | `Sessions` | `_arvo_sessions` store with lock-free `ReadFiles` `load_read_only`, throttled `last_seen_at`, and atomic `rotate`. |
| `Arvo.Modb.AuthStore` | `AuthStore` | Full Auth v2 store (users, TOTP/recovery, WebAuthn passkeys, API keys, orgs) inside `Modb.Ledger`. |
| `Arvo.Modb.Jobs` | `Jobs` | Indexed `_arvo_jobs` queue with `WriteTx`-composable `tx_enqueue`, backoff retries, and stale recovery. |
| `Arvo.Modb.RateLimit` | `RateLimit` | Layer 2 `_arvo_rate_limits` rate limiter with O(expired) indexed cleanup. |
| `Arvo.Modb.Uploads` | `Uploads` | Layer 2 `_arvo_uploads` metadata store with `ReadFiles` quota sums and local+DB orphan sweeping. |
| `Arvo.Modb.Search` | `Search` | Transaction-composable BM25+ full-text + vector `ReadFiles` search wrapper over `Modb.Fts`. |
| `Arvo.Modb.LiveFeeds` | `LiveFeeds` | Bridges `Modb.Feeds` O(diff) commit deltas with `Arvo.Live` SSE streams and `inertia.reload`. |
| `Arvo.Modb.Backup` | `Backup` | Sealed S3/local encrypted snapshot backup, verify, restore, and delta sync presets over `Modb.Sync`. |
| `Arvo.Modb.Inspector` | `Inspector` | `ReadFiles`-only snapshot collector powering `/__arvo` Overview, Audit, and Replay views. |
| `Arvo.Modb.TimeTravel` | `TimeTravel` | `ReadFiles` time-travel inspector + offline selective-undo preview and proposal accept/discard lifecycle. |
| `Arvo.Modb.Testing` | `Testing` | Zero-config `SecurityMatrix` & `Modb.Ledger` hash-chain/invariant auditor for MoDB apps. |

### MoBrowse Zero-Chromium E2E Package (`packages/arvo-mobrowse/`, requires sibling `mobrowse`)

| Module | Local Alias | Purpose |
| --- | --- | --- |
| `Arvo.Mobrowse.E2e` | `E2e` | Zero-Chromium E2E evidence (`e2e-report.json`), desktop/mobile PNG baseline diffing (`capture_page`), and SSR SEO `<head>` assertions (`inspect_seo_head`, `assert_seo_head`) over `Mobrowse.Arvo`. |

### `@arvo/react` Kit (`packages/arvo-react/`)

Turnkey React 19 + Inertia v2 + TypeScript UI kit exporting:
- Auth & security pages: `LoginPage`, `RegisterPage`, `VerifyEmailPage`, `ForgotPasswordPage`, `ResetPasswordPage`, `MfaChallengePage`, `SecuritySettingsPage`
- Real-time & upload hooks: `useArvoLive` (auto `router.reload({ only })` on SSE `inertia.reload`), `useArvoUpload` (multipart + 2-step S3 presigned uploads with XSRF and size/MIME checks)
- WebAuthn browser helpers (`prepareCreationOptions`, `prepareRequestOptions`, serialization)
- Operations UI: `<AuditTimeline />` (filterable audit/replay call log + selective-undo proposal cards)

---

## Install & Update

### Homebrew (macOS Apple Silicon & `x86_64` Linux)

```sh
brew install robertguss/tap/arvo
# Update later:
brew update && brew upgrade mo modb mobrowse arvo
```

### Linux / No-Homebrew Installer (`x86_64` Linux & Apple Silicon macOS)

Installs or upgrades `mo`, `modb`, `modb-mcp`, `mobrowse`, `mobrowse-viewer`, and `arvo` into `~/.local/bin` and `~/.local/share` with SHA-256 verification:

```sh
curl -fsSL https://raw.githubusercontent.com/robertguss/arvo/main/scripts/install.sh | sh
```

If you manage `mo` (and optionally `dana`) via `mise`:

```sh
mise use -g github:robertguss/mo@latest github:robertguss/dana@latest
curl -fsSL https://raw.githubusercontent.com/robertguss/arvo/main/scripts/install.sh | sh -s -- --skip-mo
```

---

## Quick Start

Requires [**Mo 0.4.1+**](https://github.com/robertguss/mo).

- SQLite starter: [`examples/arvo-starter`](examples/arvo-starter/README.md)
- MoDB starter: [`examples/arvo-modb-starter`](examples/arvo-modb-starter/README.md) (features `ReadFiles`-only `GET` routes, `Modb.Ledger`, `Arvo.Modb.Search`, `Arvo.Live` SSE on `303` redirects, `/mcp`, and `/__arvo`)

```bash
# Scaffold a new full-stack app (interactive or scripted via bin/arvo or cmd/arvo)
./bin/arvo new my-app --db modb --auth full --mobrowse
cd my-app && ../bin/arvo dev
```

---

## Arvo CLI (`cmd/arvo/main.mo` & `bin/arvo`)

Run pure-Mo commands directly via `mo run cmd/arvo/main.mo ...`, or invoke the host wrapper [`bin/arvo`](bin/arvo) (needed for `--emit-script` workflows that build frontends, vendor dependencies, SSH to `exe.dev` VMs, or run full project checks):

### App & `exe.dev` Deployment Commands
- `arvo new <app-name> [--db modb|sqlite] [--auth full|allowlist|none] [--orgs] [--mcp] [--mobrowse]` — scaffold a new Arvo + React app (with optional MoBrowse E2E + SEO suite `test-mobrowse-e2e.mo`)
- `arvo dev [--app DIR] [--port 8080] [--vite-port 5173] [--no-vite]` — run Vite HMR + `mo serve --watch`
- `arvo gen <resource|auth|page|job|mcp-tool> <Name> [fields...]` — generate explicit Mo handlers + React pages
- `arvo doctor [--app DIR] [--prod] [--json]` — audit `arvo.toml`, secrets, hardening, and `mo check`
- `arvo build [--app DIR] [--out DIR] [--skip-frontend] [--dry-run]` — build frontend assets and bundle a self-contained `.arvo/dist/` release vendoring transitive `mo.toml` path dependencies
- `arvo deploy init [--app DIR]` — generate hardened `systemd` unit + env template + `[deploy]` config for `exe.dev` VMs
- `arvo deploy <HOST> [--app DIR] [--bootstrap-env] [--rollback]` — atomic release upload over SSH with pre-deploy backup, `/healthz` + `/readyz` checks, and automatic rollback on failure
- `arvo backup <sync|restore|verify|local> [--app DIR] [flags]` — run MoDB integrity/audit checks (`packages/arvo-modb/cmd/backup/main.mo`), encrypted snapshots, and S3 delta sync

### Verification & Testing Commands
- `arvo contracts [--app DIR] [--check]` — generate/verify `frontend/src/arvo.gen.ts` from `Json.schema[T]()`
- `arvo verify [--app DIR] [--tier fast|feature|full] [--json] [--base REF]` — run verification ladder + tamper checks + `.arvo/dossier/verify.jsonl`
- `arvo feature [--app DIR] [--validate] [--manifest OUT] [DIR]` — validate `.feature.md` Executable Feature Maps and export `@browser` Playwright manifests
- `arvo sim [--app DIR] [--entry FILE] [--only NAME]` — run deterministic `Arvo.Testing.Sim` suites
- `arvo control <sha|launch|doctor|inspect|reset|drive|screenshot|record|cleanup>` — manage isolated runtime instances & browser captures
- `arvo statechart [check|render]` — explore/replay `Arvo.Sqlite.Jobs`, `Arvo.Sqlite.Sessions` / `Arvo.Session`, and `Auth` / `Totp` statecharts and verify sync commits
- `arvo replay <capture|gen>` — capture sanitized failure bundles and generate standalone regression tests
- `arvo bench --baseline-cmd A --candidate-cmd B` — alternating A/B benchmark runner
- `arvo dossier [--app DIR] [--open]` & `arvo log ...` — render static HTML Verification Dossier & `<150`-word PR summary

---

## Running the Test Suite

```bash
# Core + SQLite + Testing + CLI + examples/arvo-starter (auto-runs MoDB/MoBrowse suites if siblings exist)
./scripts/test.sh

# Explicitly select MoDB and/or MoBrowse checkouts
MODB_PATH=/path/to/modb MOBROWSE_PATH=/path/to/mobrowse ./scripts/test.sh

# React / TypeScript component & hook suite
npm --prefix packages/arvo-react run typecheck && npm --prefix packages/arvo-react test
```

`./scripts/test.sh` enforces zero `Sqlite`/`Modb`/`Mobrowse` leakage inside `lib/arvo/*.mo`, checks & tests all core/SQLite/testing/fixture/CLI/starter modules, validates `.feature.md` specs and `arvo contracts --check`, runs statechart sync & replay checks, passes all 14 `--strength` suites at `kill_rate == 1`, tests `packages/arvo-modb/` + `examples/arvo-modb-starter/main.mo`, and tests `packages/arvo-mobrowse/` + `arvo new --mobrowse` end-to-end apps.

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
