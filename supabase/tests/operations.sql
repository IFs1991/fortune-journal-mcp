-- Operator side: post approval/publish state machine, run leases, metric snapshots and KPI reports.
-- Disposable database only; everything rolls back.
BEGIN;
SET LOCAL ROLE service_role;

-- ===== Publishing: approval is bound to the body hash; unknown outcomes are never re-published =====
DO $$
DECLARE
  pid uuid := 'e1000000-0000-4000-8000-000000000001';
  claim jsonb;
  r jsonb;
BEGIN
  INSERT INTO public.fortune_posts (id, account_key, body, body_sha256) VALUES (pid, '123', 'test-only post', repeat('c', 64));
  IF public.fj_approve_post(pid, repeat('d', 64)) THEN RAISE EXCEPTION 'approval with the wrong hash'; END IF;
  IF NOT public.fj_approve_post(pid, repeat('c', 64)) THEN RAISE EXCEPTION 'approval refused'; END IF;
  -- Editing an approved draft withdraws the approval.
  UPDATE public.fortune_posts SET body = 'edited', body_sha256 = repeat('e', 64) WHERE id = pid;
  IF (SELECT status FROM public.fortune_posts WHERE id = pid) <> 'draft' THEN RAISE EXCEPTION 'edit kept the approval'; END IF;
  UPDATE public.fortune_posts SET body = 'test-only post', body_sha256 = repeat('c', 64) WHERE id = pid;
  PERFORM public.fj_approve_post(pid, repeat('c', 64));

  BEGIN
    PERFORM public.fj_claim_publish(pid, repeat('d', 64));
    RAISE EXCEPTION 'claim with a different hash';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'POST_NOT_APPROVED_OR_NOT_DUE' THEN RAISE; END IF;
  END;
  claim := public.fj_claim_publish(pid, repeat('c', 64));
  IF NOT (claim->>'acquired')::boolean THEN RAISE EXCEPTION 'not claimed'; END IF;
  r := public.fj_claim_publish(pid, repeat('c', 64));
  IF (r->>'acquired')::boolean THEN RAISE EXCEPTION 'double publish claim'; END IF;
  BEGIN
    UPDATE public.fortune_posts SET body = 'changed while publishing', body_sha256 = repeat('f', 64) WHERE id = pid;
    RAISE EXCEPTION 'body changed while publishing';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'PUBLISHED_CONTENT_IMMUTABLE' THEN RAISE; END IF;
  END;

  -- Network error: the outcome is unknown and stays unknown.
  IF NOT public.fj_finish_publish(pid, (claim->>'runId')::uuid, NULL, '12345', 'THREADS_NETWORK_ERROR') THEN RAISE EXCEPTION 'finish refused'; END IF;
  IF (SELECT status FROM public.fortune_posts WHERE id = pid) <> 'publish_unknown' THEN RAISE EXCEPTION 'unknown publish not recorded'; END IF;
  r := public.fj_claim_publish(pid, repeat('c', 64));
  IF r->>'status' <> 'publish_unknown' OR (r->>'acquired')::boolean THEN RAISE EXCEPTION 'unknown publication retried: %', r; END IF;
  -- Reconciliation with the real external id is still possible.
  IF NOT public.fj_finish_publish(pid, (claim->>'runId')::uuid, '987', '12345') THEN RAISE EXCEPTION 'reconciliation refused'; END IF;
  IF (SELECT status FROM public.fortune_posts WHERE id = pid) <> 'published' THEN RAISE EXCEPTION 'reconciliation not applied'; END IF;
  IF public.fj_finish_publish(pid, (claim->>'runId')::uuid, '988', '12345') THEN RAISE EXCEPTION 'finished run finished again'; END IF;
END $$;

-- A publish lease that expired is resolved to unknown, never re-acquired.
DO $$
DECLARE
  pid uuid := 'e1000000-0000-4000-8000-000000000002';
  claim jsonb;
  r jsonb;
