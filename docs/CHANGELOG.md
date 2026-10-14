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

## Release status

Implementation source, not production-verified. Five SQL templates must be generated through the real Supabase CLI; actual DB and OAuth/provider integration still need execution. Full dependency install/build has not completed in this network-isolated environment. See verification/RESULTS.md.
