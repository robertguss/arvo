# MoDB Bills, Full-Text Search, Real-Time Live Reload, MCP Actions, and Dev Inspector

Signed-in household members manage paycheck bills backed by MoDB Ledger hash-chained audit logs, search bills via BM25+ full-text search, receive real-time SSE invalidation frames on mutations, execute typed `Arvo.Action` workflows over HTTP or MCP, and inspect MoDB internals at `/__arvo` only when `ARVO_DEV=1`.

## Sub-features

- `bill-fts-search`: indexes bills transactionally inside `Modb.Ledger` and queries via `ReadFiles`-only `Arvo.Modb.Search`.
- `live-invalidation`: streams `/live` SSE events and triggers partial Inertia reloads on bill changes.
- `unified-mcp-action`: exposes `bills.pay` and `bills.search` through both HTTP endpoints and CSRF-protected `POST /mcp`.
- `dev-dashboard`: fails closed with `404` unless `ARVO_DEV=1`, exposing MoDB buckets, audit log, jobs, and Dev Mailbox.

## How to get to it (user POV)

- Sign in at `/login`, inspect or search bills on `/`, call `/bills/search?q=...` or `POST /mcp`, and open `/__arvo` in local development.

## Scenarios

```gherkin
Feature: Flagship MoDB Starter
  Background:
    Given signed in as "ada@household.local"

  @smoke @db-check
  Scenario: Member searches indexed bills and triggers real-time invalidation via MCP
    When I visit "/bills/search?q=Electric"
    Then the response status is 200
    When I call MCP tool "bills.pay" for bill 1
    Then the response emits an "inertia.reload" SSE event
    And opening "/__arvo" without ARVO_DEV returns 404
```

## Gotchas

- `Modb.Fts` indexing runs inside the existing `Modb.Ledger` transaction so every bill write shares a single tamper-evident audit commit.
- `/__arvo` and `/__arvo/mailbox` strictly return `404` unless `ARVO_DEV=1`.
