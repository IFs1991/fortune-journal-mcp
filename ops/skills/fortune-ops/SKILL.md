---
name: fortune-ops
description: Private owner-only operation of Fortune Journal marketing, snapshots and cohort reports through the signed operations CLI. Never distribute with the customer plugin.
---

Read AGENTS.md and docs/OPERATIONS.md §7 first. This skill is for a reviewed owner execution environment, not an ordinary customer conversation.

Use `node --env-file=<env file outside the repo> --experimental-strip-types scripts/ops.mjs <command.json>` (commands and their validation: src/ops/commands.ts). The CLI signs using environment secrets; never print those secrets, a signed authorization header, or a customer record.

Default action is read-only report. Preserve denominators, mature cohorts, NULLs, unknown attribution and currencies. Do not call customer host inference cost zero. Use only public owner content for drafts. Never infer a user's interests or fill missing historical metrics.

Write commands require an explicit owner scope. A draft does not authorize approval; approval does not authorize arbitrary later body edits. RequestId and postId remain stable for retries. Use exact bodySha256 from the draft response. Public publish stays disabled until owner permits the actual post/account/window.

Publish outcomes: `success` (live, recorded), `failed` (the error happened before the publish call, nothing is live; the post is back to approved and the owner may ask for one more `publish_post`), `unknown` (sent but unconfirmed). Unknown publish: stop. Never publish it again and never use a new key. Open the Threads profile (read permission) and look for the exact approved body; then send `resolve_publish` with `outcome: "published"` and the live `externalPostId`, or `outcome: "not_published"` only after confirming it is absent. Only after `not_published` may `publish_post` run again, with owner scope. Outstanding unknown posts are listed in the report (`operations.publishUnknown`). A response with `recorded: false` means the database did not take the outcome: report it to the owner before anything else.

Maintenance cron: HTTP 500 / `FJ_MAINTENANCE_PARTIAL_FAILURE` means at least one step failed; `retryable: false` (for example `PURGE_RETRIES_EXHAUSTED`, `THREADS_PERMISSION_DENIED`) needs a person, `retryable: true` is retried by the next hourly run.

No arbitrary SQL, premium grants, changed privacy flags or production schema changes through this interface.

Analysis outputs belong in ops/experiments: measured evidence vs hypothesis vs next test separately. A weekly analysis made outside this application is not automatically observed. Use record_external_run with the actual start/end, model and known usage from the authorized execution environment; do not manufacture missing costs or claim provider verification. Analysis content stays in the experiment artifact.
