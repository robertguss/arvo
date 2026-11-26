# Arvo + MoDB + Inertia v2 Starter

Full-stack reference application combining Mo's declarative `api` server, pure-Mo `Arvo.*` web modules, and [**MoDB**](https://github.com/robertguss/modb) (`Arvo.Modb.Sessions`, `Arvo.Modb.Jobs`, `Modb.Table`, and `Modb.Ledger`) with the same Inertia v2 + React 19 + TypeScript + Vite frontend as [`examples/arvo-starter`](../arvo-starter/README.md)—with **zero `Sqlite` capability**.

## Differences vs. the SQLite Starter

- **Host-enforced read-only `GET` routes:** `Routes.authenticate` and `GET /` (`Routes.home`) receive only `ReadFiles` (never `Files`), reading `sessions.modb` via `Arvo.Modb.Sessions.load_read_only` (lock-free optimistic CoW reads with zero `last_seen_at` writes on `GET`) and `starter.modb` via `Modb.Ledger.read_locked`.
- **Tamper-evident hash-chained audit & invariants:** Domain writes use `Modb.Ledger.transact` / `transact_locked`, committing a SHA-256 hash-chained `AuditEntry` alongside domain rows while checking `Ledger.row_invariant("bill_amount_positive", ...)`. Session and queue maintenance use Layer 2 transactions.
- **Transactional MoDB background jobs:** `POST /imports/csv` prepares an `"import.notify"` job and persists it via `Arvo.Modb.Jobs.tx_put` in the same `Modb.Ledger` transaction as the inserted bills. The scheduled `arvo.jobs.drain` worker recovers claims left running for five minutes before draining pending jobs.

## Running Tests

Requires a sibling `modb` checkout at `../../../modb` relative to this directory (matching `mo.toml`):

```sh
mo check examples/arvo-modb-starter/main.mo
mo test examples/arvo-modb-starter/main.mo
```

## Running Locally (Reusing `examples/arvo-starter/frontend`)

From the Arvo repository root, build and copy the frontend assets, set a 32-byte hex session key, and choose the initial password for `ada@household.local`. Keep the same key across restarts; the seed password is only required to initialize a new database.

```sh
(cd examples/arvo-starter/frontend && npm ci && npm run build)
mkdir -p /tmp/arvo-modb-data/public
cp -R examples/arvo-starter/public/. /tmp/arvo-modb-data/public/

export ARVO_SECRET_KEY="$(openssl rand -hex 32)"
read -r -s -p "Initial password for ada@household.local: " ARVO_SEED_PASSWORD
printf '\n'
ARVO_SEED_PASSWORD="$ARVO_SEED_PASSWORD" \
ARVO_INSECURE_COOKIES=1 \
  mo serve examples/arvo-modb-starter/main.mo --bind 127.0.0.1 --port 8080 --data /tmp/arvo-modb-data
```
