---
name: arvo-correct
description: Systemic engineering correction workflow whenever an agent or commit repeats a class of mistakes. Enforces fixes at the highest automation level and verifies the new check catches the past mistake.
---

# Systemic Mistake Prevention (`arvo-correct`)

Activate whenever an AI agent or contributor repeats a mistake class (e.g., hand-typed JS props drifting from Mo, missing CSRF/auth checks, broken ARIA labels, stale statechart models, or weak tests that pass with buggy logic).

## Escalation Hierarchy (Fix at Highest Possible Level)

Apply the strongest structural enforcer that makes the mistake impossible:

1. **Architecture:** Centralize the invariant (e.g., `Arvo.Inertia` HTML-escaped serialization, `Auth.require_csrf`, `Arvo.Migrations` SHA-256 checksums) so handlers cannot bypass it accidentally.
2. **Types & Compile-Time Contracts:** Encode valid states and wire shapes in Mo types and export them via `Json.schema[T]()` + `arvo contracts --check` into `frontend/src/arvo.gen.ts`.
3. **Lint / Static & Automated Gates:** Enforce zero-config rules via `arvo feature --validate`, `Arvo.SecurityMatrix`, query budgets, `@axe-core/playwright`, or Web-Semantic Mutant probes in `cmd/arvo/semantic-mutants.mo`.
4. **Tests & Wrong-Version `--strength` Suites:** Add deterministic real-DB tests and concrete wrong-version files under `strength/<module>/` + executable `examples` / `promise` blocks checked by `mo test --strength` and `mo test --mutants`.
5. **Docs & Skills (Last Resort Only):** Document edge cases in `.feature.md` `## Gotchas` and `.arvo/skills/` only after stronger automated checks are in place.

## Proof Requirement & Rule -> Enforcer Table

- **Prove every new check can fail:** Reproduce the real historical mistake in a scratch copy or wrong-version `.mo` file under `strength/` and verify the new check catches it before landing.
- Record the systemic fix in `.arvo/dossier/decisions.tsv` via `arvo log` and maintain a concise Rule -> Enforcer mapping in repo instructions:

| Rule | Automated Enforcer |
| --- | --- |
| Typed Mo -> TS Inertia props & page existence | `arvo contracts --check` |
| Auth, CSRF, XSS, `PRAGMA foreign_keys`, query budget | `Arvo.SecurityMatrix.run_full` + `semantic_mutants` |
| Core invariant `examples` & `promise` strength | `mo test --jobs 4 --strength` (`strength/`) + `--mutants` |
| UI ARIA roles, axe a11y, zero console/5xx, visual diff | Playwright via `arvo control` + `vitest` + `stryker` |
| Model-to-code fidelity on Jobs & Session | `arvo statechart check` |
