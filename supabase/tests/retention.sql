-- fj_purge_expired and account deletion: what is deleted, what must survive.
-- Disposable database only; everything rolls back.
BEGIN;
INSERT INTO auth.users (id) VALUES ('f1000000-0000-4000-8000-000000000001'), ('f1000000-0000-4000-8000-000000000002');
SET LOCAL ROLE service_role;

DO $$
DECLARE
  u uuid := 'f1000000-0000-4000-8000-000000000001';
  recent uuid;
  old uuid;
  post uuid := 'f1e00000-0000-4000-8000-000000000001';
  stuck uuid := 'f1e00000-0000-4000-8000-000000000002';
  old_run uuid := gen_random_uuid();
  r jsonb;
BEGIN
  PERFORM public.fj_set_privacy(u, true, false, '2026-10-v2');
  recent := (public.fj_record_calculation(u, gen_random_uuid(), repeat('a', 64), 'calculate_numerology', 'v1', current_date, NULL, 'unknown', true)->>'readingId')::uuid;
  INSERT INTO public.user_readings (user_id, request_id, request_fingerprint, feature_key, algorithm_version, target_date, tier_at_use, remaining_after, calculated_at)
  VALUES (u, gen_random_uuid(), repeat('9', 64), 'calculate_numerology', 'v1', current_date - 91, 'trial', 99, now() - interval '91 days')
  RETURNING id INTO old;
  PERFORM public.fj_submit_feedback(u, old, 3::smallint, 'unclear');
  INSERT INTO public.funnel_events (user_id, event_name, dedupe_key, occurred_at, observation, reading_id)
  VALUES (u, 'reading_completed', 'reading:old', now() - interval '89 days', 'server', old),
         (u, 'mcp_connected', 'connected:old', now() - interval '91 days', 'server', NULL);

  INSERT INTO public.automation_runs (id, task, idempotency_key, status, actor_kind, started_at, finished_at)
  VALUES (old_run, 'collect_account_metrics', 'old-run', 'succeeded', 'server_cron', now() - interval '91 days', now() - interval '91 days');
  INSERT INTO public.account_metric_snapshots (account_key, run_id, collected_at, metric_name, metric_value, period_kind, api_version)
  VALUES ('123', old_run, now() - interval '91 days', 'followers_count', 10, 'point_in_time', 'v1.0'),
         ('123', gen_random_uuid(), now() - interval '401 days', 'followers_count', 9, 'point_in_time', 'v1.0');
  INSERT INTO public.fortune_posts (id, account_key, external_post_id, body, body_sha256, status, published_at)
  VALUES (post, '123', '1', 'old public post', repeat('a', 64), 'published', now() - interval '500 days');
  INSERT INTO public.post_metric_snapshots (post_id, run_id, collected_at, snapshot_kind, api_version, views)
  VALUES (post, gen_random_uuid(), now() - interval '401 days', 'manual', 'v1.0', 1),
         (post, old_run, now() - interval '91 days', 'manual', 'v1.0', 2);

  -- An in-flight publish whose lease expired.
  INSERT INTO public.fortune_posts (id, account_key, body, body_sha256) VALUES (stuck, '123', 'stuck', repeat('b', 64));
  PERFORM public.fj_approve_post(stuck, repeat('b', 64));
  PERFORM public.fj_claim_publish(stuck, repeat('b', 64));
  UPDATE public.automation_runs SET lease_expires_at = now() - interval '1 second' WHERE post_id = stuck;

  r := public.fj_purge_expired();
  IF (r->>'readingsDeleted')::int <> 1 OR (r->>'eventsDeleted')::int <> 1 OR (r->>'runsDeleted')::int <> 1 OR (r->>'snapshotsDeleted')::int <> 2 THEN
    RAISE EXCEPTION 'purge counts: %', r;
  END IF;
  IF EXISTS (SELECT 1 FROM public.user_readings WHERE id = old) THEN RAISE EXCEPTION 'expired reading kept'; END IF;
  IF EXISTS (SELECT 1 FROM public.reading_feedback WHERE reading_id = old) OR EXISTS (SELECT 1 FROM public.funnel_events WHERE dedupe_key = 'reading:old') THEN
    RAISE EXCEPTION 'feedback/event of an expired reading kept';
  END IF;
  IF EXISTS (SELECT 1 FROM public.funnel_events WHERE dedupe_key = 'connected:old') THEN RAISE EXCEPTION 'expired event kept'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_readings WHERE id = recent) OR NOT EXISTS (SELECT 1 FROM public.funnel_events WHERE reading_id = recent) THEN
    RAISE EXCEPTION 'recent data purged';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.funnel_events WHERE user_id = u AND event_name = 'analytics_enrolled') THEN RAISE EXCEPTION 'recent enrollment purged'; END IF;
  IF EXISTS (SELECT 1 FROM public.automation_runs WHERE id = old_run) THEN RAISE EXCEPTION 'expired run kept'; END IF;
  -- Snapshots outlive their 90-day run (400-day retention) and keep their capture identity.
  IF (SELECT count(*) FROM public.account_metric_snapshots WHERE run_id = old_run) <> 1
     OR (SELECT count(*) FROM public.post_metric_snapshots WHERE run_id = old_run) <> 1 THEN
    RAISE EXCEPTION 'snapshot deleted with its run';
  END IF;
  IF (SELECT status FROM public.fortune_posts WHERE id = stuck) <> 'publish_unknown'
     OR (SELECT status FROM public.automation_runs WHERE post_id = stuck) <> 'unknown' THEN
    RAISE EXCEPTION 'expired publish lease not resolved to unknown';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.fortune_posts WHERE id = post) THEN RAISE EXCEPTION 'published post purged'; END IF;
END $$;

-- Account deletion removes every per-user row; subscription bindings and the money ledger stay de-identified (billing.sql).
RESET ROLE;
DELETE FROM auth.users WHERE id = 'f1000000-0000-4000-8000-000000000001';
DO $$
DECLARE
  t text;
  n bigint;
BEGIN
  FOREACH t IN ARRAY ARRAY['user_access', 'subscriptions', 'user_readings', 'funnel_events', 'reading_feedback'] LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE user_id = %L', t, 'f1000000-0000-4000-8000-000000000001') INTO n;
    IF n <> 0 THEN RAISE EXCEPTION 'deleted user data remains in %', t; END IF;
  END LOOP;
END $$;
ROLLBACK;
