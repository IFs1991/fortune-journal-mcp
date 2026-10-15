-- Migration 08: draw_tarot needs one RPC (prior-draw lookup moved into fj_record_calculation) and
-- get_access_status reads one snapshot RPC. Quota, idempotency, suspension and tier rules are unchanged.
BEGIN;
INSERT INTO auth.users(id) VALUES('f8000000-0000-4000-8000-000000000001'),('f8000000-0000-4000-8000-000000000002'),('f8000000-0000-4000-8000-000000000003');
DO $$ BEGIN
 IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='fj_record_calculation')<>1 THEN RAISE EXCEPTION 'fj_record_calculation overload added';END IF;
 IF to_regprocedure('public.fj_access_snapshot(uuid)') IS NULL THEN RAISE EXCEPTION 'fj_access_snapshot missing';END IF;
 IF NOT has_function_privilege('service_role','public.fj_access_snapshot(uuid)','EXECUTE') OR has_function_privilege('anon','public.fj_access_snapshot(uuid)','EXECUTE')
  OR has_function_privilege('authenticated','public.fj_access_snapshot(uuid)','EXECUTE') THEN RAISE EXCEPTION 'fj_access_snapshot grants wrong';END IF;
 IF EXISTS(SELECT 1 FROM pg_proc WHERE oid IN('public.fj_access_snapshot(uuid)'::regprocedure,'public.fj_record_calculation(uuid,uuid,text,text,text,date,text,text,boolean)'::regprocedure)
  AND (prosecdef OR NOT ('search_path=""'=ANY(proconfig)))) THEN RAISE EXCEPTION 'definer or mutable search_path';END IF;
 IF (SELECT provolatile FROM pg_proc WHERE oid='public.fj_access_snapshot(uuid)'::regprocedure)<>'s' THEN RAISE EXCEPTION 'snapshot must be STABLE (read-only)';END IF;
END; $$;
SET LOCAL ROLE service_role;
DO $$ DECLARE u uuid:='f8000000-0000-4000-8000-000000000001';d uuid:='f8d00000-0000-4000-8000-000000000001';n uuid:='f8e00000-0000-4000-8000-000000000001';
 first jsonb;r jsonb;used integer;
BEGIN
 first:=public.fj_record_calculation(u,d,repeat('1',64),'draw_tarot','tarot-v1',current_date);
 IF first->>'tier'<>'trial' OR (first->>'replayed')::boolean THEN RAISE EXCEPTION 'first draw: %',first;END IF;
 -- The app no longer looks up the original date: a retry on a later day sends today's date and still replays.
 r:=public.fj_record_calculation(u,d,repeat('1',64),'draw_tarot','tarot-v1',current_date+1);
 IF NOT (r->>'replayed')::boolean OR r->>'readingId'<>first->>'readingId' OR r->>'remainingAtCompletion'<>first->>'remainingAtCompletion' THEN RAISE EXCEPTION 'cross-day tarot retry not replayed: %',r;END IF;
 IF (SELECT target_date FROM public.user_readings WHERE id=(first->>'readingId')::uuid)<>current_date THEN RAISE EXCEPTION 'original draw date rewritten';END IF;
 -- Same drawId with a different input (count/key version/key) or another feature is still a conflict.
 r:=public.fj_record_calculation(u,d,repeat('2',64),'draw_tarot','tarot-v1',current_date+1);
 IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'different tarot input accepted: %',r;END IF;
 r:=public.fj_record_calculation(u,d,repeat('1',64),'calculate_numerology','tarot-v1',current_date);
 IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'feature mismatch accepted: %',r;END IF;
 r:=public.fj_record_calculation(u,d,repeat('1',64),'draw_tarot','tarot-v2',current_date);
 IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'algorithm mismatch accepted: %',r;END IF;
 -- Numerology stays bound to its calendar date.
 PERFORM public.fj_record_calculation(u,n,repeat('3',64),'calculate_numerology','num-v1',current_date);
 r:=public.fj_record_calculation(u,n,repeat('3',64),'calculate_numerology','num-v1',current_date+1);
 IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'numerology date change accepted: %',r;END IF;
 SELECT sum(used_count) INTO used FROM public.usage_counters WHERE user_id=u;
 IF used<>2 THEN RAISE EXCEPTION 'replays or conflicts consumed quota: %',used;END IF;
 -- After the trial ends, an identical retry of an earlier draw (within the 90-day ledger) replays without
 -- charging; a new draw is still refused.
 UPDATE public.user_access SET trial_started_at=now()-interval '15 days',trial_ends_at=now()-interval '1 day' WHERE user_id=u;
 r:=public.fj_record_calculation(u,d,repeat('1',64),'draw_tarot','tarot-v1',current_date+2);
 IF NOT coalesce((r->>'replayed')::boolean,false) OR r->>'tier'<>'free' OR r->>'readingId'<>first->>'readingId' THEN RAISE EXCEPTION 'post-trial retry not replayed: %',r;END IF;
 r:=public.fj_record_calculation(u,gen_random_uuid(),repeat('1',64),'draw_tarot','tarot-v1',current_date);
 IF r->>'reason' IS DISTINCT FROM 'FEATURE_NOT_INCLUDED' THEN RAISE EXCEPTION 'free user drew new tarot: %',r;END IF;
 r:=public.fj_record_calculation(u,d,repeat('2',64),'draw_tarot','tarot-v1',current_date);
 IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'post-trial conflicting retry accepted: %',r;END IF;
 IF (SELECT sum(used_count) FROM public.usage_counters WHERE user_id=u)<>2 THEN RAISE EXCEPTION 'post-trial retry consumed quota';END IF;
 -- Suspension still wins over any replay.
 UPDATE public.user_access SET suspended_at=now() WHERE user_id=u;
 r:=public.fj_record_calculation(u,d,repeat('1',64),'draw_tarot','tarot-v1',current_date);
 IF r->>'reason' IS DISTINCT FROM 'ACCOUNT_SUSPENDED' THEN RAISE EXCEPTION 'suspended replay allowed: %',r;END IF;
