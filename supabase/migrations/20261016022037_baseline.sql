-- Fortune Journal — baseline schema (v0.3.0, pre-release).
--
-- This single migration replaces the v0.1 + v0.2 history (initial + 5 additive + 3 forward fixes). That
-- history never reached a remote database (read-only check 2026-10-16: no Fortune Journal Supabase project
-- exists) and remains in Git before commit "feat(db): replace migration history with a single baseline".
--
-- Readers: the generated result is supabase/schema.sql and docs/generated/DB_CATALOG.md (npm run db:schema).
-- The design rationale per table/function is docs/DATABASE.md. Once this file is applied to any remote
-- database, record it in supabase/applied-migrations.json and never edit it again; add a new migration.
--
-- Conventions: every public table has RLS and no anon/authenticated privileges (customers reach data only
-- through the app, which uses service_role after verifying Supabase Auth). Every function is SECURITY INVOKER
-- with search_path = '' and is executable by service_role only. Customer journal text, birth data and
-- free-form feedback are never stored.
BEGIN;

-- =====================================================================================================
-- 1. Accounts, entitlement and the usage ledger
-- =====================================================================================================

CREATE TABLE public.user_access (
  user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  -- The trial starts at the first calculation (fj_record_calculation), never at sign-in or consent.
  trial_started_at timestamptz,
  trial_ends_at timestamptz,
  first_calculated_at timestamptz,
  suspended_at timestamptz,
  -- Optional analytics consent; interest (topic) consent requires analytics consent.
  analytics_consent_at timestamptz,
  interest_consent_at timestamptz,
  consent_version text CHECK (consent_version ~ '^[0-9]{4}-[0-9]{2}-v[0-9]+$'),
  consent_updated_at timestamptz,
  analytics_revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT trial_window CHECK (
    (trial_started_at IS NULL) = (trial_ends_at IS NULL) AND (trial_ends_at IS NULL OR trial_ends_at >= trial_started_at)
  ),
  CONSTRAINT interest_requires_analytics CHECK (interest_consent_at IS NULL OR analytics_consent_at IS NOT NULL)
);
COMMENT ON TABLE public.user_access IS 'One row per user: trial window, suspension and optional-consent state. No birth or journal data.';

CREATE TABLE public.subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- NULL after account deletion: the binding stays (de-identified) so later refunds and chargebacks still reach
  -- the ledger. A NULL user never matches fj_access_status, so it can grant nothing.
  user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  provider text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  provider_customer_id text,
  provider_subscription_id text NOT NULL,
  status text NOT NULL CHECK (status IN ('incomplete', 'trialing', 'active', 'past_due', 'canceled', 'unpaid', 'expired')),
  current_period_end timestamptz,
  cancel_at_period_end boolean NOT NULL DEFAULT false,
  -- Set only when fj_apply_billing applied a signature-verified provider snapshot. NULL never grants Premium.
  verified_at timestamptz,
  provider_updated_at timestamptz,
  plan_key text CHECK (plan_key ~ '^[A-Za-z0-9_.:-]{1,80}$'),
  amount_minor bigint CHECK (amount_minor >= 0),
  currency text CHECK (currency ~ '^[A-Z]{3}$'),
  currency_exponent smallint CHECK (currency_exponent BETWEEN 0 AND 6),
  interval_months smallint CHECK (interval_months BETWEEN 1 AND 12),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_subscription_id),
  CONSTRAINT deleted_account_is_deidentified CHECK (user_id IS NOT NULL OR provider_customer_id IS NULL)
);
CREATE INDEX subscriptions_user ON public.subscriptions (user_id);
COMMENT ON TABLE public.subscriptions IS 'Server-created binding to a provider subscription plus its latest verified state. Kept de-identified after account deletion.';

-- Account deletion sets user_id NULL (FK action); the provider customer id goes with it.
CREATE FUNCTION public.fj_deidentify_subscription() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF NEW.user_id IS NULL THEN
    NEW.provider_customer_id := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER fj_subscription_deidentify BEFORE UPDATE OF user_id ON public.subscriptions
FOR EACH ROW EXECUTE FUNCTION public.fj_deidentify_subscription();

-- Each row is one consumed usage unit and the idempotency record of one request. Usage limits are counted
-- from these rows (no separate counter table to keep in sync). Result text and inputs are never stored.
CREATE TABLE public.user_readings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  request_id uuid NOT NULL,
  -- HMAC(REQUEST_HMAC_KEY) of user, request and the exact input: pseudonymous, not anonymous.
  request_fingerprint text NOT NULL CHECK (request_fingerprint ~ '^[a-f0-9]{64}$'),
  feature_key text NOT NULL CHECK (feature_key IN ('calculate_numerology', 'draw_tarot')),
  algorithm_version text NOT NULL CHECK (algorithm_version ~ '^[A-Za-z0-9_.:-]{1,80}$'),
  target_date date NOT NULL,
  -- Only with analytics AND interest consent.
  topic text CHECK (topic IN ('love', 'work', 'money', 'general')),
  tier_at_use text NOT NULL CHECK (tier_at_use IN ('free', 'trial', 'premium')),
  remaining_after integer NOT NULL CHECK (remaining_after >= 0),
  calculated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, request_id),
  -- Target of the composite foreign keys that stop one user's feedback/events pointing at another's reading.
  UNIQUE (user_id, id)
);
-- Usage counting (fj_record_calculation) and D7 cohorts (fj_cohort_report) both filter by user and time.
CREATE INDEX user_readings_user_time ON public.user_readings (user_id, calculated_at);
COMMENT ON TABLE public.user_readings IS '90-day operational ledger: one row per consumed usage unit / idempotent request. No reading text.';

CREATE FUNCTION public.fj_access_status(p_user_id uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_access public.user_access%ROWTYPE;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_USER';
  END IF;
  SELECT * INTO v_access FROM public.user_access WHERE user_id = p_user_id;
  IF v_access.suspended_at IS NOT NULL THEN
    RETURN 'suspended';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.subscriptions s
    WHERE s.user_id = p_user_id AND s.verified_at IS NOT NULL
      AND s.status IN ('active', 'trialing') AND s.current_period_end > now()
  ) THEN
    RETURN 'premium';
  END IF;
  IF v_access.trial_ends_at > now() THEN
    RETURN 'trial';
  END IF;
  RETURN 'free';
END $$;
COMMENT ON FUNCTION public.fj_access_status(uuid) IS 'The only tier rule: suspended > verified current subscription > trial > free.';

