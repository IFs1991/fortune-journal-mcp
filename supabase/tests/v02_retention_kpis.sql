-- Disposable database fixtures only. Each file rolls back its own writes.
BEGIN;
SET LOCAL ROLE service_role;
DO $$ DECLARE pid uuid:=gen_random_uuid();rid uuid:=gen_random_uuid();r2 uuid:=gen_random_uuid();result jsonb;rate numeric;BEGIN
 INSERT INTO public.fortune_posts(id,account_key,external_post_id,body,body_sha256,status,published_at)
 VALUES(pid,'retentiontest','777','public test only',repeat('a',64),'published',now()-interval '101 days');
 INSERT INTO public.automation_runs(id,task,idempotency_key,status,actor_kind,started_at,finished_at)
 VALUES(rid,'collect_account_metrics','retention-a','succeeded','operator',now()-interval '100 days',now()-interval '100 days'),
 (r2,'collect_account_metrics','retention-b','succeeded','operator',now()-interval '99 days',now()-interval '99 days');
 INSERT INTO public.account_metric_snapshots(account_key,run_id,capture_key,collected_at,metric_name,metric_value,period_kind,api_version)
 VALUES('retentiontest',rid,rid,now()-interval '100 days','followers_count',100,'point_in_time','v1.0'),
 ('retentiontest',r2,r2,now()-interval '99 days','followers_count',105,'point_in_time','v1.0');
 -- Should not collide when both FK run_ids become NULL after retention.
 PERFORM public.fj_purge_expired();
 IF (SELECT count(*) FROM public.account_metric_snapshots WHERE account_key='retentiontest' AND run_id IS NULL)<>2 THEN RAISE EXCEPTION 'capture identity lost';END IF;
 INSERT INTO public.account_metric_snapshots(account_key,capture_key,collected_at,metric_name,metric_value,period_kind,api_version)
 VALUES('growthtest',gen_random_uuid(),now()-interval '7 days 1 hour','followers_count',20,'point_in_time','v1.0'),
 ('growthtest',gen_random_uuid(),now()-interval '1 hour','followers_count',17,'point_in_time','v1.0');
 result:=public.fj_follower_growth('growthtest');
 IF (result->>'netGrowth')::integer<>-3 THEN RAISE EXCEPTION 'followers summed or decline hidden';END IF;
 result:=public.fj_follower_growth('missing');
 IF result->>'netGrowth' IS NOT NULL OR (result->>'complete')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'missing baseline became zero';END IF;
 INSERT INTO public.post_metric_snapshots(post_id,collected_at,target_age_hours,snapshot_kind,api_version,views,likes,replies,reposts,quotes)
 VALUES(pid,now()-interval '100 days',24,'scheduled','v1.0',100,2,1,1,1),
 (pid,now()-interval '99 days 23 hours',24,'scheduled','v1.0',100,90,1,1,1);
 SELECT engagement_pct INTO rate FROM public.fj_post_24h WHERE post_id=pid;
 IF rate<>5 THEN RAISE EXCEPTION '24h snapshot selection wrong';END IF;
END; $$;
RESET ROLE;
-- A real client connection must NOT be labeled as discovery via that client.
INSERT INTO auth.users(id) VALUES('55555555-5555-4555-8555-555555555555');
SET LOCAL ROLE service_role;
SELECT public.fj_set_privacy('55555555-5555-4555-8555-555555555555',true,false,'2026-10-v2');
SELECT public.fj_record_funnel('55555555-5555-4555-8555-555555555555','mcp_connected','first-client','chatgpt','registered_client');
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.funnel_events WHERE user_id='55555555-5555-4555-8555-555555555555' AND event_name='registration' AND source_channel<>'unknown') THEN RAISE EXCEPTION 'client confused with acquisition';END IF;
END; $$;
RESET ROLE;
ROLLBACK;
