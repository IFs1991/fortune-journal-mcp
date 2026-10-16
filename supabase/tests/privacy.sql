-- Optional analytics: consent, withdrawal, registration cohort, attribution, feedback and self-reports.
-- Disposable database only; everything rolls back.
BEGIN;
INSERT INTO auth.users (id) VALUES
  ('d1000000-0000-4000-8000-000000000001'),  -- new account, opts in
  ('d1000000-0000-4000-8000-000000000002'),  -- old account, opts in
  ('d1000000-0000-4000-8000-000000000003'),  -- never consents
  ('d1000000-0000-4000-8000-000000000004');  -- another user (cross-user checks)
SET LOCAL ROLE service_role;

-- ===== Registration cohort only for near-signup opt-ins, never fabricated =====
DO $$
BEGIN
  PERFORM public.fj_set_privacy('d1000000-0000-4000-8000-000000000001', true, false, '2026-10-v2', now() - interval '1 hour');
  IF NOT EXISTS (SELECT 1 FROM public.funnel_events WHERE user_id = 'd1000000-0000-4000-8000-000000000001' AND event_name = 'registration'
                 AND occurred_at = now() - interval '1 hour' AND observation = 'server') THEN
    RAISE EXCEPTION 'near-signup registration missing';
  END IF;
  PERFORM public.fj_set_privacy('d1000000-0000-4000-8000-000000000002', true, false, '2026-10-v2', now() - interval '3 days');
  IF EXISTS (SELECT 1 FROM public.funnel_events WHERE user_id = 'd1000000-0000-4000-8000-000000000002' AND event_name = 'registration') THEN
    RAISE EXCEPTION 'old account fabricated into the signup cohort';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.funnel_events WHERE user_id = 'd1000000-0000-4000-8000-000000000002' AND event_name = 'analytics_enrolled') THEN
    RAISE EXCEPTION 'enrollment not recorded';
  END IF;
  -- Unknown registration time records no cohort entry; a future one is invalid.
  PERFORM public.fj_set_privacy('d1000000-0000-4000-8000-000000000004', true, true, '2026-10-v2');
  IF EXISTS (SELECT 1 FROM public.funnel_events WHERE user_id = 'd1000000-0000-4000-8000-000000000004' AND event_name = 'registration') THEN
    RAISE EXCEPTION 'unknown registration time fabricated';
  END IF;
  BEGIN
    PERFORM public.fj_set_privacy('d1000000-0000-4000-8000-000000000004', true, true, '2026-10-v2', now() + interval '1 hour');
    RAISE EXCEPTION 'future registration accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_PRIVACY_CHOICE' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.fj_set_privacy('d1000000-0000-4000-8000-000000000003', false, true, '2026-10-v2');
    RAISE EXCEPTION 'interest consent without analytics accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_PRIVACY_CHOICE' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.fj_set_privacy('d1000000-0000-4000-8000-000000000003', true, false, 'latest');
    RAISE EXCEPTION 'malformed consent version accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_PRIVACY_CHOICE' THEN RAISE; END IF;
  END;
  -- A user who already calculated before opting in is an enrollment, not a registration.
  PERFORM public.fj_record_calculation('d1000000-0000-4000-8000-000000000003', gen_random_uuid(), repeat('a', 64), 'calculate_numerology', 'v1', current_date);
  PERFORM public.fj_set_privacy('d1000000-0000-4000-8000-000000000003', true, false, '2026-10-v2', now() - interval '1 hour');
  IF EXISTS (SELECT 1 FROM public.funnel_events WHERE user_id = 'd1000000-0000-4000-8000-000000000003' AND event_name = 'registration') THEN
    RAISE EXCEPTION 'user with prior usage entered the signup cohort';
  END IF;
  PERFORM public.fj_set_privacy('d1000000-0000-4000-8000-000000000003', false, false, '2026-10-v2');
END $$;