-- One transaction per MCP calculation: lock the user, start the trial, resolve the tier, replay or charge,
-- write the ledger row. Returns {ok, reason} or {ok, readingId, tier, remainingAtCompletion, replayed}.
CREATE FUNCTION public.fj_record_calculation(
  p_user_id uuid,
  p_request_id uuid,
  p_fingerprint text,
  p_feature text,
  p_algorithm text,
  p_target_date date,
  p_topic text DEFAULT NULL,
  p_client text DEFAULT 'unknown',
  p_collect_analytics boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_now timestamptz := now();
  v_access public.user_access%ROWTYPE;
  v_previous public.user_readings%ROWTYPE;
  v_tier text;
  v_limit integer;
  v_used integer;
  v_reading_id uuid;
BEGIN
  IF p_user_id IS NULL OR p_request_id IS NULL OR p_target_date IS NULL
     OR p_fingerprint IS NULL OR p_fingerprint !~ '^[a-f0-9]{64}$'
     OR p_feature IS NULL OR p_feature NOT IN ('calculate_numerology', 'draw_tarot')
     OR p_algorithm IS NULL OR p_algorithm !~ '^[A-Za-z0-9_.:-]{1,80}$'
     OR (p_topic IS NOT NULL AND p_topic NOT IN ('love', 'work', 'money', 'general'))
     OR p_client IS NULL OR p_client NOT IN ('chatgpt', 'claude', 'unknown') THEN
    RAISE EXCEPTION 'INVALID_CALCULATION_METADATA';
  END IF;

  -- Serialize every calculation of this user, so all checks below read committed state (READ COMMITTED
  -- takes a fresh snapshot per statement) and concurrent requests cannot exceed a limit or double-charge.
  INSERT INTO public.user_access (user_id) VALUES (p_user_id) ON CONFLICT DO NOTHING;
  SELECT * INTO v_access FROM public.user_access WHERE user_id = p_user_id FOR UPDATE;
  IF v_access.suspended_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ACCOUNT_SUSPENDED');
  END IF;

  -- Product policy: the 14-day trial starts at the first calculation.
  IF v_access.trial_started_at IS NULL THEN
    UPDATE public.user_access SET trial_started_at = v_now, trial_ends_at = v_now + interval '14 days'
    WHERE user_id = p_user_id
    RETURNING * INTO v_access;
  END IF;
  v_tier := public.fj_access_status(p_user_id);

  -- An identical retry replays the delivered result without new usage, even after the trial ended.
  -- Tarot is keyed to its drawId, not to a calendar date; numerology replays need the same target date.
  SELECT * INTO v_previous FROM public.user_readings WHERE user_id = p_user_id AND request_id = p_request_id;
  IF FOUND THEN
    IF v_previous.request_fingerprint <> p_fingerprint OR v_previous.feature_key <> p_feature
       OR v_previous.algorithm_version <> p_algorithm
       OR (p_feature <> 'draw_tarot' AND v_previous.target_date <> p_target_date) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'IDEMPOTENCY_CONFLICT');
    END IF;
    RETURN jsonb_build_object('ok', true, 'readingId', v_previous.id, 'tier', v_tier,
      'remainingAtCompletion', v_previous.remaining_after, 'replayed', true);
  END IF;

  -- Product policy (the only copy): Free = 3 numerology per ISO week (no tarot);
  -- Trial = 100 and Premium = 200 per feature per UTC day. Each tier counts only its own usage.
  v_limit := CASE
    WHEN v_tier = 'premium' THEN 200
    WHEN v_tier = 'trial' THEN 100
    WHEN p_feature = 'calculate_numerology' THEN 3
  END;
  IF v_limit IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'FEATURE_NOT_INCLUDED');
  END IF;
  SELECT count(*) INTO v_used FROM public.user_readings
  WHERE user_id = p_user_id AND feature_key = p_feature AND tier_at_use = v_tier
    AND calculated_at >= date_trunc(CASE WHEN v_tier = 'free' THEN 'week' ELSE 'day' END, v_now, 'UTC');
  IF v_used >= v_limit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'USAGE_LIMIT_REACHED');
  END IF;

  INSERT INTO public.user_readings (
    user_id, request_id, request_fingerprint, feature_key, algorithm_version, target_date, topic,
    tier_at_use, remaining_after, calculated_at
  ) VALUES (
    p_user_id, p_request_id, p_fingerprint, p_feature, p_algorithm, p_target_date,
    CASE WHEN p_collect_analytics AND v_access.analytics_consent_at IS NOT NULL
      AND v_access.interest_consent_at IS NOT NULL THEN p_topic END,
    v_tier, v_limit - v_used - 1, v_now
  ) RETURNING id INTO v_reading_id;

  UPDATE public.user_access SET first_calculated_at = v_now
  WHERE user_id = p_user_id AND first_calculated_at IS NULL;

  IF p_collect_analytics AND v_access.analytics_consent_at IS NOT NULL THEN
    -- The MCP client is the platform used, not evidence of how the user found the service.
    INSERT INTO public.funnel_events (
      user_id, event_name, dedupe_key, occurred_at, observation, reading_id, source_channel, source_evidence
    ) VALUES (
      p_user_id, 'reading_completed', 'reading:' || v_reading_id, v_now, 'server', v_reading_id, p_client,
      CASE WHEN p_client = 'unknown' THEN 'unknown' ELSE 'registered_client' END
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'readingId', v_reading_id, 'tier', v_tier,
    'remainingAtCompletion', v_limit - v_used - 1, 'replayed', false);
END $$;

-- =====================================================================================================
-- 1b. Auth: audience of MCP access tokens (Supabase Custom Access Token Hook)
-- =====================================================================================================

-- Enable in Supabase Auth -> Hooks -> Customize Access Token (pg-functions://postgres/public/fj_access_token_hook).
-- Supabase issues aud='authenticated' for every token and ignores the RFC 8707 `resource` parameter (the hook
-- input has no resource either). Every token issued to an OAuth client carries client_id, so this replaces its
-- aud with the MCP audience: /api/mcp requires exactly that audience and the account web APIs refuse it.
-- Browser-session tokens are returned unchanged. Pure function of its input (no table access); if it fails,
-- Supabase issues no token (fail closed). Keep the value equal to MCP_TOKEN_AUDIENCE in src/domain/oauth-claims.ts.
CREATE FUNCTION public.fj_access_token_hook(event jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_claims jsonb := event->'claims';
BEGIN
  IF jsonb_typeof(v_claims->'client_id') = 'string' AND v_claims->>'client_id' <> '' THEN
    v_claims := jsonb_set(v_claims, '{aud}', '"urn:fortune-journal:mcp"'::jsonb);
  END IF;
  RETURN jsonb_build_object('claims', v_claims);
END $$;

-- =====================================================================================================
-- 2. Optional analytics (global switch AND explicit consent)
-- =====================================================================================================

-- Operator-owned public marketing posts; referenced by attribution, so defined before funnel_events.
CREATE TABLE public.fortune_posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_key text NOT NULL CHECK (account_key ~ '^[A-Za-z0-9_:-]{1,100}$'),
  external_post_id text CHECK (external_post_id ~ '^[0-9]{1,80}$'),
  container_id text CHECK (container_id ~ '^[0-9]{1,80}$'),
  body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 10000),
  body_sha256 text NOT NULL CHECK (body_sha256 ~ '^[a-f0-9]{64}$'),
  topic text NOT NULL DEFAULT 'unclassified' CHECK (topic IN ('love', 'work', 'money', 'general', 'unclassified')),
  method text NOT NULL DEFAULT 'unclassified' CHECK (method IN ('tarot', 'numerology', 'mixed', 'unclassified')),
  tone text NOT NULL DEFAULT 'unclassified' CHECK (tone IN ('empathetic', 'assertive', 'question', 'unclassified')),
  zodiac text CHECK (zodiac IN ('aries', 'taurus', 'gemini', 'cancer', 'leo', 'virgo', 'libra', 'scorpio',
    'sagittarius', 'capricorn', 'aquarius', 'pisces')),
  language text NOT NULL DEFAULT 'und' CHECK (language ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$'),
  hook_text text CHECK (char_length(hook_text) <= 240),
  cta_key text NOT NULL DEFAULT 'none' CHECK (cta_key IN ('none', 'reflect', 'save', 'reply', 'visit_profile')),
  prompt_version text CHECK (prompt_version ~ '^[A-Za-z0-9_.:-]{1,80}$'),
  experiment_id text CHECK (experiment_id ~ '^[A-Za-z0-9_.:-]{1,80}$'),
  variant_key text CHECK (variant_key ~ '^[A-Za-z0-9_.:-]{1,80}$'),
  -- publish_unknown is terminal for automation: a person reconciles it, nothing re-posts it.
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'approved', 'publishing', 'publish_unknown', 'published')),
  scheduled_at timestamptz,
  published_at timestamptz,
  approved_at timestamptz,
  approved_body_sha256 text CHECK (approved_body_sha256 ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT published_has_external_id CHECK (status <> 'published' OR (external_post_id IS NOT NULL AND published_at IS NOT NULL)),
  CONSTRAINT approval_matches_body CHECK (
    status NOT IN ('approved', 'publishing') OR (approved_at IS NOT NULL AND approved_body_sha256 = body_sha256)
  ),
  UNIQUE (account_key, external_post_id)
);
COMMENT ON TABLE public.fortune_posts IS 'Operator-owned public marketing posts only, never customer content.';

CREATE TABLE public.funnel_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  event_name text NOT NULL CHECK (event_name IN ('registration', 'analytics_enrolled', 'mcp_connected', 'reading_completed',
    'journal_save_reported', 'life_log_reported', 'review_reported')),
  dedupe_key text NOT NULL CHECK (char_length(dedupe_key) BETWEEN 1 AND 160),
  occurred_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  source_channel text NOT NULL DEFAULT 'unknown' CHECK (source_channel IN ('threads', 'chatgpt', 'claude', 'direct', 'unknown')),
  source_evidence text NOT NULL DEFAULT 'unknown' CHECK (source_evidence IN ('signed_link', 'self_reported', 'registered_client', 'unknown')),
  observation text NOT NULL CHECK (observation IN ('server', 'self_reported')),
  post_id uuid REFERENCES public.fortune_posts (id) ON DELETE SET NULL,
  reading_id uuid,
  UNIQUE (user_id, dedupe_key),
  FOREIGN KEY (user_id, reading_id) REFERENCES public.user_readings (user_id, id) ON DELETE CASCADE,
  -- User reports are self-reported; everything else is observed by the server.
  CONSTRAINT observation_matches_event CHECK (
    (event_name IN ('journal_save_reported', 'life_log_reported', 'review_reported')) = (observation = 'self_reported')
  )
);
CREATE INDEX funnel_events_cohort ON public.funnel_events (event_name, occurred_at, user_id);
CREATE INDEX funnel_events_post ON public.funnel_events (post_id) WHERE post_id IS NOT NULL;
CREATE INDEX funnel_events_reading ON public.funnel_events (user_id, reading_id) WHERE reading_id IS NOT NULL;
COMMENT ON TABLE public.funnel_events IS 'Optional, consented product events. Deleted on withdrawal; no anonymous tracking IDs.';

