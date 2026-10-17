-- fj_record_calculation / fj_access_status: trial start, tiers, usage limits, idempotent replay, atomicity.
-- Disposable database only; everything rolls back. Concurrency is covered by scripts/test-db.sh.
BEGIN;
INSERT INTO auth.users (id) VALUES
  ('c1000000-0000-4000-8000-000000000001'),  -- trial user
  ('c1000000-0000-4000-8000-000000000002'),  -- free user (trial expired)
  ('c1000000-0000-4000-8000-000000000003'),  -- subscription user
  ('c1000000-0000-4000-8000-000000000004'),  -- atomicity / suspension
  ('c1000000-0000-4000-8000-000000000005');  -- never calculated
SET LOCAL ROLE service_role;

-- ===== Trial starts at the first calculation, never at consent =====
DO $$
DECLARE
  u uuid := 'c1000000-0000-4000-8000-000000000001';
  req uuid := 'c1a00000-0000-4000-8000-000000000001';
  first jsonb;
  again jsonb;
  r jsonb;
BEGIN
  PERFORM public.fj_set_privacy(u, true, true, '2026-10-v2');
  IF (SELECT trial_started_at FROM public.user_access WHERE user_id = u) IS NOT NULL THEN
    RAISE EXCEPTION 'consent started the trial';
  END IF;
  IF public.fj_access_status(u) <> 'free' THEN RAISE EXCEPTION 'tier before first calculation must be free'; END IF;

  first := public.fj_record_calculation(u, req, repeat('a', 64), 'calculate_numerology', 'num-v1', current_date, 'love', 'unknown', true);
  IF first->>'tier' <> 'trial' OR (first->>'replayed')::boolean OR (first->>'remainingAtCompletion')::int <> 99 THEN
    RAISE EXCEPTION 'first calculation: %', first;
  END IF;
  IF public.fj_access_status(u) <> 'trial' THEN RAISE EXCEPTION 'access status after first calculation'; END IF;
  IF (SELECT trial_ends_at - trial_started_at FROM public.user_access WHERE user_id = u) <> interval '14 days' THEN
    RAISE EXCEPTION 'trial length';
  END IF;
  IF (SELECT first_calculated_at FROM public.user_access WHERE user_id = u) IS NULL THEN
    RAISE EXCEPTION 'first_calculated_at not recorded';
  END IF;

  -- Identical retry: same reading, same remaining count, no new ledger row (= no new usage).
  again := public.fj_record_calculation(u, req, repeat('a', 64), 'calculate_numerology', 'num-v1', current_date, 'love', 'unknown', true);
  IF NOT (again->>'replayed')::boolean OR again->>'readingId' <> first->>'readingId'
     OR again->>'remainingAtCompletion' <> first->>'remainingAtCompletion' THEN
    RAISE EXCEPTION 'retry not replayed: %', again;
  END IF;
  IF (SELECT count(*) FROM public.user_readings WHERE user_id = u) <> 1 THEN RAISE EXCEPTION 'retry consumed usage'; END IF;

  -- Same request id with different input, feature, algorithm or (numerology) date is a conflict.
  r := public.fj_record_calculation(u, req, repeat('b', 64), 'calculate_numerology', 'num-v1', current_date);
  IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'different input accepted: %', r; END IF;
  r := public.fj_record_calculation(u, req, repeat('a', 64), 'draw_tarot', 'num-v1', current_date);
  IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'feature mismatch accepted: %', r; END IF;
  r := public.fj_record_calculation(u, req, repeat('a', 64), 'calculate_numerology', 'num-v2', current_date);
  IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'algorithm mismatch accepted: %', r; END IF;
  r := public.fj_record_calculation(u, req, repeat('a', 64), 'calculate_numerology', 'num-v1', current_date + 1);
  IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'numerology date change accepted: %', r; END IF;
  IF (SELECT count(*) FROM public.user_readings WHERE user_id = u) <> 1 THEN RAISE EXCEPTION 'conflicts consumed usage'; END IF;
END $$;

