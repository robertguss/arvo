---
name: arvo-verify
description: End-to-end verification protocol for completing features, refactors, or PRs in Arvo apps. Runs Tier 0 -> Tier 1 -> Tier 2 checks, logs decisions to decisions.tsv, emits the HTML + PR Markdown Verification Dossier, and requires an independent verifier sign-off.
---

# Arvo Verification Protocol

Follow this ladder whenever completing a feature, refactor, or PR. Match proof rigor to every touched surface, fail closed on skipped gates, and never fabricate passes.

## Tiered Ladder (`--app DIR`)

1. **Tier 0 (`fast`) — Contracts, Feature Validation & Mo Tests:**
   - Regenerate/check TypeScript contracts if backend props or routes changed:
     ```bash
     arvo contracts --app examples/arvo-starter
     arvo contracts --app examples/arvo-starter --check
     ```
   - Export real Mo Inertia fixtures whenever response payloads change, then run Vitest + RTL:
     ```bash
     (cd examples/arvo-starter && mo run main.mo --arvo-export-fixtures)
     (cd examples/arvo-starter/frontend && npm run test:ci)
     ```
   - Run Tier 0 gate:
     ```bash
     arvo verify --app examples/arvo-starter --tier fast
     ```

2. **Tier 1 (`feature`) — Mo Mutants, Live Browser E2E, Axe & Visual Parity:**
   - Rebuild production frontend assets if UI files changed: `(cd examples/arvo-starter/frontend && npm run build)`
   - Launch an isolated runtime via `arvo control`, drive Playwright across `mobile` (`390x844`) and `desktop` (`1280x800`), inspect DB/audit cross-checks, and clean up without losing evidence:
     ```bash
     arvo control launch --app examples/arvo-starter --seed baseline --run-id verify-ui &
     arvo control doctor --app examples/arvo-starter --run-id verify-ui
     URL=$(jq -r '.url' examples/arvo-starter/.arvo/runs/verify-ui/run.json)
     SHA=$(jq -r '.build_sha' examples/arvo-starter/.arvo/runs/verify-ui/run.json)
     (cd examples/arvo-starter/frontend && node ./scripts/arvo-playwright.mjs --mode drive --base-url "$URL" --run-id verify-ui --app-dir .. --evidence-dir .arvo/evidence/verify-ui --build-sha "$SHA" --viewport all)
     arvo control cleanup --app examples/arvo-starter --run-id verify-ui
     ```
   - Run Tier 1 gate:
     ```bash
     arvo verify --app examples/arvo-starter --tier feature
     ```

3. **Tier 2 (`full`) — `--strength`, Web-Semantic Mutants, Stryker & Formal Statecharts:**
   - Refresh Stryker mutation score (`>= 85%`): `(cd examples/arvo-starter/frontend && npm run stryker)`
   - Run full gate (automatically writes `.arvo/dossier/verify.jsonl`, `.arvo/dossier/index.html`, and `.arvo/dossier/pr-summary.md`):
     ```bash
     arvo verify --app examples/arvo-starter --tier full
     ```

## Non-Negotiables

- **Log decision checkpoints** cleanly with `arvo log`:
  ```bash
  arvo log --app examples/arvo-starter --phase verify --decision "<what>" --why "<reason>" --evidence ".arvo/dossier/verify.jsonl" --result "pass"
  ```
- **Independent Verifier Sign-Off:** Before final merge/handoff, have an independent reviewer agent (never the author turn) inspect `.arvo/dossier/index.html` and `.arvo/dossier/pr-summary.md`, review any flagged `tamper_check` diffs or risks, and record its `Attention` findings.
- **Report `INCONCLUSIVE`** if any required verification surface could not execute (missing evidence, stale `build_sha`, or skipped phase). Never claim `PASS` on partial coverage.