CREATE TABLE public.reading_feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reading_id uuid NOT NULL,
  usefulness smallint NOT NULL CHECK (usefulness BETWEEN 1 AND 5),
  -- Subjective, fixed labels only: never free text, never evidence of predictive accuracy.
  match_assessment text NOT NULL CHECK (match_assessment IN ('not_assessed', 'matched', 'mixed', 'not_matched', 'unclear')),
  followup_date date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, reading_id),
  FOREIGN KEY (user_id, reading_id) REFERENCES public.user_readings (user_id, id) ON DELETE CASCADE
);
COMMENT ON TABLE public.reading_feedback IS 'Optional fixed-label feedback for one of the user''s own readings.';

-- Sets optional consent. Withdrawal deletes optional data but keeps the operational ledger.
-- p_registered_at comes from the verified Supabase Auth user (service_role cannot read auth.users).
CREATE FUNCTION public.fj_set_privacy(
  p_user_id uuid,
  p_analytics boolean,
  p_interests boolean,
  p_version text,
  p_registered_at timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_access public.user_access%ROWTYPE;
BEGIN
  IF p_user_id IS NULL OR p_analytics IS NULL OR p_interests IS NULL
     OR p_version IS NULL OR p_version !~ '^[0-9]{4}-[0-9]{2}-v[0-9]+$'
     OR (p_interests AND NOT p_analytics) OR p_registered_at > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'INVALID_PRIVACY_CHOICE';
  END IF;
  INSERT INTO public.user_access (user_id) VALUES (p_user_id) ON CONFLICT DO NOTHING;
  SELECT * INTO v_access FROM public.user_access WHERE user_id = p_user_id FOR UPDATE;

  IF NOT p_analytics THEN
    DELETE FROM public.funnel_events WHERE user_id = p_user_id;
    DELETE FROM public.reading_feedback WHERE user_id = p_user_id;
  ELSIF v_access.analytics_consent_at IS NULL THEN
    INSERT INTO public.funnel_events (user_id, event_name, dedupe_key, occurred_at, observation)
    VALUES (p_user_id, 'analytics_enrolled', 'enrollment', now(), 'server')
    ON CONFLICT DO NOTHING;
    -- Only a near-signup opt-in without prior usage enters the signup cohort; older accounts are
    -- enrollments, never retroactively fabricated registrations.
    IF p_registered_at >= now() - interval '24 hours' AND v_access.first_calculated_at IS NULL THEN
      INSERT INTO public.funnel_events (user_id, event_name, dedupe_key, occurred_at, observation)
      VALUES (p_user_id, 'registration', 'registration', p_registered_at, 'server')
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;
  IF NOT p_interests THEN
    UPDATE public.user_readings SET topic = NULL WHERE user_id = p_user_id AND topic IS NOT NULL;
  END IF;

  UPDATE public.user_access SET
    analytics_consent_at = CASE WHEN p_analytics THEN coalesce(v_access.analytics_consent_at, now()) END,
    interest_consent_at = CASE WHEN p_interests THEN coalesce(v_access.interest_consent_at, now()) END,
    consent_version = p_version,
    consent_updated_at = now(),
    analytics_revoked_at = CASE WHEN NOT p_analytics THEN now() ELSE v_access.analytics_revoked_at END
  WHERE user_id = p_user_id;
  RETURN jsonb_build_object('analytics', p_analytics, 'interests', p_interests, 'version', p_version);
END $$;

-- Records how a consenting user says (or a signed link shows) they found the service. Only fills an unknown
-- channel or upgrades to a signed link; returns false when nothing changed or there is no consent.
CREATE FUNCTION public.fj_set_attribution(p_user_id uuid, p_channel text, p_evidence text, p_post_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_access public.user_access%ROWTYPE;
BEGIN
  IF p_user_id IS NULL OR p_channel IS NULL OR p_channel NOT IN ('threads', 'chatgpt', 'claude', 'direct', 'unknown')
     OR p_evidence IS NULL OR p_evidence NOT IN ('signed_link', 'self_reported', 'unknown')
     OR (p_evidence = 'signed_link' AND (p_post_id IS NULL OR p_channel <> 'threads')) THEN
    RAISE EXCEPTION 'INVALID_ATTRIBUTION';
  END IF;
  SELECT * INTO v_access FROM public.user_access WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND OR v_access.analytics_consent_at IS NULL THEN
    RETURN false;
  END IF;
  IF p_post_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.fortune_posts WHERE id = p_post_id AND status = 'published') THEN
    RAISE EXCEPTION 'ATTRIBUTION_POST_NOT_FOUND';
  END IF;
  UPDATE public.funnel_events SET source_channel = p_channel, source_evidence = p_evidence, post_id = p_post_id
  WHERE user_id = p_user_id AND event_name = 'registration'
    AND (source_channel = 'unknown' OR (p_evidence = 'signed_link' AND source_evidence <> 'signed_link'));
  RETURN FOUND;
END $$;

-- Consented connection telemetry and explicit user self-reports (never verified against Google Sheets).
CREATE FUNCTION public.fj_record_funnel(
  p_user_id uuid,
  p_event text,
  p_dedupe_key text,
  p_channel text DEFAULT 'unknown',
  p_evidence text DEFAULT 'unknown',
  p_reading_id uuid DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_access public.user_access%ROWTYPE;
BEGIN
  IF p_user_id IS NULL OR p_dedupe_key IS NULL OR char_length(p_dedupe_key) NOT BETWEEN 1 AND 160
     OR p_event IS NULL OR p_event NOT IN ('mcp_connected', 'journal_save_reported', 'life_log_reported', 'review_reported')
     OR p_channel IS NULL OR p_channel NOT IN ('threads', 'chatgpt', 'claude', 'direct', 'unknown')
     OR p_evidence IS NULL OR p_evidence NOT IN ('signed_link', 'self_reported', 'registered_client', 'unknown') THEN
    RAISE EXCEPTION 'INVALID_FUNNEL_EVENT';
  END IF;
  -- Same lock as fj_set_privacy, so an event cannot slip in while a withdrawal deletes events.
  SELECT * INTO v_access FROM public.user_access WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND OR v_access.analytics_consent_at IS NULL OR v_access.suspended_at IS NOT NULL THEN
    RETURN false;
  END IF;
  IF p_reading_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_readings WHERE id = p_reading_id AND user_id = p_user_id) THEN
    RAISE EXCEPTION 'READING_NOT_FOUND';
  END IF;
  INSERT INTO public.funnel_events (user_id, event_name, dedupe_key, occurred_at, observation, source_channel, source_evidence, reading_id)
  VALUES (p_user_id, p_event, p_dedupe_key, now(), CASE WHEN p_event = 'mcp_connected' THEN 'server' ELSE 'self_reported' END,
    p_channel, p_evidence, p_reading_id)
  ON CONFLICT (user_id, dedupe_key) DO NOTHING;
  RETURN true;
END $$;

CREATE FUNCTION public.fj_submit_feedback(
  p_user_id uuid,
  p_reading_id uuid,
  p_usefulness smallint,
  p_match text,
  p_followup date DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_access public.user_access%ROWTYPE;
BEGIN
  IF p_user_id IS NULL OR p_reading_id IS NULL OR p_usefulness IS NULL OR p_usefulness NOT BETWEEN 1 AND 5
     OR p_match IS NULL OR p_match NOT IN ('not_assessed', 'matched', 'mixed', 'not_matched', 'unclear') THEN
    RAISE EXCEPTION 'INVALID_FEEDBACK';
  END IF;
  SELECT * INTO v_access FROM public.user_access WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND OR v_access.analytics_consent_at IS NULL OR v_access.suspended_at IS NOT NULL THEN
    RETURN false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_readings WHERE id = p_reading_id AND user_id = p_user_id) THEN
    RAISE EXCEPTION 'READING_NOT_FOUND';
  END IF;
  INSERT INTO public.reading_feedback (user_id, reading_id, usefulness, match_assessment, followup_date)
  VALUES (p_user_id, p_reading_id, p_usefulness, p_match, p_followup)
  ON CONFLICT (user_id, reading_id) DO UPDATE SET
    usefulness = excluded.usefulness, match_assessment = excluded.match_assessment,
    followup_date = excluded.followup_date, updated_at = now();
  RETURN true;
END $$;

-- =====================================================================================================
-- 3. Billing ledger (no provider is connected yet: /api/billing/webhook answers 501)
-- =====================================================================================================

-- One row per accepted, signature-verified provider event (only fj_apply_billing writes here).
-- No raw webhook payloads or card data.
CREATE TABLE public.billing_events (
  provider text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  event_id text NOT NULL CHECK (char_length(event_id) BETWEEN 1 AND 200),
  user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  provider_subscription_id text NOT NULL,
  event_type text NOT NULL CHECK (event_type IN ('subscription_updated', 'payment_succeeded', 'payment_failed',
    'subscription_canceled', 'refund_succeeded', 'chargeback')),
  occurred_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  -- Provider-independent identity of one money movement: two notifications for one charge share it.
  economic_key text CHECK (char_length(economic_key) BETWEEN 1 AND 160),
  original_payment_key text,
  amount_minor bigint CHECK (amount_minor >= 0),
  currency text CHECK (currency ~ '^[A-Z]{3}$'),
  currency_exponent smallint CHECK (currency_exponent BETWEEN 0 AND 6),
  billing_reason text NOT NULL DEFAULT 'not_applicable' CHECK (billing_reason IN ('initial', 'recurring', 'one_time', 'not_applicable')),
  plan_key text CHECK (plan_key ~ '^[A-Za-z0-9_.:-]{1,80}$'),
  -- What the event's subscription snapshot did to entitlement state.
  state_disposition text NOT NULL CHECK (state_disposition IN ('none', 'applied', 'older_or_identical', 'needs_reconciliation')),
  PRIMARY KEY (provider, event_id),
  CONSTRAINT cash_fields CHECK (
    CASE WHEN event_type IN ('payment_succeeded', 'refund_succeeded', 'chargeback')
      THEN economic_key IS NOT NULL AND amount_minor IS NOT NULL AND currency IS NOT NULL AND currency_exponent IS NOT NULL
      ELSE economic_key IS NULL AND amount_minor IS NULL AND currency IS NULL AND currency_exponent IS NULL
    END
  )
);
CREATE UNIQUE INDEX billing_events_economic_key ON public.billing_events (provider, economic_key) WHERE economic_key IS NOT NULL;
CREATE INDEX billing_events_user ON public.billing_events (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX billing_events_cash_time ON public.billing_events (occurred_at) WHERE economic_key IS NOT NULL;
COMMENT ON TABLE public.billing_events IS 'Verified, normalized provider events. Cash collections are not MRR. Not auto-purged.';

-- The caller MUST have verified the provider signature and normalized the event. The user is never taken from
-- provider metadata: a server-created subscriptions binding is required (it survives account deletion,
-- de-identified). Money alone never grants Premium; only a newer subscription snapshot changes entitlement.
--   * Same event id again: identical = no-op, different = BILLING_IDEMPOTENCY_CONFLICT.
--   * Another event id for the same money movement (economic_key): cash is not counted again, but the snapshot it
--     carries is still applied when newer (a later notice often carries the newer state).
--   * Same provider timestamp, different content (status, period, cancellation, plan, price, interval): flagged
--     needs_reconciliation; if the two disagree on entitlement, verified_at is cleared (fail closed) until a newer
--     snapshot or one the adapter fetched from the provider API ("reconciled": true) is applied.
--   * Events on the binding of a deleted account that would keep it alive are flagged for a person.
-- Concurrent deliveries for one subscription serialize on its row lock; the unique keys stop double counting.
CREATE FUNCTION public.fj_apply_billing(p_provider text, p_event_id text, p_event jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_kind text := p_event->>'event_type';
  v_occurred_at timestamptz := (p_event->>'occurred_at')::timestamptz;
  v_economic_key text := p_event->>'economic_key';
  v_amount bigint := (p_event->>'amount_minor')::bigint;
  v_currency text := p_event->>'currency';
  v_exponent smallint := (p_event->>'currency_exponent')::smallint;
  v_snapshot jsonb := nullif(p_event->'subscription', 'null'::jsonb);
  v_reconciled boolean := coalesce((p_event->>'reconciled')::boolean, false);
  v_snapshot_at timestamptz;
  v_is_cash boolean;
  v_cash_duplicate boolean := false;
  v_disposition text := 'none';
  v_subscription public.subscriptions%ROWTYPE;
  v_previous public.billing_events%ROWTYPE;
  v_new public.subscriptions%ROWTYPE;
BEGIN
  IF p_provider IS NULL OR p_provider !~ '^[a-z][a-z0-9_]{1,30}$'
     OR p_event_id IS NULL OR char_length(p_event_id) NOT BETWEEN 1 AND 200
     OR v_kind IS NULL OR v_kind NOT IN ('subscription_updated', 'payment_succeeded', 'payment_failed',
       'subscription_canceled', 'refund_succeeded', 'chargeback')
     OR v_occurred_at IS NULL OR v_occurred_at > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'INVALID_BILLING_EVENT';
  END IF;
  SELECT * INTO v_subscription FROM public.subscriptions
  WHERE provider = p_provider AND provider_subscription_id = p_event->>'provider_subscription_id'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'BILLING_BINDING_REQUIRED';
  END IF;

  v_is_cash := v_kind IN ('payment_succeeded', 'refund_succeeded', 'chargeback');
  IF v_is_cash AND (v_economic_key IS NULL OR v_amount IS NULL OR v_currency IS NULL OR v_exponent IS NULL) THEN
    RAISE EXCEPTION 'INVALID_FINANCIAL_FIELDS';
  END IF;
  IF NOT v_is_cash AND (v_economic_key IS NOT NULL OR v_amount IS NOT NULL) THEN
    RAISE EXCEPTION 'NON_FINANCIAL_AMOUNT';
  END IF;

  -- Redelivery of the same event: it was fully processed the first time.
  SELECT * INTO v_previous FROM public.billing_events WHERE provider = p_provider AND event_id = p_event_id;
  IF FOUND THEN
    IF v_previous.event_type IS DISTINCT FROM v_kind OR v_previous.economic_key IS DISTINCT FROM v_economic_key
       OR v_previous.amount_minor IS DISTINCT FROM v_amount OR v_previous.currency IS DISTINCT FROM v_currency
       OR v_previous.currency_exponent IS DISTINCT FROM v_exponent
       OR v_previous.provider_subscription_id IS DISTINCT FROM v_subscription.provider_subscription_id THEN
      RAISE EXCEPTION 'BILLING_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN jsonb_build_object('duplicate', true, 'stateApplied', false);
  END IF;
  -- Another notification of an already recorded money movement: same facts required, cash not counted again.
  IF v_is_cash THEN
    SELECT * INTO v_previous FROM public.billing_events WHERE provider = p_provider AND economic_key = v_economic_key;
    IF FOUND THEN
      IF v_previous.event_type IS DISTINCT FROM v_kind OR v_previous.amount_minor IS DISTINCT FROM v_amount
         OR v_previous.currency IS DISTINCT FROM v_currency OR v_previous.currency_exponent IS DISTINCT FROM v_exponent
         OR v_previous.provider_subscription_id IS DISTINCT FROM v_subscription.provider_subscription_id THEN
        RAISE EXCEPTION 'BILLING_IDEMPOTENCY_CONFLICT';
      END IF;
      v_cash_duplicate := true;
    END IF;
  END IF;

  IF v_snapshot IS NOT NULL THEN
    v_snapshot_at := (v_snapshot->>'provider_updated_at')::timestamptz;
    IF v_snapshot_at IS NULL OR v_snapshot_at > now() + interval '5 minutes' OR v_snapshot->>'status' IS NULL
       OR v_snapshot->>'status' NOT IN ('incomplete', 'trialing', 'active', 'past_due', 'canceled', 'unpaid', 'expired') THEN
      RAISE EXCEPTION 'INVALID_SUBSCRIPTION_SNAPSHOT';
    END IF;
    v_new := v_subscription;
    v_new.status := v_snapshot->>'status';
    v_new.current_period_end := (v_snapshot->>'current_period_end')::timestamptz;
    v_new.cancel_at_period_end := coalesce((v_snapshot->>'cancel_at_period_end')::boolean, false);
    v_new.plan_key := v_snapshot->>'plan_key';
    v_new.amount_minor := (v_snapshot->>'amount_minor')::bigint;
    v_new.currency := v_snapshot->>'currency';
    v_new.currency_exponent := (v_snapshot->>'currency_exponent')::smallint;
    v_new.interval_months := (v_snapshot->>'interval_months')::smallint;

    IF v_subscription.provider_updated_at IS NULL OR v_snapshot_at > v_subscription.provider_updated_at
       OR (v_reconciled AND v_snapshot_at >= v_subscription.provider_updated_at) THEN
      UPDATE public.subscriptions SET
        status = v_new.status, current_period_end = v_new.current_period_end,
        cancel_at_period_end = v_new.cancel_at_period_end, verified_at = now(), provider_updated_at = v_snapshot_at,
        plan_key = v_new.plan_key, amount_minor = v_new.amount_minor, currency = v_new.currency,
        currency_exponent = v_new.currency_exponent, interval_months = v_new.interval_months, updated_at = now()
      WHERE id = v_subscription.id;
      v_disposition := 'applied';
    ELSIF v_snapshot_at = v_subscription.provider_updated_at
       AND (v_new.status, v_new.current_period_end, v_new.cancel_at_period_end, v_new.plan_key, v_new.amount_minor,
            v_new.currency, v_new.currency_exponent, v_new.interval_months)
           IS DISTINCT FROM
           (v_subscription.status, v_subscription.current_period_end, v_subscription.cancel_at_period_end,
            v_subscription.plan_key, v_subscription.amount_minor, v_subscription.currency,
            v_subscription.currency_exponent, v_subscription.interval_months) THEN
      -- The provider gave two different states for the same instant; which is newer is unknowable here.
      v_disposition := 'needs_reconciliation';
      IF (v_new.status IN ('active', 'trialing') AND coalesce(v_new.current_period_end > now(), false))
         IS DISTINCT FROM
         (v_subscription.status IN ('active', 'trialing') AND coalesce(v_subscription.current_period_end > now(), false)) THEN
        UPDATE public.subscriptions SET verified_at = NULL, updated_at = now() WHERE id = v_subscription.id;
      END IF;
    ELSE
      v_disposition := 'older_or_identical';
    END IF;
    IF v_subscription.user_id IS NULL AND v_new.status IN ('incomplete', 'trialing', 'active', 'past_due', 'unpaid') THEN
      v_disposition := 'needs_reconciliation';
    END IF;
  END IF;

  IF v_cash_duplicate THEN
    RETURN jsonb_build_object('duplicate', true, 'stateApplied', v_disposition = 'applied', 'stateDisposition', v_disposition);
  END IF;
  INSERT INTO public.billing_events (
    provider, event_id, user_id, provider_subscription_id, event_type, occurred_at, economic_key, original_payment_key,
    amount_minor, currency, currency_exponent, billing_reason, plan_key, state_disposition
  ) VALUES (
    p_provider, p_event_id, v_subscription.user_id, v_subscription.provider_subscription_id, v_kind, v_occurred_at,
    v_economic_key, p_event->>'original_payment_key', v_amount, v_currency, v_exponent,
    coalesce(p_event->>'billing_reason', 'not_applicable'), p_event->>'plan_key', v_disposition
  );
  RETURN jsonb_build_object('duplicate', false, 'stateApplied', v_disposition = 'applied', 'stateDisposition', v_disposition);
END $$;

CREATE VIEW public.fj_cash_events WITH (security_invoker = true) AS
SELECT provider, event_id, user_id, provider_subscription_id, economic_key, occurred_at, event_type,
  currency, currency_exponent, billing_reason,
  CASE WHEN event_type = 'payment_succeeded' THEN amount_minor ELSE -amount_minor END AS signed_amount_minor
FROM public.billing_events
WHERE event_type IN ('payment_succeeded', 'refund_succeeded', 'chargeback');

CREATE VIEW public.fj_current_mrr WITH (security_invoker = true) AS
SELECT currency, currency_exponent, count(*) AS subscriptions,
  sum(amount_minor::numeric / power(10::numeric, currency_exponent) / interval_months) AS mrr
FROM public.subscriptions
WHERE verified_at IS NOT NULL AND status = 'active' AND current_period_end > now()
  AND amount_minor IS NOT NULL AND currency IS NOT NULL AND currency_exponent IS NOT NULL AND interval_months IS NOT NULL
GROUP BY currency, currency_exponent;

CREATE FUNCTION public.fj_revenue_report(p_from timestamptz, p_until timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_output jsonb;
BEGIN
  IF p_from IS NULL OR p_until IS NULL OR p_until <= p_from OR p_until > now() + interval '5 minutes'
     OR p_from < p_until - interval '400 days' THEN
    RAISE EXCEPTION 'INVALID_REPORT_WINDOW';
  END IF;
  WITH sums AS (
    SELECT currency, currency_exponent,
      count(*) FILTER (WHERE event_type = 'payment_succeeded') AS payments,
      count(*) FILTER (WHERE event_type IN ('refund_succeeded', 'chargeback')) AS reversals,
      sum(signed_amount_minor)::text AS net_collected_minor
    FROM public.fj_cash_events
    WHERE occurred_at >= p_from AND occurred_at < p_until
    GROUP BY currency, currency_exponent
  )
  SELECT jsonb_build_object('rows', coalesce(jsonb_agg(to_jsonb(sums)), '[]'::jsonb),
    'measure', 'net_cash_collected_not_mrr_or_accounting_revenue',
    'eventsNeedingReconciliation', (SELECT count(*) FROM public.billing_events
      WHERE state_disposition = 'needs_reconciliation' AND received_at >= p_from AND received_at < p_until))
  INTO v_output FROM sums;
  RETURN v_output;
END $$;

-- =====================================================================================================
-- 4. Operator automation: runs, publishing, metric snapshots
-- =====================================================================================================

CREATE FUNCTION public.fj_guard_post_edit() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF NEW.body IS DISTINCT FROM OLD.body OR NEW.body_sha256 IS DISTINCT FROM OLD.body_sha256 THEN
    IF OLD.status IN ('publishing', 'publish_unknown', 'published') THEN
      RAISE EXCEPTION 'PUBLISHED_CONTENT_IMMUTABLE';
    END IF;
    -- An edited draft needs a new approval of the new body hash.
    NEW.status := 'draft';
    NEW.approved_at := NULL;
    NEW.approved_body_sha256 := NULL;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER fj_post_edit BEFORE UPDATE ON public.fortune_posts FOR EACH ROW EXECUTE FUNCTION public.fj_guard_post_edit();

CREATE TABLE public.automation_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task text NOT NULL CHECK (task IN ('publish_post', 'collect_post_metrics', 'collect_account_metrics', 'import_posts',
    'draft_post', 'weekly_analysis', 'purge')),
  idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 1 AND 240),
  post_id uuid REFERENCES public.fortune_posts (id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'succeeded', 'failed', 'unknown')),
  actor_kind text NOT NULL CHECK (actor_kind IN ('owner_agent', 'server_cron', 'external_report')),
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  lease_expires_at timestamptz NOT NULL DEFAULT (now() + interval '2 minutes'),
  attempts integer NOT NULL DEFAULT 1 CHECK (attempts BETWEEN 1 AND 100),
  duration_ms bigint CHECK (duration_ms >= 0),
  -- Cost columns carry their provenance; NULL means unobserved, never zero.
  model text CHECK (char_length(model) <= 120),
  input_tokens bigint CHECK (input_tokens >= 0),
  output_tokens bigint CHECK (output_tokens >= 0),
  estimated_cost numeric(20, 8) CHECK (estimated_cost >= 0),
  cost_currency text CHECK (cost_currency ~ '^[A-Z]{3}$'),
  cost_source text NOT NULL DEFAULT 'unobserved' CHECK (cost_source IN ('unobserved', 'provider_reported', 'external_reported',
    'estimate', 'not_applicable')),
  error_code text CHECK (error_code ~ '^[A-Z0-9_]{1,80}$'),
  CONSTRAINT cost_has_currency CHECK ((estimated_cost IS NULL) = (cost_currency IS NULL)),
  CONSTRAINT unobserved_cost_is_empty CHECK (
    cost_source NOT IN ('unobserved', 'not_applicable') OR (estimated_cost IS NULL AND input_tokens IS NULL AND output_tokens IS NULL)
  ),
  CONSTRAINT finished_unless_running CHECK ((status = 'running') = (finished_at IS NULL)),
  UNIQUE (task, idempotency_key)
);
CREATE INDEX automation_runs_started ON public.automation_runs (started_at);
CREATE INDEX automation_runs_post ON public.automation_runs (post_id) WHERE post_id IS NOT NULL;
COMMENT ON TABLE public.automation_runs IS 'Idempotent run leases and history for operator automation (90 days).';

-- Snapshots keep run_id as their capture identity but no foreign key: they are kept 400 days, runs 90 days.
CREATE TABLE public.post_metric_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.fortune_posts (id) ON DELETE CASCADE,
  run_id uuid NOT NULL,
  collected_at timestamptz NOT NULL,
  target_age_hours smallint CHECK (target_age_hours IN (24, 72, 168)),
  snapshot_kind text NOT NULL CHECK (snapshot_kind IN ('scheduled', 'manual', 'backfill_now')),
  api_version text NOT NULL CHECK (api_version ~ '^v[0-9]+\.[0-9]+$'),
  -- Lifetime counters as reported; NULL = not reported (not zero).
  views bigint CHECK (views >= 0),
  likes bigint CHECK (likes >= 0),
  replies bigint CHECK (replies >= 0),
  reposts bigint CHECK (reposts >= 0),
  quotes bigint CHECK (quotes >= 0),
  shares bigint CHECK (shares >= 0),
  CONSTRAINT scheduled_has_target_age CHECK ((snapshot_kind = 'scheduled') = (target_age_hours IS NOT NULL)),
  UNIQUE (post_id, run_id)
);
COMMENT ON TABLE public.post_metric_snapshots IS 'Observed lifetime counters of one post at an actual time (400 days).';