-- ===== Tarot is keyed to its drawId: a retry on a later day replays; the original row is kept =====
DO $$
DECLARE
  u uuid := 'c1000000-0000-4000-8000-000000000001';
  draw uuid := 'c1d00000-0000-4000-8000-000000000001';
  first jsonb;
  r jsonb;
BEGIN
  first := public.fj_record_calculation(u, draw, repeat('1', 64), 'draw_tarot', 'tarot-v1', current_date);
  r := public.fj_record_calculation(u, draw, repeat('1', 64), 'draw_tarot', 'tarot-v1', current_date + 1);
  IF NOT (r->>'replayed')::boolean OR r->>'readingId' <> first->>'readingId' THEN RAISE EXCEPTION 'cross-day replay: %', r; END IF;
  IF (SELECT target_date FROM public.user_readings WHERE id = (first->>'readingId')::uuid) <> current_date THEN
    RAISE EXCEPTION 'original draw date rewritten';
  END IF;

  -- After the trial ends an identical retry still replays (tier now free); a new draw is refused.
  UPDATE public.user_access SET trial_started_at = now() - interval '15 days', trial_ends_at = now() - interval '1 day'
   WHERE user_id = u;
  r := public.fj_record_calculation(u, draw, repeat('1', 64), 'draw_tarot', 'tarot-v1', current_date + 2);
  IF NOT coalesce((r->>'replayed')::boolean, false) OR r->>'tier' <> 'free' OR r->>'readingId' <> first->>'readingId' THEN
    RAISE EXCEPTION 'post-trial retry not replayed: %', r;
  END IF;
  r := public.fj_record_calculation(u, gen_random_uuid(), repeat('1', 64), 'draw_tarot', 'tarot-v1', current_date);
  IF r->>'reason' IS DISTINCT FROM 'FEATURE_NOT_INCLUDED' THEN RAISE EXCEPTION 'free user drew new tarot: %', r; END IF;
  r := public.fj_record_calculation(u, draw, repeat('2', 64), 'draw_tarot', 'tarot-v1', current_date);
  IF r->>'reason' IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT' THEN RAISE EXCEPTION 'post-trial conflicting retry: %', r; END IF;
  IF (SELECT count(*) FROM public.user_readings WHERE user_id = u) <> 2 THEN RAISE EXCEPTION 'post-trial calls consumed usage'; END IF;
END $$;

-- ===== Free: 3 numerology per ISO week; trial usage does not count against it =====
DO $$
DECLARE
  u uuid := 'c1000000-0000-4000-8000-000000000002';
  remaining int[] := '{}';
  r jsonb;
BEGIN
  INSERT INTO public.user_access (user_id, trial_started_at, trial_ends_at)
  VALUES (u, now() - interval '20 days', now() - interval '6 days');
  -- A reading recorded under the trial earlier this week is a different usage bucket.
  INSERT INTO public.user_readings (user_id, request_id, request_fingerprint, feature_key, algorithm_version, target_date,
    tier_at_use, remaining_after, calculated_at)
  VALUES (u, gen_random_uuid(), repeat('9', 64), 'calculate_numerology', 'num-v1', current_date, 'trial', 99,
    greatest(date_trunc('week', now(), 'UTC'), now() - interval '1 second'));
  FOR i IN 1..3 LOOP
    r := public.fj_record_calculation(u, gen_random_uuid(), repeat('c', 64), 'calculate_numerology', 'num-v1', current_date);
    IF r->>'tier' <> 'free' THEN RAISE EXCEPTION 'free tier expected: %', r; END IF;
    remaining := remaining || (r->>'remainingAtCompletion')::int;
  END LOOP;
  IF remaining <> '{2,1,0}' THEN RAISE EXCEPTION 'free remaining %', remaining; END IF;
  r := public.fj_record_calculation(u, gen_random_uuid(), repeat('c', 64), 'calculate_numerology', 'num-v1', current_date);
  IF r->>'reason' IS DISTINCT FROM 'USAGE_LIMIT_REACHED' THEN RAISE EXCEPTION '4th free calculation: %', r; END IF;
  IF (SELECT count(*) FROM public.user_readings WHERE user_id = u AND tier_at_use = 'free') <> 3 THEN
    RAISE EXCEPTION 'limit refusal wrote a ledger row';
  END IF;
  -- Readings from previous weeks no longer count.
  UPDATE public.user_readings SET calculated_at = date_trunc('week', now(), 'UTC') - interval '1 second'
   WHERE user_id = u AND tier_at_use = 'free';
  r := public.fj_record_calculation(u, gen_random_uuid(), repeat('c', 64), 'calculate_numerology', 'num-v1', current_date);
  IF (r->>'remainingAtCompletion')::int <> 2 THEN RAISE EXCEPTION 'new ISO week did not reset: %', r; END IF;
