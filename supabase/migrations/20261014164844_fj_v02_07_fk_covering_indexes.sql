-- Additive performance fix found by `supabase db advisors` (unindexed_foreign_keys) on the local stack.
-- The daily purge deletes old automation_runs and user_readings; without these indexes every deleted parent row
-- makes PostgreSQL scan the child table to apply ON DELETE SET NULL / CASCADE.
-- Plain CREATE INDEX (inside the migration transaction) is fine for a new/small Staging database; for a large
-- populated database, review lock time first or build CONCURRENTLY outside a transaction as a separate step.
BEGIN;
CREATE INDEX account_snapshots_run ON public.account_metric_snapshots(run_id) WHERE run_id IS NOT NULL;
CREATE INDEX automation_runs_post ON public.automation_runs(post_id) WHERE post_id IS NOT NULL;
CREATE INDEX funnel_events_reading ON public.funnel_events(user_id, reading_id) WHERE reading_id IS NOT NULL;
COMMIT;
