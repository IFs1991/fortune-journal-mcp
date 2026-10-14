BEGIN;
INSERT INTO auth.users(id) VALUES('11111111-1111-4111-8111-111111111111'),('22222222-2222-4222-8222-222222222222');
SET LOCAL ROLE service_role;
SELECT public.fj_set_privacy('11111111-1111-4111-8111-111111111111',true,true,'2026-10-v2');
SELECT public.fj_record_calculation('11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',repeat('a',64),'calculate_numerology','test-v1',current_date,'love','unknown',true);
SELECT public.fj_record_calculation('22222222-2222-4222-8222-222222222222','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',repeat('b',64),'calculate_numerology','test-v1',current_date,NULL,'unknown',false);
RESET ROLE;
DO $$ DECLARE n integer; f record; BEGIN
 SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity;
 IF n<>11 THEN RAISE EXCEPTION 'expected 11 RLS protected app tables, found %',n; END IF;
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'fj_%' LOOP
  IF has_function_privilege('anon',f.signature,'EXECUTE') OR has_function_privilege('authenticated',f.signature,'EXECUTE') THEN RAISE EXCEPTION 'client can execute %',f.signature; END IF;
 END LOOP;
 IF has_table_privilege('authenticated','public.fortune_posts','SELECT') OR has_table_privilege('authenticated','public.billing_events','SELECT') THEN RAISE EXCEPTION 'operator table leaked'; END IF;
END; $$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
DO $$ BEGIN
 IF (SELECT count(id) FROM public.user_readings)<>1 THEN RAISE EXCEPTION 'cross-user reading leak'; END IF;
 IF EXISTS(SELECT id FROM public.user_readings WHERE user_id='22222222-2222-4222-8222-222222222222') THEN RAISE EXCEPTION 'BOLA'; END IF;
 BEGIN PERFORM request_fingerprint FROM public.user_readings;RAISE EXCEPTION 'fingerprint readable';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN UPDATE public.user_access SET trial_ends_at=now()+interval '100 years';RAISE EXCEPTION 'user can grant trial';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN UPDATE public.subscriptions SET status='active';RAISE EXCEPTION 'user can grant paid';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.fj_purge_expired();RAISE EXCEPTION 'user can purge';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM id FROM public.fortune_posts;RAISE EXCEPTION 'user can read marketing ops';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END; $$;
SET LOCAL ROLE anon;
DO $$ BEGIN
 BEGIN PERFORM id FROM public.user_readings;RAISE EXCEPTION 'anonymous read';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.fj_set_privacy('11111111-1111-4111-8111-111111111111',true,true,'2026-10-v2');RAISE EXCEPTION 'anonymous RPC';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END; $$;
RESET ROLE;
ROLLBACK;