BEGIN
  INSERT INTO public.fortune_posts (id, account_key, body, body_sha256) VALUES (pid, '123', 'second post', repeat('a', 64));
  PERFORM public.fj_approve_post(pid, repeat('a', 64));
  claim := public.fj_claim_publish(pid, repeat('a', 64));
  UPDATE public.automation_runs SET lease_expires_at = now() - interval '1 second' WHERE id = (claim->>'runId')::uuid;
  r := public.fj_begin_run('publish_post', 'publish:' || pid, 'owner_agent', pid);
  IF (r->>'acquired')::boolean OR r->>'status' <> 'unknown' THEN RAISE EXCEPTION 'expired publish lease re-acquired: %', r; END IF;
  IF (SELECT status FROM public.fortune_posts WHERE id = pid) <> 'publish_unknown' THEN RAISE EXCEPTION 'post not marked unknown'; END IF;
END $$;

-- ===== Run leases for retryable tasks: at most 3 attempts, stale attempts cannot finish =====
DO $$
DECLARE
  a jsonb;
  b jsonb;
BEGIN
  a := public.fj_begin_run('import_posts', 'import:1', 'owner_agent');
  IF NOT (a->>'acquired')::boolean OR (a->>'attempt')::int <> 1 THEN RAISE EXCEPTION 'first run: %', a; END IF;
  b := public.fj_begin_run('import_posts', 'import:1', 'owner_agent');
  IF (b->>'acquired')::boolean THEN RAISE EXCEPTION 'running lease acquired twice'; END IF;
  IF NOT public.fj_finish_run((a->>'runId')::uuid, 1, false, 'THREADS_API_ERROR') THEN RAISE EXCEPTION 'failure not recorded'; END IF;
  b := public.fj_begin_run('import_posts', 'import:1', 'owner_agent');
  IF (b->>'attempt')::int <> 2 THEN RAISE EXCEPTION 'retry attempt: %', b; END IF;
  IF public.fj_finish_run((a->>'runId')::uuid, 1, true) THEN RAISE EXCEPTION 'stale attempt finished the run'; END IF;
  PERFORM public.fj_finish_run((b->>'runId')::uuid, 2, false, 'THREADS_API_ERROR');
  PERFORM public.fj_begin_run('import_posts', 'import:1', 'owner_agent');
  PERFORM public.fj_finish_run((b->>'runId')::uuid, 3, false, 'THREADS_API_ERROR');
  b := public.fj_begin_run('import_posts', 'import:1', 'owner_agent');
  IF (b->>'acquired')::boolean OR b->>'status' <> 'failed' THEN RAISE EXCEPTION 'more than 3 attempts: %', b; END IF;
  -- The refusal says no attempt will ever be granted again, so callers cannot report it as "already done".
  IF NOT (b->>'exhausted')::boolean OR (b->>'attempts')::int <> 3 THEN RAISE EXCEPTION 'exhaustion not reported: %', b; END IF;
  a := public.fj_begin_run('purge', 'purge:done', 'server_cron');
  PERFORM public.fj_finish_run((a->>'runId')::uuid, 1, true);
  b := public.fj_begin_run('purge', 'purge:done', 'server_cron');
  IF (b->>'exhausted')::boolean OR b->>'status' <> 'succeeded' THEN RAISE EXCEPTION 'finished run reported exhausted: %', b; END IF;
  -- A third attempt whose lease expired without finishing is exhausted too (no silent "running" forever).
  a := public.fj_begin_run('import_posts', 'import:stuck', 'owner_agent');
  UPDATE public.automation_runs SET attempts = 3, lease_expires_at = now() - interval '1 second' WHERE id = (a->>'runId')::uuid;
  b := public.fj_begin_run('import_posts', 'import:stuck', 'owner_agent');
  IF (b->>'acquired')::boolean OR NOT (b->>'exhausted')::boolean THEN RAISE EXCEPTION 'stuck attempt not exhausted: %', b; END IF;
  BEGIN
    PERFORM public.fj_begin_run('collect_post_metrics', 'k', 'owner_agent', 'e1000000-0000-4000-8000-000000000001');
    PERFORM public.fj_begin_run('collect_post_metrics', 'k', 'owner_agent', 'e1000000-0000-4000-8000-000000000002');
    RAISE EXCEPTION 'same key reused for another post';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'IDEMPOTENCY_CONFLICT' THEN RAISE; END IF;
  END;
END $$;

-- ===== Snapshots and KPIs: endpoints not sums, actual ages, NULL is not zero =====
DO $$
DECLARE
  pid uuid := 'e1000000-0000-4000-8000-000000000003';
  r jsonb;
  rate numeric;