END $$;

-- ===== Premium needs a verified, current, active subscription; unverified/expired never grant it =====
DO $$
DECLARE
  u uuid := 'c1000000-0000-4000-8000-000000000003';
  r jsonb;
BEGIN
  INSERT INTO public.subscriptions (user_id, provider, provider_customer_id, provider_subscription_id, status, current_period_end)
  VALUES (u, 'test_provider', 'cust', 'sub_c3', 'active', now() + interval '30 days');
  r := public.fj_record_calculation(u, gen_random_uuid(), repeat('d', 64), 'draw_tarot', 'tarot-v1', current_date);
  IF r->>'tier' <> 'trial' THEN RAISE EXCEPTION 'unverified subscription granted %', r->>'tier'; END IF;
  UPDATE public.subscriptions SET verified_at = now(), current_period_end = now() - interval '1 second' WHERE user_id = u;
  IF public.fj_access_status(u) <> 'trial' THEN RAISE EXCEPTION 'expired subscription granted premium'; END IF;
  UPDATE public.subscriptions SET current_period_end = now() + interval '1 day' WHERE user_id = u;
  IF public.fj_access_status(u) <> 'premium' THEN RAISE EXCEPTION 'verified subscription not premium'; END IF;
  r := public.fj_record_calculation(u, gen_random_uuid(), repeat('d', 64), 'draw_tarot', 'tarot-v1', current_date);
  -- The trial draw above is a different bucket: Premium starts from its own 200/day.
  IF r->>'tier' <> 'premium' OR (r->>'remainingAtCompletion')::int <> 199 THEN RAISE EXCEPTION 'premium usage: %', r; END IF;
  UPDATE public.subscriptions SET status = 'past_due' WHERE user_id = u;
  IF public.fj_access_status(u) <> 'trial' THEN RAISE EXCEPTION 'past_due subscription granted premium'; END IF;
END $$;

-- ===== Atomicity: a failure after the ledger insert leaves no usage and no trial start =====
RESET ROLE;
CREATE FUNCTION pg_temp.fail_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'INJECTED_FAILURE';
END $$;
INSERT INTO public.user_access (user_id, analytics_consent_at, consent_version, consent_updated_at)
VALUES ('c1000000-0000-4000-8000-000000000004', now(), '2026-10-v2', now());
CREATE TRIGGER fj_test_fail BEFORE INSERT ON public.funnel_events FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_event();
SET LOCAL ROLE service_role;
DO $$
DECLARE
  u uuid := 'c1000000-0000-4000-8000-000000000004';
BEGIN
  BEGIN
    PERFORM public.fj_record_calculation(u, gen_random_uuid(), repeat('e', 64), 'calculate_numerology', 'num-v1', current_date,
      NULL, 'unknown', true);
    RAISE EXCEPTION 'injected failure not raised';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INJECTED_FAILURE' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.user_readings WHERE user_id = u) THEN RAISE EXCEPTION 'usage consumed without a commit'; END IF;
  IF (SELECT trial_started_at FROM public.user_access WHERE user_id = u) IS NOT NULL THEN RAISE EXCEPTION 'partial trial start'; END IF;
END $$;
RESET ROLE;
DROP TRIGGER fj_test_fail ON public.funnel_events;
SET LOCAL ROLE service_role;

