-- Migration 06: fj_set_privacy must work as service_role WITHOUT any auth.users privilege.
BEGIN;
INSERT INTO auth.users(id) VALUES('c0000000-0000-4000-8000-00000000000c'),('d0000000-0000-4000-8000-00000000000d'),('e0000000-0000-4000-8000-00000000000e');
DO $$ BEGIN
 IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='fj_set_privacy')<>1 THEN RAISE EXCEPTION 'stale fj_set_privacy overload remains';END IF;
 IF has_table_privilege('service_role','auth.users','SELECT') THEN RAISE EXCEPTION 'test environment grants auth.users; it would mask the defect';END IF;
END; $$;
SET LOCAL ROLE service_role;
DO $$ BEGIN
 PERFORM public.fj_set_privacy('c0000000-0000-4000-8000-00000000000c',true,false,'2026-10-v2',now()-interval '1 hour');
 IF NOT EXISTS(SELECT 1 FROM public.funnel_events WHERE user_id='c0000000-0000-4000-8000-00000000000c' AND event_name='registration') THEN RAISE EXCEPTION 'near-signup cohort entry missing';END IF;
 PERFORM public.fj_set_privacy('d0000000-0000-4000-8000-00000000000d',true,false,'2026-10-v2',now()-interval '3 days');
 IF EXISTS(SELECT 1 FROM public.funnel_events WHERE user_id='d0000000-0000-4000-8000-00000000000d' AND event_name='registration') THEN RAISE EXCEPTION 'old account fabricated into signup cohort';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.funnel_events WHERE user_id='d0000000-0000-4000-8000-00000000000d' AND event_name='analytics_enrolled') THEN RAISE EXCEPTION 'enrollment not recorded';END IF;
 PERFORM public.fj_set_privacy('e0000000-0000-4000-8000-00000000000e',true,true,'2026-10-v2');
 IF EXISTS(SELECT 1 FROM public.funnel_events WHERE user_id='e0000000-0000-4000-8000-00000000000e' AND event_name='registration') THEN RAISE EXCEPTION 'unknown registration time fabricated';END IF;
 BEGIN PERFORM public.fj_set_privacy('e0000000-0000-4000-8000-00000000000e',true,true,'2026-10-v2',now()+interval '1 hour');RAISE EXCEPTION 'future registration accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVALID_PRIVACY_CHOICE' THEN RAISE;END IF;END;
END; $$;
RESET ROLE;
ROLLBACK;