-- ===== Attribution: self-report, signed link upgrade, never from the MCP client =====
DO $$
DECLARE
  u uuid := 'd1000000-0000-4000-8000-000000000001';
  post uuid := 'd1e00000-0000-4000-8000-000000000001';
  draft uuid := 'd1e00000-0000-4000-8000-000000000002';
BEGIN
  INSERT INTO public.fortune_posts (id, account_key, external_post_id, body, body_sha256, status, published_at)
  VALUES (post, '123', '555', 'public post', repeat('a', 64), 'published', now() - interval '2 days');
  INSERT INTO public.fortune_posts (id, account_key, body, body_sha256) VALUES (draft, '123', 'draft', repeat('b', 64));

  IF NOT public.fj_set_attribution(u, 'chatgpt', 'self_reported') THEN RAISE EXCEPTION 'self-report not recorded'; END IF;
  PERFORM public.fj_record_funnel(u, 'mcp_connected', 'connected:claude', 'claude', 'registered_client');
  IF (SELECT source_channel FROM public.funnel_events WHERE user_id = u AND event_name = 'registration') <> 'chatgpt' THEN
    RAISE EXCEPTION 'MCP client overwrote the acquisition channel';
  END IF;
  -- A later self-report does not overwrite a known channel; a signed link upgrades it.
  IF public.fj_set_attribution(u, 'direct', 'self_reported') THEN RAISE EXCEPTION 'known channel overwritten by self-report'; END IF;
  IF NOT public.fj_set_attribution(u, 'threads', 'signed_link', post) THEN RAISE EXCEPTION 'signed link not applied'; END IF;
  IF (SELECT post_id FROM public.funnel_events WHERE user_id = u AND event_name = 'registration') <> post THEN RAISE EXCEPTION 'post not linked'; END IF;
  BEGIN
    PERFORM public.fj_set_attribution(u, 'threads', 'signed_link', draft);
    RAISE EXCEPTION 'unpublished post accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'ATTRIBUTION_POST_NOT_FOUND' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.fj_set_attribution(u, 'chatgpt', 'signed_link', post);
    RAISE EXCEPTION 'signed link outside Threads accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_ATTRIBUTION' THEN RAISE; END IF;
  END;
  IF public.fj_set_attribution('d1000000-0000-4000-8000-000000000003', 'threads', 'self_reported') THEN
    RAISE EXCEPTION 'attribution recorded without consent';
  END IF;
END $$;

-- ===== Feedback and self-reports: consent required, own readings only, deduplicated =====
DO $$
DECLARE
  u uuid := 'd1000000-0000-4000-8000-000000000001';
  other uuid := 'd1000000-0000-4000-8000-000000000004';
  mine uuid;
  theirs uuid;