-- LONG form: the follower count is a stock (point in time); the other metrics are flows over a period.
CREATE TABLE public.account_metric_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_key text NOT NULL CHECK (account_key ~ '^[A-Za-z0-9_:-]{1,100}$'),
  run_id uuid NOT NULL,
  collected_at timestamptz NOT NULL,
  metric_name text NOT NULL CHECK (metric_name IN ('views', 'likes', 'replies', 'reposts', 'quotes', 'followers_count')),
  metric_value bigint CHECK (metric_value >= 0),
  period_kind text NOT NULL CHECK (period_kind IN ('point_in_time', 'day', 'range')),
  period_start timestamptz,
  period_end timestamptz,
  api_version text NOT NULL CHECK (api_version ~ '^v[0-9]+\.[0-9]+$'),
  CONSTRAINT stock_or_flow CHECK (
    (metric_name = 'followers_count' AND period_kind = 'point_in_time' AND period_start IS NULL AND period_end IS NULL)
    OR (metric_name <> 'followers_count' AND period_kind IN ('day', 'range') AND period_start IS NOT NULL AND period_end > period_start)
  ),
  UNIQUE NULLS NOT DISTINCT (run_id, account_key, metric_name, period_kind, period_start, period_end)
);
CREATE INDEX account_metric_snapshots_series ON public.account_metric_snapshots (account_key, metric_name, collected_at);
COMMENT ON TABLE public.account_metric_snapshots IS 'One metric and interval per row; never sum follower stocks or overlapping ranges.';

