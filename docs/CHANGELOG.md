# Unreleased — MCP communication optimization

Details, auth decision and measurements: [PERFORMANCE.md](PERFORMANCE.md).

## Changed

- **DB (migration 08)**: `draw_tarot` and `get_access_status` need one PostgREST call instead of two. `fj_record_calculation` looks up an existing draw itself (cross-day tarot retries replay without the app-side lookup); identical retries are checked before the tier gate, so a retry after the trial ended replays the delivered draw without usage. New read-only `fj_access_snapshot` (service_role only); tier policy stays in `resolveEntitlement`. **Apply 08 before deploying the app.**
- **Auth**: expired / foreign-issuer / non-OAuth bearer tokens are rejected before calling Supabase Auth. Accepted tokens are still verified with `auth.getUser()` on every request (immediate revocation kept; `getClaims()`-only verification was measured and rejected).
- **Telemetry**: `get_account_profile` records the optional `mcp_connected` event after the response (`next/server` `after()`); consent and dedupe unchanged.
- **MCP descriptions / customer skill**: call `calculate_numerology` / `draw_tarot` directly; `get_access_status` / `get_account_profile` only when the user asks. Inputs/outputs unchanged.

## Added

- Optional per-call timing log (`MCP_TIMING_LOG=true` → `FJ_MCP_TIMING`, no inputs/IDs/tokens, no DB writes); `scripts/bench-mcp-local.mjs`, `scripts/probe-auth-verification.mjs`; SQL suite `v02_forward_fix_08.sql`; 10-parallel cross-date tarot retries in the PG suite; E2E for tampered tokens, post-trial replay, suspension, 10 parallel identical MCP draws, deferred telemetry with/without consent.

## Fixed

- **CI**: `supabase-local` E2E failed with `ERR_UNKNOWN_FILE_EXTENSION: .ts` on Node 22.16 — run `e2e-local.mjs` with `--experimental-strip-types`.

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