BEGIN
  UPDATE public.user_access SET interest_consent_at = now() WHERE user_id = u;
  mine := (public.fj_record_calculation(u, gen_random_uuid(), repeat('a', 64), 'calculate_numerology', 'v1', current_date, 'love', 'unknown', true)->>'readingId')::uuid;
  theirs := (public.fj_record_calculation(other, gen_random_uuid(), repeat('b', 64), 'calculate_numerology', 'v1', current_date)->>'readingId')::uuid;

  IF NOT public.fj_submit_feedback(u, mine, 4::smallint, 'mixed') THEN RAISE EXCEPTION 'feedback refused'; END IF;
  IF NOT public.fj_submit_feedback(u, mine, 5::smallint, 'matched', current_date + 7) THEN RAISE EXCEPTION 'feedback update refused'; END IF;
  IF (SELECT usefulness FROM public.reading_feedback WHERE reading_id = mine) <> 5 OR (SELECT count(*) FROM public.reading_feedback WHERE user_id = u) <> 1 THEN
    RAISE EXCEPTION 'feedback not upserted';
  END IF;
  BEGIN
    PERFORM public.fj_submit_feedback(u, theirs, 4::smallint, 'mixed');
    RAISE EXCEPTION 'feedback on another user reading';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'READING_NOT_FOUND' THEN RAISE; END IF;
  END;
  BEGIN
    INSERT INTO public.reading_feedback (user_id, reading_id, usefulness, match_assessment) VALUES (other, mine, 5, 'matched');
    RAISE EXCEPTION 'composite FK allowed cross-user feedback';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  IF public.fj_submit_feedback('d1000000-0000-4000-8000-000000000003',
       (SELECT id FROM public.user_readings WHERE user_id = 'd1000000-0000-4000-8000-000000000003' LIMIT 1), 3::smallint, 'unclear') THEN
    RAISE EXCEPTION 'feedback without consent';
  END IF;

  IF NOT public.fj_record_funnel(u, 'journal_save_reported', 'report:1', 'unknown', 'unknown', mine) THEN RAISE EXCEPTION 'report refused'; END IF;
  PERFORM public.fj_record_funnel(u, 'journal_save_reported', 'report:1', 'unknown', 'unknown', mine);
  IF (SELECT count(*) FROM public.funnel_events WHERE user_id = u AND dedupe_key = 'report:1') <> 1 THEN RAISE EXCEPTION 'report duplicated'; END IF;
  IF (SELECT observation FROM public.funnel_events WHERE user_id = u AND dedupe_key = 'report:1') <> 'self_reported' THEN
    RAISE EXCEPTION 'self-report labelled as a server observation';
  END IF;
  BEGIN
    PERFORM public.fj_record_funnel(u, 'review_reported', 'report:2', 'unknown', 'unknown', theirs);
    RAISE EXCEPTION 'report on another user reading';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'READING_NOT_FOUND' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.fj_record_funnel(u, 'registration', 'forged', 'threads', 'signed_link');
    RAISE EXCEPTION 'server-only event accepted from the funnel RPC';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_FUNNEL_EVENT' THEN RAISE; END IF;
  END;
  IF public.fj_record_funnel('d1000000-0000-4000-8000-000000000003', 'mcp_connected', 'connected:unknown') THEN
    RAISE EXCEPTION 'event recorded without consent';
  END IF;

  -- Withdrawing interests only clears topics.
  PERFORM public.fj_set_privacy(u, true, false, '2026-10-v2');
  IF EXISTS (SELECT 1 FROM public.user_readings WHERE user_id = u AND topic IS NOT NULL) THEN RAISE EXCEPTION 'topic kept after interest withdrawal'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.reading_feedback WHERE user_id = u) THEN RAISE EXCEPTION 'feedback deleted by interest withdrawal'; END IF;

  -- Withdrawing analytics deletes optional data but keeps the operational ledger (idempotency, quota).
  PERFORM public.fj_set_privacy(u, false, false, '2026-10-v2');
  IF EXISTS (SELECT 1 FROM public.funnel_events WHERE user_id = u) OR EXISTS (SELECT 1 FROM public.reading_feedback WHERE user_id = u) THEN
    RAISE EXCEPTION 'optional data survived withdrawal';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_readings WHERE id = mine) THEN RAISE EXCEPTION 'operational ledger deleted on withdrawal'; END IF;
  IF (SELECT analytics_consent_at IS NULL AND interest_consent_at IS NULL AND analytics_revoked_at IS NOT NULL AND consent_version = '2026-10-v2'
      FROM public.user_access WHERE user_id = u) IS NOT TRUE THEN
    RAISE EXCEPTION 'withdrawal state not recorded';
  END IF;
  IF public.fj_submit_feedback(u, mine, 4::smallint, 'mixed') THEN RAISE EXCEPTION 'feedback accepted after withdrawal'; END IF;
  -- Re-consent keeps the earlier withdrawal timestamp as history and starts a new consent time.
  PERFORM public.fj_set_privacy(u, true, false, '2026-11-v3');
  IF (SELECT analytics_consent_at FROM public.user_access WHERE user_id = u) IS NULL THEN RAISE EXCEPTION 're-consent not recorded'; END IF;
END $$;

RESET ROLE;
ROLLBACK;