-- Acquire (or re-acquire) the lease for one idempotent task. Publishing is never retried automatically:
-- an expired publish lease becomes 'unknown', and only a run recorded as definitely not published ('failed')
-- can be claimed again, by an explicit operator command. Other tasks get up to 3 attempts. A refusal reports
-- `exhausted` when no further attempt will ever be granted for this key (callers must treat it as a failure).
CREATE FUNCTION public.fj_begin_run(p_task text, p_key text, p_actor text, p_post_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_run public.automation_runs%ROWTYPE;
  v_new_id uuid;
BEGIN
  INSERT INTO public.automation_runs (task, idempotency_key, actor_kind, post_id)
  VALUES (p_task, p_key, p_actor, p_post_id)
  ON CONFLICT (task, idempotency_key) DO NOTHING
  RETURNING id INTO v_new_id;
  SELECT * INTO v_run FROM public.automation_runs WHERE task = p_task AND idempotency_key = p_key FOR UPDATE;
  IF v_run.post_id IS DISTINCT FROM p_post_id THEN
    RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT';
  END IF;
  IF v_new_id IS NOT NULL THEN
    RETURN jsonb_build_object('acquired', true, 'runId', v_run.id, 'attempt', v_run.attempts);
  END IF;

  IF p_task = 'publish_post' AND v_run.status = 'running' AND v_run.lease_expires_at <= now() THEN
    UPDATE public.automation_runs SET status = 'unknown', finished_at = now(), error_code = 'LEASE_EXPIRED' WHERE id = v_run.id;
    UPDATE public.fortune_posts SET status = 'publish_unknown' WHERE id = p_post_id AND status = 'publishing';
    RETURN jsonb_build_object('acquired', false, 'runId', v_run.id, 'status', 'unknown');
  END IF;
  IF v_run.attempts < 3 AND (v_run.status = 'failed'
       OR (p_task <> 'publish_post' AND v_run.status = 'running' AND v_run.lease_expires_at <= now())) THEN
    UPDATE public.automation_runs SET status = 'running', attempts = attempts + 1, started_at = now(), finished_at = NULL,
      lease_expires_at = now() + interval '2 minutes', error_code = NULL
    WHERE id = v_run.id
    RETURNING * INTO v_run;
    RETURN jsonb_build_object('acquired', true, 'runId', v_run.id, 'attempt', v_run.attempts);
  END IF;
  RETURN jsonb_build_object('acquired', false, 'runId', v_run.id, 'status', v_run.status, 'attempts', v_run.attempts,
    'errorCode', v_run.error_code,
    'exhausted', v_run.attempts >= 3 AND (v_run.status = 'failed'
      OR (v_run.status = 'running' AND v_run.lease_expires_at <= now())));
END $$;

-- Finishes the current attempt of a non-publish run; a stale attempt number is refused.
CREATE FUNCTION public.fj_finish_run(p_run_id uuid, p_attempt integer, p_success boolean, p_error text DEFAULT NULL) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  UPDATE public.automation_runs SET
    status = CASE WHEN p_success THEN 'succeeded' ELSE 'failed' END,
    finished_at = now(),
    duration_ms = greatest(0, extract(epoch FROM (now() - started_at)) * 1000)::bigint,
    error_code = CASE WHEN p_success THEN NULL ELSE p_error END
  WHERE id = p_run_id AND attempts = p_attempt AND status = 'running' AND task <> 'publish_post';
  RETURN FOUND;
END $$;

-- Approval binds to the exact body hash; Threads text posts are limited to 500 characters.
CREATE FUNCTION public.fj_approve_post(p_id uuid, p_hash text) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  UPDATE public.fortune_posts SET status = 'approved', approved_at = now(), approved_body_sha256 = p_hash
  WHERE id = p_id AND body_sha256 = p_hash AND status IN ('draft', 'approved') AND char_length(body) <= 500;
  RETURN FOUND;
END $$;

-- Lock order everywhere: fortune_posts row, then automation_runs row.
CREATE FUNCTION public.fj_claim_publish(p_post_id uuid, p_expected_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_post public.fortune_posts%ROWTYPE;
  v_run jsonb;
BEGIN
  SELECT * INTO v_post FROM public.fortune_posts WHERE id = p_post_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'POST_NOT_FOUND';
  END IF;
  IF v_post.status IN ('publishing', 'publish_unknown', 'published') THEN
    RETURN jsonb_build_object('acquired', false, 'status', v_post.status);
  END IF;
  IF p_expected_hash IS DISTINCT FROM v_post.body_sha256 OR v_post.status <> 'approved'
     OR v_post.approved_body_sha256 <> v_post.body_sha256 OR v_post.scheduled_at > now() THEN
    RAISE EXCEPTION 'POST_NOT_APPROVED_OR_NOT_DUE';
  END IF;
  v_run := public.fj_begin_run('publish_post', 'publish:' || v_post.id, 'owner_agent', v_post.id);
  IF (v_run->>'acquired')::boolean THEN
    UPDATE public.fortune_posts SET status = 'publishing' WHERE id = v_post.id;
  END IF;
  RETURN v_run;
END $$;

-- Outcome of one publish attempt. p_external_id set = published. p_external_id NULL = unknown (timeout, lost
-- response, failed local write), unless p_not_published: the failure happened before the publish call (container
-- creation), so nothing can be live; the post returns to 'approved' and the run is 'failed' (re-claimable once
-- the operator asks again). Unknown is terminal for automation; fj_resolve_publish is the human exit.
CREATE FUNCTION public.fj_finish_publish(
  p_post_id uuid,
  p_run_id uuid,
  p_external_id text,
  p_container_id text,
  p_error text DEFAULT NULL,
  p_not_published boolean DEFAULT false
) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_run public.automation_runs%ROWTYPE;
  v_not_published boolean := coalesce(p_not_published, false) AND p_external_id IS NULL;
BEGIN
  PERFORM 1 FROM public.fortune_posts WHERE id = p_post_id FOR UPDATE;
  SELECT * INTO v_run FROM public.automation_runs
  WHERE id = p_run_id AND post_id = p_post_id AND task = 'publish_post'
  FOR UPDATE;
  -- A definite "not published" may only end the attempt still in flight; an unknown run stays unknown.
  IF NOT FOUND OR v_run.status NOT IN ('running', 'unknown') OR (v_not_published AND v_run.status <> 'running') THEN
    RETURN false;
  END IF;
  UPDATE public.fortune_posts SET
    status = CASE WHEN p_external_id IS NOT NULL THEN 'published' WHEN v_not_published THEN 'approved' ELSE 'publish_unknown' END,
    external_post_id = p_external_id,
    container_id = coalesce(p_container_id, container_id),
    published_at = CASE WHEN p_external_id IS NULL THEN NULL ELSE now() END
  WHERE id = p_post_id;
  UPDATE public.automation_runs SET
    status = CASE WHEN p_external_id IS NOT NULL THEN 'succeeded' WHEN v_not_published THEN 'failed' ELSE 'unknown' END,
    finished_at = now(),
    duration_ms = greatest(0, extract(epoch FROM (now() - started_at)) * 1000)::bigint,
    error_code = p_error
  WHERE id = p_run_id;
  RETURN true;
END $$;

-- Human reconciliation of a publish_unknown post after checking the Threads profile. With an external id: it is
-- live (recorded as published now; the true publish time is not known). Without: a person confirmed it is not
-- live, so the post returns to 'approved' and the run to 'failed' (the next publish_post claims a new attempt).
CREATE FUNCTION public.fj_resolve_publish(p_post_id uuid, p_external_id text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_post public.fortune_posts%ROWTYPE;
BEGIN
  IF p_post_id IS NULL OR (p_external_id IS NOT NULL AND p_external_id !~ '^[0-9]{1,80}$') THEN
    RAISE EXCEPTION 'INVALID_RESOLUTION';
  END IF;
  SELECT * INTO v_post FROM public.fortune_posts WHERE id = p_post_id FOR UPDATE;
  IF NOT FOUND OR v_post.status <> 'publish_unknown' THEN
    RAISE EXCEPTION 'POST_NOT_UNKNOWN';
  END IF;
  PERFORM 1 FROM public.automation_runs WHERE post_id = p_post_id AND task = 'publish_post' FOR UPDATE;
  IF p_external_id IS NOT NULL THEN
    UPDATE public.fortune_posts SET status = 'published', external_post_id = p_external_id, published_at = now()
    WHERE id = p_post_id;
  ELSE
    UPDATE public.fortune_posts SET status = 'approved' WHERE id = p_post_id;
  END IF;
  UPDATE public.automation_runs SET
    status = CASE WHEN p_external_id IS NOT NULL THEN 'succeeded' ELSE 'failed' END,
    finished_at = coalesce(finished_at, now()),
    error_code = CASE WHEN p_external_id IS NOT NULL THEN 'RESOLVED_PUBLISHED' ELSE 'RESOLVED_NOT_PUBLISHED' END
  WHERE post_id = p_post_id AND task = 'publish_post' AND status IN ('unknown', 'running');
  RETURN jsonb_build_object('resolved', true, 'status', CASE WHEN p_external_id IS NOT NULL THEN 'published' ELSE 'approved' END);
END $$;

-- =====================================================================================================
-- 5. KPI reports (read-only; NULL means not observable or not yet mature, never zero)
-- =====================================================================================================

-- The snapshot closest to 24h after publishing, observed between 24h and 26h.
CREATE VIEW public.fj_post_24h WITH (security_invoker = true) AS
WITH candidates AS (
  SELECT p.id AS post_id, p.account_key, p.topic, p.tone, p.method, p.experiment_id, p.variant_key, p.published_at,
    s.collected_at, s.views, s.likes, s.replies, s.reposts, s.quotes, s.shares,
    extract(epoch FROM (s.collected_at - p.published_at)) / 3600 AS actual_age_hours,
    row_number() OVER (PARTITION BY p.id ORDER BY s.collected_at - p.published_at, s.id) AS rn
  FROM public.fortune_posts p
  JOIN public.post_metric_snapshots s ON s.post_id = p.id
  WHERE s.snapshot_kind = 'scheduled' AND s.target_age_hours = 24
    AND s.collected_at >= p.published_at + interval '24 hours' AND s.collected_at <= p.published_at + interval '26 hours'
)
SELECT post_id, account_key, topic, tone, method, experiment_id, variant_key, published_at, collected_at,
  views, likes, replies, reposts, quotes, shares, actual_age_hours,
  CASE WHEN views > 0 AND likes IS NOT NULL AND replies IS NOT NULL AND reposts IS NOT NULL AND quotes IS NOT NULL
    THEN 100.0 * (likes::numeric + replies + reposts + quotes) / views END AS engagement_pct
FROM candidates
WHERE rn = 1;

-- Signup cohorts of consenting near-signup accounts: 24h activation, exact D7 return, paid within 35 days.
CREATE FUNCTION public.fj_cohort_report(p_from timestamptz, p_until timestamptz, p_asof timestamptz DEFAULT now()) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_output jsonb;
BEGIN
  IF p_from IS NULL OR p_until IS NULL OR p_asof IS NULL OR p_until <= p_from OR p_until > p_asof
     OR p_from < p_asof - interval '90 days' OR p_asof > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'INVALID_COHORT_WINDOW';
  END IF;
  WITH registrations AS (
    SELECT user_id, occurred_at, source_channel FROM public.funnel_events
    WHERE event_name = 'registration' AND occurred_at >= p_from AND occurred_at < p_until
  ), cohort AS (
    SELECT r.*, a.first_calculated_at,
      EXISTS (
        SELECT 1 FROM public.user_readings u
        WHERE u.user_id = r.user_id AND u.calculated_at >= a.first_calculated_at + interval '7 days'
          AND u.calculated_at < a.first_calculated_at + interval '8 days' AND u.calculated_at <= p_asof
      ) AS d7,
      EXISTS (
        SELECT 1 FROM public.billing_events b
        WHERE b.user_id = r.user_id AND b.event_type = 'payment_succeeded' AND b.amount_minor > 0
          AND b.occurred_at >= r.occurred_at AND b.occurred_at < r.occurred_at + interval '35 days' AND b.occurred_at <= p_asof
      ) AS paid35
    FROM registrations r
    JOIN public.user_access a ON a.user_id = r.user_id
  ), groups AS (
    SELECT source_channel, count(*) AS cohort_size,
      count(*) FILTER (WHERE occurred_at <= p_asof - interval '24 hours') AS activation_eligible,
      count(*) FILTER (WHERE occurred_at <= p_asof - interval '24 hours' AND first_calculated_at >= occurred_at
        AND first_calculated_at < occurred_at + interval '24 hours') AS activated,
      count(*) FILTER (WHERE first_calculated_at <= p_asof - interval '8 days') AS d7_eligible,
      count(*) FILTER (WHERE first_calculated_at <= p_asof - interval '8 days' AND d7) AS d7_returned,
      count(*) FILTER (WHERE occurred_at <= p_asof - interval '35 days') AS conversion_eligible,
      count(*) FILTER (WHERE occurred_at <= p_asof - interval '35 days' AND paid35) AS paid_35d
    FROM cohort
    GROUP BY source_channel
  )
  SELECT jsonb_build_object(
    'population', 'consented_near_signup_accounts_only', 'windowStart', p_from, 'windowEnd', p_until, 'asOf', p_asof,
    'rows', coalesce(jsonb_agg(to_jsonb(groups) || jsonb_build_object(
      'activation_24h_pct', 100.0 * activated / nullif(activation_eligible, 0),
      'd7_exact_pct', 100.0 * d7_returned / nullif(d7_eligible, 0),
      'paid_35d_pct', 100.0 * paid_35d / nullif(conversion_eligible, 0))), '[]'::jsonb))
  INTO v_output FROM groups;
  RETURN v_output;
END $$;

-- Follower growth as the difference of two endpoint snapshots, each observed within the preceding 26 hours.
CREATE FUNCTION public.fj_follower_growth(p_account text, p_until timestamptz DEFAULT now()) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_baseline public.account_metric_snapshots%ROWTYPE;
  v_latest public.account_metric_snapshots%ROWTYPE;
BEGIN
  IF p_account IS NULL OR p_until IS NULL OR p_until > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'INVALID_GROWTH_WINDOW';
  END IF;
  SELECT * INTO v_baseline FROM public.account_metric_snapshots
  WHERE account_key = p_account AND metric_name = 'followers_count' AND metric_value IS NOT NULL
    AND collected_at <= p_until - interval '7 days' AND collected_at >= p_until - interval '7 days 26 hours'
  ORDER BY collected_at DESC, id
  LIMIT 1;
  SELECT * INTO v_latest FROM public.account_metric_snapshots
  WHERE account_key = p_account AND metric_name = 'followers_count' AND metric_value IS NOT NULL
    AND collected_at <= p_until AND collected_at >= p_until - interval '26 hours'
  ORDER BY collected_at DESC, id
  LIMIT 1;
  RETURN jsonb_build_object(
    'account', p_account, 'requestedEnd', p_until, 'baselineAt', v_baseline.collected_at, 'latestAt', v_latest.collected_at,
    'baselineCount', v_baseline.metric_value, 'latestCount', v_latest.metric_value,
    'netGrowth', v_latest.metric_value - v_baseline.metric_value,
    'actualDays', extract(epoch FROM (v_latest.collected_at - v_baseline.collected_at)) / 86400.0,
    'complete', v_baseline.id IS NOT NULL AND v_latest.id IS NOT NULL,
    'definition', 'endpoint_difference_with_26h_freshness_not_sum');
END $$;

CREATE FUNCTION public.fj_operation_report(p_from timestamptz, p_until timestamptz) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_tasks jsonb;
  v_costs jsonb;
BEGIN
  IF p_from IS NULL OR p_until IS NULL OR p_until <= p_from OR p_until > now() + interval '5 minutes'
     OR p_from < p_until - interval '90 days' THEN
    RAISE EXCEPTION 'INVALID_OPERATION_WINDOW';
  END IF;
  WITH t AS (
    SELECT task, count(*) AS runs,
      count(*) FILTER (WHERE status = 'succeeded') AS succeeded,
      count(*) FILTER (WHERE status = 'failed') AS failed,
      count(*) FILTER (WHERE status = 'unknown') AS unknown,
      count(*) FILTER (WHERE status = 'running') AS running,
      count(*) FILTER (WHERE attempts > 1) AS retried,
      count(*) FILTER (WHERE estimated_cost IS NOT NULL) AS cost_observed,
      avg(duration_ms) FILTER (WHERE duration_ms IS NOT NULL) AS mean_duration_ms
    FROM public.automation_runs
    WHERE started_at >= p_from AND started_at < p_until
    GROUP BY task
  )
  SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) INTO v_tasks FROM t;
  WITH c AS (
    SELECT cost_currency, cost_source, count(*) AS runs, sum(estimated_cost)::text AS recorded_cost
    FROM public.automation_runs
    WHERE started_at >= p_from AND started_at < p_until AND estimated_cost IS NOT NULL
    GROUP BY cost_currency, cost_source
  )
  SELECT coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) INTO v_costs FROM c;
  RETURN jsonb_build_object('tasks', v_tasks, 'costByCurrencyAndSource', v_costs,
    -- Outstanding human work regardless of the window: never re-posted automatically (fj_resolve_publish).
    'publishUnknown', (SELECT coalesce(jsonb_agg(jsonb_build_object('postId', id, 'since', updated_at) ORDER BY updated_at), '[]'::jsonb)
      FROM (SELECT id, updated_at FROM public.fortune_posts WHERE status = 'publish_unknown' ORDER BY updated_at LIMIT 50) u),
    'caveat', 'Missing cost is unobserved, not zero. Customer-host LLM costs are not observable.');
END $$;

-- =====================================================================================================
-- 6. Retention (proposed operational periods, not statutory ones; billing is deliberately excluded)
-- =====================================================================================================

CREATE FUNCTION public.fj_purge_expired() RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_events bigint;
  v_readings bigint;
  v_runs bigint;
  v_post_snapshots bigint;
  v_account_snapshots bigint;
BEGIN
  DELETE FROM public.funnel_events WHERE occurred_at < now() - interval '90 days';
  GET DIAGNOSTICS v_events = ROW_COUNT;
  -- Feedback and reading-linked events cascade from the ledger.
  DELETE FROM public.user_readings WHERE calculated_at < now() - interval '90 days';
  GET DIAGNOSTICS v_readings = ROW_COUNT;

  -- An orphaned in-flight publish is unknown, never queued for an automatic repost (posts before runs).
  UPDATE public.fortune_posts p SET status = 'publish_unknown'
  WHERE p.status = 'publishing' AND EXISTS (
    SELECT 1 FROM public.automation_runs r
    WHERE r.post_id = p.id AND r.task = 'publish_post' AND r.status = 'running' AND r.lease_expires_at < now()
  );
  UPDATE public.automation_runs SET status = 'unknown', finished_at = now(), error_code = 'LEASE_EXPIRED'
  WHERE task = 'publish_post' AND status = 'running' AND lease_expires_at < now();
  DELETE FROM public.automation_runs WHERE status IN ('succeeded', 'failed') AND finished_at < now() - interval '90 days';
  GET DIAGNOSTICS v_runs = ROW_COUNT;

  DELETE FROM public.post_metric_snapshots WHERE collected_at < now() - interval '400 days';
  GET DIAGNOSTICS v_post_snapshots = ROW_COUNT;
  DELETE FROM public.account_metric_snapshots WHERE collected_at < now() - interval '400 days';
  GET DIAGNOSTICS v_account_snapshots = ROW_COUNT;
  RETURN jsonb_build_object('readingsDeleted', v_readings, 'eventsDeleted', v_events, 'runsDeleted', v_runs,
    'snapshotsDeleted', v_post_snapshots + v_account_snapshots);
END $$;

-- One-line descriptions shown in docs/generated/DB_CATALOG.md.
COMMENT ON FUNCTION public.fj_record_calculation(uuid, uuid, text, text, text, date, text, text, boolean) IS
  'MCP calculate_numerology/draw_tarot: trial start, tier, idempotent replay, usage limit and ledger row in one transaction.';
COMMENT ON FUNCTION public.fj_set_privacy(uuid, boolean, boolean, text, timestamptz) IS
  'Login page: set optional consent; withdrawal deletes events/feedback and clears topics.';
COMMENT ON FUNCTION public.fj_set_attribution(uuid, text, text, uuid) IS 'Login page: self-reported or signed-link source of a consenting registration.';
COMMENT ON FUNCTION public.fj_record_funnel(uuid, text, text, text, text, uuid) IS 'MCP: consented connection telemetry and explicit self-reports.';
COMMENT ON FUNCTION public.fj_submit_feedback(uuid, uuid, smallint, text, date) IS 'MCP: consented fixed-label feedback on an own reading.';
COMMENT ON FUNCTION public.fj_apply_billing(text, text, jsonb) IS 'Billing adapter (not connected): idempotent verified event, cash counted once, ordered/reconciled subscription snapshot.';
COMMENT ON FUNCTION public.fj_revenue_report(timestamptz, timestamptz) IS 'Ops report: net cash collected per currency (not MRR) and billing events needing reconciliation.';
COMMENT ON FUNCTION public.fj_begin_run(text, text, text, uuid) IS 'Ops: acquire an idempotent run lease (publish never retried automatically; exhausted keys reported).';
COMMENT ON FUNCTION public.fj_finish_run(uuid, integer, boolean, text) IS 'Ops: finish the current attempt of a non-publish run.';
COMMENT ON FUNCTION public.fj_approve_post(uuid, text) IS 'Ops: approve a draft bound to its body hash.';
COMMENT ON FUNCTION public.fj_claim_publish(uuid, text) IS 'Ops: claim an approved, due post for publishing (one claim only).';
COMMENT ON FUNCTION public.fj_finish_publish(uuid, uuid, text, text, text, boolean) IS 'Ops: record published, unknown or definitely-not-published outcome.';
COMMENT ON FUNCTION public.fj_resolve_publish(uuid, text) IS 'Ops: human reconciliation of a publish_unknown post (published with id, or not published).';
COMMENT ON FUNCTION public.fj_cohort_report(timestamptz, timestamptz, timestamptz) IS 'Ops report: consented signup cohorts (activation, D7, paid 35d).';
COMMENT ON FUNCTION public.fj_follower_growth(text, timestamptz) IS 'Ops report: 7-day follower change from two fresh endpoint snapshots.';
COMMENT ON FUNCTION public.fj_operation_report(timestamptz, timestamptz) IS 'Ops report: run outcomes, recorded costs with provenance, outstanding unknown publishes.';
COMMENT ON FUNCTION public.fj_purge_expired() IS 'Cron: 90/400-day retention and expired publish leases to unknown.';
COMMENT ON FUNCTION public.fj_access_token_hook(jsonb) IS 'Supabase Auth hook: OAuth-client tokens get aud=urn:fortune-journal:mcp.';
COMMENT ON FUNCTION public.fj_deidentify_subscription() IS 'Trigger: a subscription binding of a deleted account drops the provider customer id.';
COMMENT ON FUNCTION public.fj_guard_post_edit() IS 'Trigger: published bodies are immutable; edits withdraw approval.';

-- =====================================================================================================
-- 7. Privileges: backend only
-- =====================================================================================================

-- RLS without policies denies anon/authenticated even if a grant is added by mistake (defense in depth);
-- service_role bypasses RLS, so the app derives every user id from the verified Auth user, never from input.
ALTER TABLE public.user_access ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_readings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fortune_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.funnel_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reading_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.automation_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_metric_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_metric_snapshots ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON
  public.user_access, public.subscriptions, public.user_readings, public.fortune_posts, public.funnel_events,
  public.reading_feedback, public.billing_events, public.automation_runs, public.post_metric_snapshots,
  public.account_metric_snapshots, public.fj_cash_events, public.fj_current_mrr, public.fj_post_24h
FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.user_access, public.subscriptions, public.user_readings, public.fortune_posts, public.funnel_events,
  public.reading_feedback, public.billing_events, public.automation_runs, public.post_metric_snapshots,
  public.account_metric_snapshots
TO service_role;
GRANT SELECT ON public.fj_cash_events, public.fj_current_mrr, public.fj_post_24h TO service_role;

-- Functions are executable by PUBLIC (and, on Supabase, anon/authenticated) by default.
DO $$
DECLARE
  v_function regprocedure;
BEGIN
  FOR v_function IN
    SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', v_function);
  END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION
  public.fj_access_status(uuid),
  public.fj_record_calculation(uuid, uuid, text, text, text, date, text, text, boolean),
  public.fj_set_privacy(uuid, boolean, boolean, text, timestamptz),
  public.fj_set_attribution(uuid, text, text, uuid),
  public.fj_record_funnel(uuid, text, text, text, text, uuid),
  public.fj_submit_feedback(uuid, uuid, smallint, text, date),
  public.fj_apply_billing(text, text, jsonb),
  public.fj_revenue_report(timestamptz, timestamptz),
  public.fj_begin_run(text, text, text, uuid),
  public.fj_finish_run(uuid, integer, boolean, text),
  public.fj_approve_post(uuid, text),
  public.fj_claim_publish(uuid, text),
  public.fj_finish_publish(uuid, uuid, text, text, text, boolean),
  public.fj_resolve_publish(uuid, text),
  public.fj_cohort_report(timestamptz, timestamptz, timestamptz),
  public.fj_follower_growth(text, timestamptz),
  public.fj_operation_report(timestamptz, timestamptz),
  public.fj_purge_expired(),
  public.fj_access_token_hook(jsonb)
TO service_role;
-- Supabase Auth runs the hook as supabase_auth_admin; it needs nothing else in this schema.
GRANT EXECUTE ON FUNCTION public.fj_access_token_hook(jsonb) TO supabase_auth_admin;
COMMIT;
