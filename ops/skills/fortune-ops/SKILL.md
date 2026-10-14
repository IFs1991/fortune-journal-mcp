---
name: fortune-ops
description: Private owner-only operation of Fortune Journal marketing, snapshots and cohort reports through the signed operations CLI. Never distribute with the customer plugin.
---

Read AGENTS.md and docs/BUILD_STATUS.md first. This skill is for a reviewed owner execution environment, not an ordinary customer conversation.

Use `node --env-file=.env.local --experimental-strip-types scripts/ops.mjs <command.json>`. The CLI signs using environment secrets; never print those secrets, a signed authorization header, or a customer record.

Default action is read-only report. Preserve denominators, mature cohorts, NULLs, unknown attribution and currencies. Do not call customer host inference cost zero. Use only public owner content for drafts. Never infer a user's interests or fill missing historical metrics.

Write commands require an explicit owner scope. A draft does not authorize approval; approval does not authorize arbitrary later body edits. RequestId and postId remain stable for retries. Use exact bodySha256 from the draft response. Public publish stays disabled until owner permits the actual post/account/window.

Unknown publish: stop. Inspect official records with read permissions; do not issue another publish with a new key. No arbitrary SQL, premium grants, changed privacy flags or production schema changes through this interface.

Analysis outputs belong in ops/experiments: measured evidence vs hypothesis vs next test separately. A weekly analysis made outside this application is not automatically observed. Use record_external_run with the actual start/end, model and known usage from the authorized execution environment; do not manufacture missing costs or claim provider verification. Analysis content stays in the experiment artifact.
