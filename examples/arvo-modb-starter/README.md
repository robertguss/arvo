# Arvo + MoDB + Inertia v2 Starter

Full-stack reference application combining Mo's declarative `api` server, pure-Mo `Arvo.*` web modules, and [**MoDB**](https://github.com/robertguss/modb) (`Arvo.Modb.Sessions`, `Arvo.Modb.Jobs`, `Modb.Table`, and `Modb.Ledger`) with the same Inertia v2 + React 19 + TypeScript + Vite frontend as [`examples/arvo-starter`](../arvo-starter/README.md)—with **zero `Sqlite` capability**.

## Differences vs. the SQLite Starter

- **Host-enforced read-only `GET` routes:** `Routes.authenticate` and `GET /` (`Routes.home`) receive only `ReadFiles` (never `Files`), reading `sessions.modb` via `Arvo.Modb.Sessions.load_read_only` (lock-free optimistic CoW reads with zero `last_seen_at` writes on `GET`) and `starter.modb` via `Modb.Ledger.read_locked`.
- **Tamper-evident hash-chained audit & invariants:** Every write executes via `Modb.Ledger.transact` / `transact_locked`, committing a SHA-256 hash-chained `AuditEntry` alongside domain rows while checking `Ledger.row_invariant("bill_amount_positive", ...)`.
- **Transactional MoDB background jobs:** `POST /imports/csv` enqueues an `"import.notify"` job via `Arvo.Modb.Jobs.tx_enqueue` inside the same `Modb.Ledger` transaction as the inserted bills, and `Main` declares `job "arvo.jobs.drain" Routes.drain_jobs every 10.seconds` for `mo serve` and `ApiTest.run_job`.

## Running Tests

Requires a sibling `modb` checkout at `../../../modb` relative to this directory (matching `mo.toml`):

```sh
mo check examples/arvo-modb-starter/main.mo
mo test examples/arvo-modb-starter/main.mo
```

## Running Locally (Reusing `examples/arvo-starter/frontend`)

Build the frontend assets once from `examples/arvo-starter/frontend` and copy `examples/arvo-starter/public` into your `--data` directory (or run Vite HMR in dev):

```sh
cd examples/arvo-starter/frontend && npm ci && npm run build
mkdir -p /tmp/arvo-modb-data
cp -R ../public /tmp/arvo-modb-data/public

ARVO_SECRET_KEY="$(openssl rand -hex 32)" \
ARVO_INSECURE_COOKIES=1 \
  mo serve examples/arvo-modb-starter/main.mo --port 8080 --data /tmp/arvo-modb-data
```
