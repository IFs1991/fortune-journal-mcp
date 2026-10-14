BEGIN;
CREATE FUNCTION public.fj_purge_expired() RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE readings bigint; events bigint; counters bigint; runs bigint;
BEGIN
 -- Operational retention proposal, NOT a statutory retention period.
 DELETE FROM public.funnel_events WHERE occurred_at<now()-interval '90 days'; GET DIAGNOSTICS events=ROW_COUNT;
 DELETE FROM public.user_readings WHERE calculated_at<now()-interval '90 days'; GET DIAGNOSTICS readings=ROW_COUNT;
 -- reading_feedback and reading-linked funnel events cascade from the operational ledger.
 DELETE FROM public.usage_counters WHERE period_start<(now() AT TIME ZONE 'UTC')::date-90; GET DIAGNOSTICS counters=ROW_COUNT;
 -- Orphaned in-flight publishing is unknown, never queued for an automatic repost.
 UPDATE public.fortune_posts p SET status='publish_unknown' WHERE p.status='publishing' AND EXISTS
  (SELECT 1 FROM public.automation_runs r WHERE r.post_id=p.id AND r.task='publish_post' AND r.status='running' AND r.lease_expires_at<now());
 UPDATE public.automation_runs SET status='unknown',finished_at=now(),error_code='LEASE_EXPIRED'
 WHERE task='publish_post' AND status='running' AND lease_expires_at<now();
 DELETE FROM public.automation_runs WHERE status IN ('succeeded','failed') AND finished_at<now()-interval '90 days'; GET DIAGNOSTICS runs=ROW_COUNT;
 DELETE FROM public.post_metric_snapshots WHERE collected_at<now()-interval '400 days';
 DELETE FROM public.account_metric_snapshots WHERE collected_at<now()-interval '400 days';
 -- Billing records are deliberately excluded: choose provider/jurisdiction-specific retention before live payments.
 RETURN jsonb_build_object('readingsDeleted',readings,'eventsDeleted',events,'countersDeleted',counters,'runsDeleted',runs);
END; $$;
REVOKE ALL ON FUNCTION public.fj_purge_expired() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.fj_purge_expired() TO service_role;
-- The old low-level quota incrementer is no longer an application entrypoint.
REVOKE ALL ON FUNCTION public.consume_usage(uuid,text,text,date,integer) FROM PUBLIC,anon,authenticated,service_role;
COMMIT;