END; $$;
DO $$ DECLARE a uuid:='f8000000-0000-4000-8000-000000000002';b uuid:='f8000000-0000-4000-8000-000000000003';s jsonb;
BEGIN
 -- A user who never calculated has no user_access row: same inputs memberTier() used to read in two queries.
 s:=public.fj_access_snapshot(a);
 IF s<>'{"access":null,"subscriptions":[]}'::jsonb THEN RAISE EXCEPTION 'empty snapshot wrong: %',s;END IF;
 INSERT INTO public.user_access(user_id,trial_started_at,trial_ends_at,suspended_at) VALUES(a,'2026-10-01T00:00:00Z','2026-10-15T00:00:00Z',NULL);
 INSERT INTO public.subscriptions(user_id,provider,provider_customer_id,provider_subscription_id,status,current_period_end,verified_at)
  VALUES(a,'test_provider','cust_a','sub_a1','active','2026-11-01T00:00:00Z','2026-10-01T00:00:00Z'),
        (a,'test_provider','cust_a','sub_a2','canceled',NULL,NULL),
        (b,'test_provider','cust_b','sub_b1','active','2099-01-01T00:00:00Z','2026-10-01T00:00:00Z');
 s:=public.fj_access_snapshot(a);
 IF s->'access'<>jsonb_build_object('trial_ends_at','2026-10-15T00:00:00+00:00','suspended_at',NULL) THEN RAISE EXCEPTION 'access part wrong: %',s->'access';END IF;
 IF jsonb_array_length(s->'subscriptions')<>2 OR s::text LIKE '%sub_b1%' OR s::text LIKE '%2099%' THEN RAISE EXCEPTION 'subscriptions not limited to the user: %',s;END IF;
 IF NOT (s->'subscriptions') @> '[{"status":"active","current_period_end":"2026-11-01T00:00:00+00:00","verified_at":"2026-10-01T00:00:00+00:00"},{"status":"canceled","current_period_end":null,"verified_at":null}]'::jsonb
  THEN RAISE EXCEPTION 'subscription fields wrong: %',s->'subscriptions';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(s->'subscriptions') e WHERE e ?| ARRAY['user_id','provider_customer_id','provider_subscription_id']) THEN RAISE EXCEPTION 'snapshot exposes billing identifiers';END IF;
 BEGIN PERFORM public.fj_access_snapshot(NULL);RAISE EXCEPTION 'null user accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVALID_USER' THEN RAISE;END IF;END;
END; $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 BEGIN PERFORM public.fj_access_snapshot('f8000000-0000-4000-8000-000000000003');RAISE EXCEPTION 'client read another snapshot';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END; $$;
RESET ROLE;
ROLLBACK;
