# CSV statement import

Signed-in members upload a bank or utility CSV statement (`name,category,amount_cents`) via multipart form data to bulk-create due bills with a single audit event.

## Sub-features

- `csv-import-happy`: parses CSV rows, applies `default_category` when category is blank, inserts bills, and logs `bills.csv_import`.
- `csv-import-reject`: rejects malformed rows with `422` without partial failure of validation guards.

## How to get to it (user POV)

- Send `POST /imports/csv` with multipart field `statement` and active session + CSRF header.

## Scenarios

```gherkin
Feature: CSV statement import
  Background:
    Given seed profile "baseline"
    And signed in as "ada@household.local"

  @smoke @db-check
  Scenario: Valid CSV upload creates multiple bills and writes audit entry
    When I upload CSV bills with default category "utilities":
      | name | category | amount_cents |
      | City Water | utilities | 3800 |
      | Rent | housing | 185000 |
    Then the response status is 200
    And the bill "City Water" shows status "due"
    And the bill "Rent" shows status "due"
    And audit trail contains action "bills.csv_import" by "ada@household.local" for "bills"

  @smoke
  Scenario: Malformed CSV row returns 422
    When I upload raw CSV "BrokenRowOnlyOneColumn\n"
    Then the response status is 422
```

## Gotchas

- CSV uploads require valid `X-XSRF-TOKEN` and UTF-8 bytes; missing columns or non-positive amounts must return `422`.