BEGIN
  INSERT INTO public.fortune_posts (id, account_key, external_post_id, body, body_sha256, status, published_at)
  VALUES (pid, '123', '777', 'published post', repeat('a', 64), 'published', now() - interval '3 days');
  INSERT INTO public.post_metric_snapshots (post_id, run_id, collected_at, target_age_hours, snapshot_kind, api_version, views, likes, replies, reposts, quotes)
  VALUES (pid, gen_random_uuid(), now() - interval '2 days', 24, 'scheduled', 'v1.0', 100, 2, 1, 1, 1),
         (pid, gen_random_uuid(), now() - interval '1 day 23 hours', 24, 'scheduled', 'v1.0', 100, 90, 1, 1, 1);
  SELECT engagement_pct INTO rate FROM public.fj_post_24h WHERE post_id = pid;
  IF rate <> 5 THEN RAISE EXCEPTION '24h snapshot must be the one closest to 24h, got %', rate; END IF;
  BEGIN
    INSERT INTO public.post_metric_snapshots (post_id, run_id, collected_at, snapshot_kind, target_age_hours, api_version)
    VALUES (pid, gen_random_uuid(), now(), 'manual', 24, 'v1.0');
    RAISE EXCEPTION 'manual snapshot labelled as a scheduled age';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  INSERT INTO public.account_metric_snapshots (account_key, run_id, collected_at, metric_name, metric_value, period_kind, api_version)
  VALUES ('growthtest', gen_random_uuid(), now() - interval '7 days 1 hour', 'followers_count', 20, 'point_in_time', 'v1.0'),
         ('growthtest', gen_random_uuid(), now() - interval '1 hour', 'followers_count', 17, 'point_in_time', 'v1.0');
  r := public.fj_follower_growth('growthtest');
  IF (r->>'netGrowth')::int <> -3 OR NOT (r->>'complete')::boolean THEN RAISE EXCEPTION 'follower growth: %', r; END IF;
  r := public.fj_follower_growth('missing');
  IF r->>'netGrowth' IS NOT NULL OR (r->>'complete')::boolean THEN RAISE EXCEPTION 'missing baseline became a number: %', r; END IF;
  BEGIN
    INSERT INTO public.account_metric_snapshots (account_key, run_id, collected_at, metric_name, metric_value, period_kind, period_start, period_end, api_version)
    VALUES ('growthtest', gen_random_uuid(), now(), 'followers_count', 1, 'day', now() - interval '1 day', now(), 'v1.0');
    RAISE EXCEPTION 'follower stock stored as a flow';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  r := public.fj_cohort_report(now() - interval '2 days', now());
  IF r->>'population' <> 'consented_near_signup_accounts_only' THEN RAISE EXCEPTION 'population label missing'; END IF;
  BEGIN
    PERFORM public.fj_cohort_report(now(), now() - interval '1 day');
    RAISE EXCEPTION 'inverted window accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_COHORT_WINDOW' THEN RAISE; END IF;
  END;

  r := public.fj_operation_report(now() - interval '1 day', now() + interval '1 minute');
  IF r->>'caveat' NOT LIKE 'Missing cost is unobserved%' OR jsonb_array_length(r->'tasks') = 0 THEN RAISE EXCEPTION 'operation report: %', r; END IF;
END $$;

-- Immature cohorts report NULL rates, not 0%.
RESET ROLE;
INSERT INTO auth.users (id) VALUES ('e1000000-0000-4000-8000-0000000000aa');
SET LOCAL ROLE service_role;
DO $$
DECLARE
  r jsonb;
  row jsonb;
BEGIN
  PERFORM public.fj_set_privacy('e1000000-0000-4000-8000-0000000000aa', true, false, '2026-10-v2', now() - interval '1 hour');
  r := public.fj_cohort_report(now() - interval '2 days', now());
  IF jsonb_array_length(r->'rows') <> 1 THEN RAISE EXCEPTION 'cohort rows: %', r; END IF;
  FOR row IN SELECT * FROM jsonb_array_elements(r->'rows') LOOP
    IF (row->>'cohort_size')::int <> 1 OR row->>'d7_exact_pct' IS NOT NULL OR row->>'paid_35d_pct' IS NOT NULL OR row->>'activation_24h_pct' IS NOT NULL THEN
      RAISE EXCEPTION 'immature cohort reported a rate: %', row;
    END IF;
  END LOOP;
END $$;

RESET ROLE;
ROLLBACK;
