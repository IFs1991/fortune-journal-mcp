# v0.2.1 — Deploy-Ready hardening (2026-10-15)

## Fixed

- **DB (P0, migration 06)**: `fj_set_privacy` read `auth.users` as `service_role`, which real Supabase does not allow; every first analytics opt-in would have failed with 503. The plain-Postgres auth stub had masked it by granting a privilege Supabase lacks (stub corrected). The backend now passes the verified Auth user's `created_at`.
- **Dependencies (P0)**: next 15.5.19 → 15.5.27 (critical advisories); postcss 8.5.30 / sharp 0.35.5 overrides; real lockfile; `npm audit` clean.
- **MCP (P0)**: route did not compile against `@modelcontextprotocol/server` v2 / `mcp-handler` v2 (`securitySchemes` moved to tool `_meta`, two-argument `createMcpHandler`); `WWW-Authenticate` resource metadata pinned to `APP_ORIGIN`.
- **OAuth (P1)**: the consent page promised revocation but no UI existed — added Connected AI apps list + revoke route. Self-declared DCR client names are now flagged as unverified.
- **DB perf (P2, migration 07)**: covering indexes for three foreign keys flagged by `supabase db advisors`.
- **Scripts**: `test-db.sh` applies the CLI-generated migrations, pins the image digest, works under Git Bash; `check-pure-types` works on Windows; static check covers forward fixes; `db:check-prepared` rejects unregistered migrations.

## Added

- Output schemas for all 7 MCP tools; journal schema 1.2 (`target_period`, additive) and `writeRules` for the customer's Sheets connector.
- Structured cron outcome logs (`FJ_MAINTENANCE_*`).
- `scripts/e2e-local.mjs` (loopback-only E2E against the local Supabase stack), `scripts/test-supabase-local.sh`, `v02_negative_edge.sql`, `v02_forward_fix_06.sql`, OAuth claim and journal unit tests.
- CI: build/typecheck/audit, disposable Postgres, and a real Supabase CLI job running SQL suites + E2E.
- Staging runbook, env matrix and approval points in `docs/DEPLOYMENT_AND_TESTS.md`.

# v0.2 — Growth, privacy and reliability

## Added

4 marketing/operations tables and 3 product telemetry tables; five ordered SQL migration stages and official CLI materializer; signed owner command API; fixed-topic public drafts with exact-hash approval; conservative Threads publishing and insight collection; account stock/flow separation; signed-link/explicit-source attribution; optional customer feedback and journal-action reports; consent withdrawal and paged service-data export; matured cohort/MRR/cash/follower/automation reporting; retention; disposable fresh/upgrade DB tests; expanded agent instructions and DoD.

## Corrected

- A retry no longer needs to spend another quota unit when the same user/request/input is reused inside the retention window.
- Consent setup no longer starts the 14-day trial; first calculation does.
- Billing verification is explicit, not automatically inferred for inherited subscription rows.
- Existing billing_events is extended rather than replaced or duplicated.
- Missing insight values are NULL, not zero; present-day backfill is not labeled historical 24h performance.
- The client used is not treated as discovery channel.
- Snapshot capture identity remains stable after old automation runs are removed.
- Posting uncertainty is retained as unknown; retrying with a new command ID cannot automatically publish the same approved post twice.
- Tarot key changes affect the request fingerprint; accidental key rotation is not silently treated as the same prior result.

## Deliberately not included

Customer journal text, birth profile storage, Google Drive token custody, free-text customer feedback, anonymous cross-site tracking, default real payments, host-generated LLM cost guesses, analytics admin dashboard, native LLM calls, indefinite workers, automatic public posting without owner approval.

## Release status (v0.2.0)

Superseded by v0.2.1 above. See verification/RESULTS.md for what has actually been executed.
