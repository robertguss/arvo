# Paycheck bills and optimistic concurrency

Signed-in household members view due paycheck bills, create new bills with field validation, and mark a bill in flight with optimistic version checking.

## Sub-features

- `bill-create`: validates name, category, and positive amount before persisting and logging an audit event.
- `bill-pay-happy`: marks a due bill `in_flight` and increments its version alongside an audit record.
- `bill-pay-conflict`: rejects a stale concurrent `expected_version` update with `409 Conflict`.

## How to get to it (user POV)

- Sign in at `/login`, open `/` (`Home`), and submit the `Add Bill` form or click `Mark paid` beside a due bill.

## Scenarios

```gherkin
Feature: Paycheck bills and optimistic concurrency
  Background:
    Given seed profile "baseline"
    And signed in as "ada@household.local"

  @smoke @browser @mobile @aria @screenshot @db-check
  Scenario: Member creates a new bill and sees updated total due
    When I visit "/"
    Then the Inertia component is "Home"
    And the bill "Electric & Gas <Utility>" shows status "due"
    When I submit new bill name "Fiber Internet" category "utilities" amount_cents "7500"
    Then the response redirects to "/"
    When I follow the redirect
    Then the flash notice is "Bill added"
    And the bill "Fiber Internet" shows status "due"
    And total due cents is 22000
    And audit trail contains action "bill.create" by "ada@household.local" for "bills"

  @smoke @browser @db-check
  Scenario: Member marks a due bill in flight and stale version conflicts with 409
    When actor "ada" marks bill 1 in flight with expected version 1
    Then the response status is 200
    And the bill "Electric & Gas <Utility>" shows status "in_flight"
    When actor "grace" marks bill 1 in flight with expected version 1
    Then the response status is 409
    And audit trail contains action "bill.mark_in_flight" by "ada@household.local" for "bills"

  @smoke
  Scenario: Blank bill name and zero amount flash validation errors across redirect
    When I submit new bill name "" category "bad_cat" amount_cents "0"
    Then the response redirects to "/"
    When I follow the redirect
    Then validation error for "name" contains "blank"
    And validation error for "amount_cents" contains "greater than 0"
```

## Gotchas

- Concurrent partners must see `409 Conflict` when paying with a stale `expected_version` rather than silently overwriting the bill.
- Bill names contain `<` and `&` to verify XSS attribute escaping across initial HTML loads.
