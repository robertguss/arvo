---
name: arvo-maintain-specs
description: Spec maintenance workflow for auditing Executable Feature Maps (specs/features/*.feature.md) against live app behavior and source code without modifying application code.
---

# Maintain Executable Feature Maps

Run this workflow daily, on schedule, or after major route/UI churn to keep `specs/features/*.feature.md` accurate and free of drift.

## Protocol

1. **Read-Only Feature Audit (Parallel Per Feature File):**
   - Inspect every file under `specs/features/*.feature.md` alongside its corresponding routes, handlers, and frontend TSX pages (using read-only inspection only).
   - Validate structural conformance (`Summary`, `Sub-features`, `How to get to it (user POV)`, `Scenarios` with valid Gherkin, `Gotchas`):
     ```bash
     arvo feature --app examples/arvo-starter --validate
     ```

2. **Live Exploratory Walkthrough via `arvo control`:**
   - Boot a disposable instance and verify server health:
     ```bash
     arvo control launch --app examples/arvo-starter --seed baseline --run-id spec-audit &
     arvo control doctor --app examples/arvo-starter --run-id spec-audit
     ```
   - Exercise every documented `@browser` scenario with Playwright, inspect ARIA trees and DB/audit rows via read-only `arvo control inspect`, and verify screenshots/traces survive cleanup:
     ```bash
     URL=$(jq -r '.url' examples/arvo-starter/.arvo/runs/spec-audit/run.json)
     SHA=$(jq -r '.build_sha' examples/arvo-starter/.arvo/runs/spec-audit/run.json)
     (cd examples/arvo-starter/frontend && node ./scripts/arvo-playwright.mjs --mode drive --base-url "$URL" --run-id spec-audit --app-dir .. --evidence-dir .arvo/evidence/spec-audit --build-sha "$SHA" --viewport all)
     arvo control inspect --app examples/arvo-starter --run-id spec-audit --audit
     arvo control cleanup --app examples/arvo-starter --run-id spec-audit
     ```

3. **Classify Every Discrepancy Strictly:**
   - **doc drift:** Product behavior is intended and tested, while `.feature.md` copy, role label, or scenario text is outdated -> update ONLY the `.feature.md` file.
   - **harness gap:** Playwright / `WebTest` harness locator or seed fixture lacks coverage -> record gap in report or `arvo log`.
   - **product regression:** App behavior violates its spec -> DO NOT rewrite `.feature.md` to hide the bug! Report status as `blocked` and escalate for an application bug fix.

## Strict Scope & Terminal States

- **Confined Edit Scope:** Edit ONLY `specs/features/*.feature.md`. Never edit product `.mo`, `.ts`, or `.tsx` code during a spec-maintenance pass (`tamper_check` will highlight all spec edits cleanly for human review).
- End every run explicitly with one outcome: `clean`, `changed`, or `blocked`, and append a checkpoint row via `arvo log`.
