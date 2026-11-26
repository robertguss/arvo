---
name: arvo-bug-repro
description: Root-cause bug reproduction and fix workflow using arvo control, Arvo.Replay failure bundles, regression tests, and blast-radius proof before fixing.
---

# Reproducible Bug Fix Protocol

Activate before fixing any reported user bug, CI regression, or production failure. Prove the failure twice before editing product code, and prove the fix twice afterward.

## Protocol

1. **Capture & Reproduce Twice:**
   - If reproducing from a failing run or production incident, capture a sanitized `Arvo.Replay` bundle (`Cookie`, `Authorization`, `X-XSRF-TOKEN`, `Set-Cookie`, and secret env vars redacted automatically):
     ```bash
     arvo replay capture --app examples/arvo-starter --id repro-1 --method POST --path /bills/1/pay --out .arvo/replays/bug.json
     arvo replay gen --app examples/arvo-starter .arvo/replays/bug.json --out .arvo/replays/replay-regression.mo
     ```
   - Otherwise launch an isolated runtime via `arvo control`, drive/trigger the failing step, inspect SQLite & audit logs read-only (`arvo control inspect --sql ...` / `--audit`), then run `arvo control reset --run-id repro-1 --seed baseline` and confirm the bug reproduces identically a second time.

2. **Write the Failing Regression Test First:**
   - Port the generated `ReplayRegression` snippet or `WebTest` / Playwright assertion into the module's test suite (`examples/arvo-starter/main.mo` or `lib/arvo/*.mo`) and observe it FAIL against unpatched code.

3. **Fix Root Cause with Minimum Diff:**
   - Make the smallest clean fix addressing the underlying invariant rather than patching symptoms.

4. **Prove Fixed Twice + Blast-Radius Safety Fact:**
   - Run the new regression test and re-drive the exact `arvo control` repro scenario twice after `arvo control reset`.
   - Identify the single core safety fact protecting adjacent routes/state (e.g., optimistic concurrency `AND version = ?`, CSRF enforcement, or tenant scoping) and prove it across all callers by running:
     ```bash
     arvo verify --app examples/arvo-starter --tier full
     arvo control cleanup --app examples/arvo-starter --run-id repro-1
     ```
   - Confirm evidence artifacts in `.arvo/evidence/repro-1/` survived cleanup and log the verification outcome via `arvo log`.