-- ===== Suspension wins over everything, including replays =====
DO $$
DECLARE
  u uuid := 'c1000000-0000-4000-8000-000000000004';
  req uuid := gen_random_uuid();
  r jsonb;
BEGIN
  PERFORM public.fj_record_calculation(u, req, repeat('e', 64), 'calculate_numerology', 'num-v1', current_date);
  UPDATE public.user_access SET suspended_at = now() WHERE user_id = u;
  IF public.fj_access_status(u) <> 'suspended' THEN RAISE EXCEPTION 'suspension not reported'; END IF;
  r := public.fj_record_calculation(u, req, repeat('e', 64), 'calculate_numerology', 'num-v1', current_date);
  IF r->>'reason' IS DISTINCT FROM 'ACCOUNT_SUSPENDED' THEN RAISE EXCEPTION 'suspended replay allowed: %', r; END IF;
END $$;

-- ===== Topic needs analytics AND interest consent AND the global analytics switch =====
DO $$
DECLARE
  u uuid := 'c1000000-0000-4000-8000-000000000001';
  r jsonb;
BEGIN
  UPDATE public.user_access SET trial_started_at = now(), trial_ends_at = now() + interval '14 days' WHERE user_id = u;
  r := public.fj_record_calculation(u, gen_random_uuid(), repeat('f', 64), 'calculate_numerology', 'num-v1', current_date, 'work', 'unknown', false);
  IF (SELECT topic FROM public.user_readings WHERE id = (r->>'readingId')::uuid) IS NOT NULL THEN RAISE EXCEPTION 'topic stored with analytics switch off'; END IF;
  r := public.fj_record_calculation(u, gen_random_uuid(), repeat('f', 64), 'calculate_numerology', 'num-v1', current_date, 'work', 'unknown', true);
  IF (SELECT topic FROM public.user_readings WHERE id = (r->>'readingId')::uuid) IS DISTINCT FROM 'work' THEN RAISE EXCEPTION 'topic not stored with consent'; END IF;
  PERFORM public.fj_set_privacy(u, true, false, '2026-10-v2');
  r := public.fj_record_calculation(u, gen_random_uuid(), repeat('f', 64), 'calculate_numerology', 'num-v1', current_date, 'money', 'unknown', true);
  IF (SELECT topic FROM public.user_readings WHERE id = (r->>'readingId')::uuid) IS NOT NULL THEN RAISE EXCEPTION 'topic stored without interest consent'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.funnel_events WHERE reading_id = (r->>'readingId')::uuid AND event_name = 'reading_completed') THEN
    RAISE EXCEPTION 'reading_completed event missing for a consenting user';
  END IF;
END $$;

-- ===== Validation and the access-status contract =====
DO $$
BEGIN
  IF public.fj_access_status('c1000000-0000-4000-8000-000000000005') <> 'free' THEN RAISE EXCEPTION 'unknown user must be free'; END IF;
  IF EXISTS (SELECT 1 FROM public.user_access WHERE user_id = 'c1000000-0000-4000-8000-000000000005') THEN
    RAISE EXCEPTION 'access status wrote a row';
  END IF;
  BEGIN
    PERFORM public.fj_access_status(NULL);
    RAISE EXCEPTION 'null user accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_USER' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.fj_record_calculation('c1000000-0000-4000-8000-000000000005', gen_random_uuid(), 'not-a-hash', 'calculate_numerology', 'v1', current_date);
    RAISE EXCEPTION 'bad fingerprint accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_CALCULATION_METADATA' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.fj_record_calculation('c1000000-0000-4000-8000-000000000005', gen_random_uuid(), repeat('a', 64), 'calculate_numerology', 'v1', current_date, 'health');
    RAISE EXCEPTION 'unknown topic accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_CALCULATION_METADATA' THEN RAISE; END IF;
  END;
  IF (SELECT provolatile FROM pg_proc WHERE oid = 'public.fj_access_status(uuid)'::regprocedure) <> 's' THEN
    RAISE EXCEPTION 'fj_access_status must be STABLE (read-only)';
  END IF;
END $$;

RESET ROLE;
ROLLBACK;
