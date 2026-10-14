-- v0.2 read-only catalog assertions. Safe for a reviewed staging admin session.
-- This does not replace A/B user fixtures or actual Supabase JWT/OAuth tests.
DO $$ DECLARE tbl text; f record;
BEGIN
 FOREACH tbl IN ARRAY ARRAY['user_access','subscriptions','usage_counters','billing_events','fortune_posts','post_metric_snapshots','account_metric_snapshots','automation_runs','user_readings','funnel_events','reading_feedback'] LOOP
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid=format('public.%I',tbl)::regclass) THEN RAISE EXCEPTION 'RLS missing for %',tbl;END IF;
  IF has_any_column_privilege('anon',format('public.%I',tbl),'SELECT') THEN RAISE EXCEPTION 'anonymous read on %',tbl;END IF;
  IF has_table_privilege('authenticated',format('public.%I',tbl),'INSERT') OR has_table_privilege('authenticated',format('public.%I',tbl),'UPDATE') OR has_table_privilege('authenticated',format('public.%I',tbl),'DELETE') THEN RAISE EXCEPTION 'client mutation on %',tbl;END IF;
 END LOOP;
 FOREACH tbl IN ARRAY ARRAY['billing_events','fortune_posts','post_metric_snapshots','account_metric_snapshots','automation_runs','funnel_events'] LOOP
  IF has_any_column_privilege('authenticated',format('public.%I',tbl),'SELECT') THEN RAISE EXCEPTION 'operator table exposed: %',tbl;END IF;
 END LOOP;
 IF has_column_privilege('authenticated','public.user_readings','request_fingerprint','SELECT') THEN RAISE EXCEPTION 'fingerprint exposed';END IF;
 FOR f IN SELECT p.oid::regprocedure AS signature,p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'fj_%' LOOP
  IF f.prosecdef OR has_function_privilege('anon',f.signature,'EXECUTE') OR has_function_privilege('authenticated',f.signature,'EXECUTE') THEN RAISE EXCEPTION 'RPC privilege problem: %',f.signature;END IF;
 END LOOP;
 IF has_function_privilege('service_role','public.consume_usage(uuid,text,text,date,integer)','EXECUTE') THEN RAISE EXCEPTION 'obsolete quota entrypoint still enabled';END IF;
END; $$;
