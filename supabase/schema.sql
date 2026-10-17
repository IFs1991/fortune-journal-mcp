--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: fj_access_status(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_access_status(p_user_id uuid) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO ''
    AS $$
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


--
-- Name: FUNCTION fj_access_status(p_user_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_access_status(p_user_id uuid) IS 'The only tier rule: suspended > verified current subscription > trial > free.';


--
-- Name: fj_access_token_hook(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_access_token_hook(event jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO ''
    AS $$
DECLARE
  v_claims jsonb := event->'claims';
BEGIN
  IF jsonb_typeof(v_claims->'client_id') = 'string' AND v_claims->>'client_id' <> '' THEN
    v_claims := jsonb_set(v_claims, '{aud}', '"urn:fortune-journal:mcp"'::jsonb);
  END IF;
  RETURN jsonb_build_object('claims', v_claims);
END $$;


--
-- Name: FUNCTION fj_access_token_hook(event jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_access_token_hook(event jsonb) IS 'Supabase Auth hook: OAuth-client tokens get aud=urn:fortune-journal:mcp.';


--
-- Name: fj_apply_billing(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_apply_billing(p_provider text, p_event_id text, p_event jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
DECLARE
  v_kind text := p_event->>'event_type';
  v_occurred_at timestamptz := (p_event->>'occurred_at')::timestamptz;
  v_economic_key text := p_event->>'economic_key';
  v_amount bigint := (p_event->>'amount_minor')::bigint;
  v_currency text := p_event->>'currency';
  v_exponent smallint := (p_event->>'currency_exponent')::smallint;
  v_snapshot jsonb := nullif(p_event->'subscription', 'null'::jsonb);
  v_snapshot_at timestamptz;
  v_is_cash boolean;
  v_disposition text := 'none';
  v_subscription public.subscriptions%ROWTYPE;
  v_previous public.billing_events%ROWTYPE;
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

  -- Duplicate delivery (same event id) or another notification of the same money movement.
  SELECT * INTO v_previous FROM public.billing_events
  WHERE provider = p_provider AND (event_id = p_event_id OR economic_key = v_economic_key)
  LIMIT 1;
  IF FOUND THEN
    IF v_previous.event_type IS DISTINCT FROM v_kind OR v_previous.amount_minor IS DISTINCT FROM v_amount
       OR v_previous.currency IS DISTINCT FROM v_currency OR v_previous.currency_exponent IS DISTINCT FROM v_exponent
       OR v_previous.provider_subscription_id IS DISTINCT FROM v_subscription.provider_subscription_id THEN
      RAISE EXCEPTION 'BILLING_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN jsonb_build_object('duplicate', true, 'stateApplied', false);
  END IF;

  IF v_snapshot IS NOT NULL THEN
    v_snapshot_at := (v_snapshot->>'provider_updated_at')::timestamptz;
    IF v_snapshot_at IS NULL OR v_snapshot_at > now() + interval '5 minutes' OR v_snapshot->>'status' IS NULL
       OR v_snapshot->>'status' NOT IN ('incomplete', 'trialing', 'active', 'past_due', 'canceled', 'unpaid', 'expired') THEN
      RAISE EXCEPTION 'INVALID_SUBSCRIPTION_SNAPSHOT';
    END IF;
    IF v_subscription.provider_updated_at IS NULL OR v_snapshot_at > v_subscription.provider_updated_at THEN
      UPDATE public.subscriptions SET
        status = v_snapshot->>'status',
        current_period_end = (v_snapshot->>'current_period_end')::timestamptz,
        cancel_at_period_end = coalesce((v_snapshot->>'cancel_at_period_end')::boolean, false),
        verified_at = now(),
        provider_updated_at = v_snapshot_at,
        plan_key = v_snapshot->>'plan_key',
        amount_minor = (v_snapshot->>'amount_minor')::bigint,
        currency = v_snapshot->>'currency',
        currency_exponent = (v_snapshot->>'currency_exponent')::smallint,
        interval_months = (v_snapshot->>'interval_months')::smallint,
        updated_at = now()
      WHERE id = v_subscription.id;
      v_disposition := 'applied';
    ELSIF v_snapshot_at = v_subscription.provider_updated_at
       AND (v_snapshot->>'status' IS DISTINCT FROM v_subscription.status
         OR (v_snapshot->>'current_period_end')::timestamptz IS DISTINCT FROM v_subscription.current_period_end) THEN
      v_disposition := 'needs_reconciliation';
    ELSE
      v_disposition := 'older_or_identical';
    END IF;
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
END $_$;


--
-- Name: FUNCTION fj_apply_billing(p_provider text, p_event_id text, p_event jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_apply_billing(p_provider text, p_event_id text, p_event jsonb) IS 'Billing adapter (not connected): idempotent verified event + ordered subscription snapshot.';


--
-- Name: fj_approve_post(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_approve_post(p_id uuid, p_hash text) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
  UPDATE public.fortune_posts SET status = 'approved', approved_at = now(), approved_body_sha256 = p_hash
  WHERE id = p_id AND body_sha256 = p_hash AND status IN ('draft', 'approved') AND char_length(body) <= 500;
  RETURN FOUND;
END $$;


--
-- Name: FUNCTION fj_approve_post(p_id uuid, p_hash text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_approve_post(p_id uuid, p_hash text) IS 'Ops: approve a draft bound to its body hash.';


--
-- Name: fj_begin_run(text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_begin_run(p_task text, p_key text, p_actor text, p_post_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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
  IF p_task <> 'publish_post' AND v_run.attempts < 3
     AND (v_run.status = 'failed' OR (v_run.status = 'running' AND v_run.lease_expires_at <= now())) THEN
    UPDATE public.automation_runs SET status = 'running', attempts = attempts + 1, started_at = now(), finished_at = NULL,
      lease_expires_at = now() + interval '2 minutes', error_code = NULL
    WHERE id = v_run.id
    RETURNING * INTO v_run;
    RETURN jsonb_build_object('acquired', true, 'runId', v_run.id, 'attempt', v_run.attempts);
  END IF;
  RETURN jsonb_build_object('acquired', false, 'runId', v_run.id, 'status', v_run.status);
END $$;


--
-- Name: FUNCTION fj_begin_run(p_task text, p_key text, p_actor text, p_post_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_begin_run(p_task text, p_key text, p_actor text, p_post_id uuid) IS 'Ops: acquire an idempotent run lease (publish is never retried).';


--
-- Name: fj_claim_publish(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_claim_publish(p_post_id uuid, p_expected_hash text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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


--
-- Name: FUNCTION fj_claim_publish(p_post_id uuid, p_expected_hash text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_claim_publish(p_post_id uuid, p_expected_hash text) IS 'Ops: claim an approved, due post for publishing (one claim only).';


--
-- Name: fj_cohort_report(timestamp with time zone, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_cohort_report(p_from timestamp with time zone, p_until timestamp with time zone, p_asof timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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


--
-- Name: FUNCTION fj_cohort_report(p_from timestamp with time zone, p_until timestamp with time zone, p_asof timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_cohort_report(p_from timestamp with time zone, p_until timestamp with time zone, p_asof timestamp with time zone) IS 'Ops report: consented signup cohorts (activation, D7, paid 35d).';


--
-- Name: fj_finish_publish(uuid, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_finish_publish(p_post_id uuid, p_run_id uuid, p_external_id text, p_container_id text, p_error text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
  v_run public.automation_runs%ROWTYPE;
BEGIN
  PERFORM 1 FROM public.fortune_posts WHERE id = p_post_id FOR UPDATE;
  SELECT * INTO v_run FROM public.automation_runs
  WHERE id = p_run_id AND post_id = p_post_id AND task = 'publish_post'
  FOR UPDATE;
  IF NOT FOUND OR v_run.status NOT IN ('running', 'unknown') THEN
    RETURN false;
  END IF;
  UPDATE public.fortune_posts SET
    status = CASE WHEN p_external_id IS NULL THEN 'publish_unknown' ELSE 'published' END,
    external_post_id = p_external_id,
    container_id = coalesce(p_container_id, container_id),
    published_at = CASE WHEN p_external_id IS NULL THEN NULL ELSE now() END
  WHERE id = p_post_id;
  UPDATE public.automation_runs SET
    status = CASE WHEN p_external_id IS NULL THEN 'unknown' ELSE 'succeeded' END,
    finished_at = now(),
    duration_ms = greatest(0, extract(epoch FROM (now() - started_at)) * 1000)::bigint,
    error_code = p_error
  WHERE id = p_run_id;
  RETURN true;
END $$;


--
-- Name: FUNCTION fj_finish_publish(p_post_id uuid, p_run_id uuid, p_external_id text, p_container_id text, p_error text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_finish_publish(p_post_id uuid, p_run_id uuid, p_external_id text, p_container_id text, p_error text) IS 'Ops: record published or unknown outcome.';


--
-- Name: fj_finish_run(uuid, integer, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_finish_run(p_run_id uuid, p_attempt integer, p_success boolean, p_error text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
  UPDATE public.automation_runs SET
    status = CASE WHEN p_success THEN 'succeeded' ELSE 'failed' END,
    finished_at = now(),
    duration_ms = greatest(0, extract(epoch FROM (now() - started_at)) * 1000)::bigint,
    error_code = CASE WHEN p_success THEN NULL ELSE p_error END
  WHERE id = p_run_id AND attempts = p_attempt AND status = 'running' AND task <> 'publish_post';
  RETURN FOUND;
END $$;


--
-- Name: FUNCTION fj_finish_run(p_run_id uuid, p_attempt integer, p_success boolean, p_error text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_finish_run(p_run_id uuid, p_attempt integer, p_success boolean, p_error text) IS 'Ops: finish the current attempt of a non-publish run.';


--
-- Name: fj_follower_growth(text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_follower_growth(p_account text, p_until timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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


--
-- Name: FUNCTION fj_follower_growth(p_account text, p_until timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_follower_growth(p_account text, p_until timestamp with time zone) IS 'Ops report: 7-day follower change from two fresh endpoint snapshots.';


--
-- Name: fj_guard_post_edit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_guard_post_edit() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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


--
-- Name: FUNCTION fj_guard_post_edit(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_guard_post_edit() IS 'Trigger: published bodies are immutable; edits withdraw approval.';


--
-- Name: fj_operation_report(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_operation_report(p_from timestamp with time zone, p_until timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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
    'caveat', 'Missing cost is unobserved, not zero. Customer-host LLM costs are not observable.');
END $$;


--
-- Name: FUNCTION fj_operation_report(p_from timestamp with time zone, p_until timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_operation_report(p_from timestamp with time zone, p_until timestamp with time zone) IS 'Ops report: run outcomes and recorded costs with provenance.';


--
-- Name: fj_purge_expired(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_purge_expired() RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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


--
-- Name: FUNCTION fj_purge_expired(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_purge_expired() IS 'Cron: 90/400-day retention and expired publish leases to unknown.';


--
-- Name: fj_record_calculation(uuid, uuid, text, text, text, date, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_record_calculation(p_user_id uuid, p_request_id uuid, p_fingerprint text, p_feature text, p_algorithm text, p_target_date date, p_topic text DEFAULT NULL::text, p_client text DEFAULT 'unknown'::text, p_collect_analytics boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
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
END $_$;


--
-- Name: FUNCTION fj_record_calculation(p_user_id uuid, p_request_id uuid, p_fingerprint text, p_feature text, p_algorithm text, p_target_date date, p_topic text, p_client text, p_collect_analytics boolean); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_record_calculation(p_user_id uuid, p_request_id uuid, p_fingerprint text, p_feature text, p_algorithm text, p_target_date date, p_topic text, p_client text, p_collect_analytics boolean) IS 'MCP calculate_numerology/draw_tarot: trial start, tier, idempotent replay, usage limit and ledger row in one transaction.';


--
-- Name: fj_record_funnel(uuid, text, text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_record_funnel(p_user_id uuid, p_event text, p_dedupe_key text, p_channel text DEFAULT 'unknown'::text, p_evidence text DEFAULT 'unknown'::text, p_reading_id uuid DEFAULT NULL::uuid) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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


--
-- Name: FUNCTION fj_record_funnel(p_user_id uuid, p_event text, p_dedupe_key text, p_channel text, p_evidence text, p_reading_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_record_funnel(p_user_id uuid, p_event text, p_dedupe_key text, p_channel text, p_evidence text, p_reading_id uuid) IS 'MCP: consented connection telemetry and explicit self-reports.';


--
-- Name: fj_revenue_report(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_revenue_report(p_from timestamp with time zone, p_until timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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
    'measure', 'net_cash_collected_not_mrr_or_accounting_revenue')
  INTO v_output FROM sums;
  RETURN v_output;
END $$;


--
-- Name: FUNCTION fj_revenue_report(p_from timestamp with time zone, p_until timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_revenue_report(p_from timestamp with time zone, p_until timestamp with time zone) IS 'Ops report: net cash collected per currency (not MRR).';


--
-- Name: fj_set_attribution(uuid, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_set_attribution(p_user_id uuid, p_channel text, p_evidence text, p_post_id uuid DEFAULT NULL::uuid) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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


--
-- Name: FUNCTION fj_set_attribution(p_user_id uuid, p_channel text, p_evidence text, p_post_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_set_attribution(p_user_id uuid, p_channel text, p_evidence text, p_post_id uuid) IS 'Login page: self-reported or signed-link source of a consenting registration.';


--
-- Name: fj_set_privacy(uuid, boolean, boolean, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_set_privacy(p_user_id uuid, p_analytics boolean, p_interests boolean, p_version text, p_registered_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
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
END $_$;


--
-- Name: FUNCTION fj_set_privacy(p_user_id uuid, p_analytics boolean, p_interests boolean, p_version text, p_registered_at timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_set_privacy(p_user_id uuid, p_analytics boolean, p_interests boolean, p_version text, p_registered_at timestamp with time zone) IS 'Login page: set optional consent; withdrawal deletes events/feedback and clears topics.';


--
-- Name: fj_submit_feedback(uuid, uuid, smallint, text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fj_submit_feedback(p_user_id uuid, p_reading_id uuid, p_usefulness smallint, p_match text, p_followup date DEFAULT NULL::date) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
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


--
-- Name: FUNCTION fj_submit_feedback(p_user_id uuid, p_reading_id uuid, p_usefulness smallint, p_match text, p_followup date); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.fj_submit_feedback(p_user_id uuid, p_reading_id uuid, p_usefulness smallint, p_match text, p_followup date) IS 'MCP: consented fixed-label feedback on an own reading.';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_metric_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_metric_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_key text NOT NULL,
    run_id uuid NOT NULL,
    collected_at timestamp with time zone NOT NULL,
    metric_name text NOT NULL,
    metric_value bigint,
    period_kind text NOT NULL,
    period_start timestamp with time zone,
    period_end timestamp with time zone,
    api_version text NOT NULL,
    CONSTRAINT account_metric_snapshots_account_key_check CHECK ((account_key ~ '^[A-Za-z0-9_:-]{1,100}$'::text)),
    CONSTRAINT account_metric_snapshots_api_version_check CHECK ((api_version ~ '^v[0-9]+\.[0-9]+$'::text)),
    CONSTRAINT account_metric_snapshots_metric_name_check CHECK ((metric_name = ANY (ARRAY['views'::text, 'likes'::text, 'replies'::text, 'reposts'::text, 'quotes'::text, 'followers_count'::text]))),
    CONSTRAINT account_metric_snapshots_metric_value_check CHECK ((metric_value >= 0)),
    CONSTRAINT account_metric_snapshots_period_kind_check CHECK ((period_kind = ANY (ARRAY['point_in_time'::text, 'day'::text, 'range'::text]))),
    CONSTRAINT stock_or_flow CHECK ((((metric_name = 'followers_count'::text) AND (period_kind = 'point_in_time'::text) AND (period_start IS NULL) AND (period_end IS NULL)) OR ((metric_name <> 'followers_count'::text) AND (period_kind = ANY (ARRAY['day'::text, 'range'::text])) AND (period_start IS NOT NULL) AND (period_end > period_start))))
);


--
-- Name: TABLE account_metric_snapshots; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.account_metric_snapshots IS 'One metric and interval per row; never sum follower stocks or overlapping ranges.';


--
-- Name: automation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.automation_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    task text NOT NULL,
    idempotency_key text NOT NULL,
    post_id uuid,
    status text DEFAULT 'running'::text NOT NULL,
    actor_kind text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    lease_expires_at timestamp with time zone DEFAULT (now() + '00:02:00'::interval) NOT NULL,
    attempts integer DEFAULT 1 NOT NULL,
    duration_ms bigint,
    model text,
    input_tokens bigint,
    output_tokens bigint,
    estimated_cost numeric(20,8),
    cost_currency text,
    cost_source text DEFAULT 'unobserved'::text NOT NULL,
    error_code text,
    CONSTRAINT automation_runs_actor_kind_check CHECK ((actor_kind = ANY (ARRAY['owner_agent'::text, 'server_cron'::text, 'external_report'::text]))),
    CONSTRAINT automation_runs_attempts_check CHECK (((attempts >= 1) AND (attempts <= 100))),
    CONSTRAINT automation_runs_cost_currency_check CHECK ((cost_currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT automation_runs_cost_source_check CHECK ((cost_source = ANY (ARRAY['unobserved'::text, 'provider_reported'::text, 'external_reported'::text, 'estimate'::text, 'not_applicable'::text]))),
    CONSTRAINT automation_runs_duration_ms_check CHECK ((duration_ms >= 0)),
    CONSTRAINT automation_runs_error_code_check CHECK ((error_code ~ '^[A-Z0-9_]{1,80}$'::text)),
    CONSTRAINT automation_runs_estimated_cost_check CHECK ((estimated_cost >= (0)::numeric)),
    CONSTRAINT automation_runs_idempotency_key_check CHECK (((char_length(idempotency_key) >= 1) AND (char_length(idempotency_key) <= 240))),
    CONSTRAINT automation_runs_input_tokens_check CHECK ((input_tokens >= 0)),
    CONSTRAINT automation_runs_model_check CHECK ((char_length(model) <= 120)),
    CONSTRAINT automation_runs_output_tokens_check CHECK ((output_tokens >= 0)),
    CONSTRAINT automation_runs_status_check CHECK ((status = ANY (ARRAY['running'::text, 'succeeded'::text, 'failed'::text, 'unknown'::text]))),
    CONSTRAINT automation_runs_task_check CHECK ((task = ANY (ARRAY['publish_post'::text, 'collect_post_metrics'::text, 'collect_account_metrics'::text, 'import_posts'::text, 'draft_post'::text, 'weekly_analysis'::text, 'purge'::text]))),
    CONSTRAINT cost_has_currency CHECK (((estimated_cost IS NULL) = (cost_currency IS NULL))),
    CONSTRAINT finished_unless_running CHECK (((status = 'running'::text) = (finished_at IS NULL))),
    CONSTRAINT unobserved_cost_is_empty CHECK (((cost_source <> ALL (ARRAY['unobserved'::text, 'not_applicable'::text])) OR ((estimated_cost IS NULL) AND (input_tokens IS NULL) AND (output_tokens IS NULL))))
);


--
-- Name: TABLE automation_runs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.automation_runs IS 'Idempotent run leases and history for operator automation (90 days).';


--
-- Name: billing_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_events (
    provider text NOT NULL,
    event_id text NOT NULL,
    user_id uuid,
    provider_subscription_id text NOT NULL,
    event_type text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    economic_key text,
    original_payment_key text,
    amount_minor bigint,
    currency text,
    currency_exponent smallint,
    billing_reason text DEFAULT 'not_applicable'::text NOT NULL,
    plan_key text,
    state_disposition text NOT NULL,
    CONSTRAINT billing_events_amount_minor_check CHECK ((amount_minor >= 0)),
    CONSTRAINT billing_events_billing_reason_check CHECK ((billing_reason = ANY (ARRAY['initial'::text, 'recurring'::text, 'one_time'::text, 'not_applicable'::text]))),
    CONSTRAINT billing_events_currency_check CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT billing_events_currency_exponent_check CHECK (((currency_exponent >= 0) AND (currency_exponent <= 6))),
    CONSTRAINT billing_events_economic_key_check CHECK (((char_length(economic_key) >= 1) AND (char_length(economic_key) <= 160))),
    CONSTRAINT billing_events_event_id_check CHECK (((char_length(event_id) >= 1) AND (char_length(event_id) <= 200))),
    CONSTRAINT billing_events_event_type_check CHECK ((event_type = ANY (ARRAY['subscription_updated'::text, 'payment_succeeded'::text, 'payment_failed'::text, 'subscription_canceled'::text, 'refund_succeeded'::text, 'chargeback'::text]))),
    CONSTRAINT billing_events_plan_key_check CHECK ((plan_key ~ '^[A-Za-z0-9_.:-]{1,80}$'::text)),
    CONSTRAINT billing_events_provider_check CHECK ((provider ~ '^[a-z][a-z0-9_]{1,30}$'::text)),
    CONSTRAINT billing_events_state_disposition_check CHECK ((state_disposition = ANY (ARRAY['none'::text, 'applied'::text, 'older_or_identical'::text, 'needs_reconciliation'::text]))),
    CONSTRAINT cash_fields CHECK (
CASE
    WHEN (event_type = ANY (ARRAY['payment_succeeded'::text, 'refund_succeeded'::text, 'chargeback'::text])) THEN ((economic_key IS NOT NULL) AND (amount_minor IS NOT NULL) AND (currency IS NOT NULL) AND (currency_exponent IS NOT NULL))
    ELSE ((economic_key IS NULL) AND (amount_minor IS NULL) AND (currency IS NULL) AND (currency_exponent IS NULL))
END)
);


--
-- Name: TABLE billing_events; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.billing_events IS 'Verified, normalized provider events. Cash collections are not MRR. Not auto-purged.';


--
-- Name: fj_cash_events; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.fj_cash_events WITH (security_invoker='true') AS
 SELECT provider,
    event_id,
    user_id,
    provider_subscription_id,
    economic_key,
    occurred_at,
    event_type,
    currency,
    currency_exponent,
    billing_reason,
        CASE
            WHEN (event_type = 'payment_succeeded'::text) THEN amount_minor
            ELSE (- amount_minor)
        END AS signed_amount_minor
   FROM public.billing_events
  WHERE (event_type = ANY (ARRAY['payment_succeeded'::text, 'refund_succeeded'::text, 'chargeback'::text]));


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    provider text NOT NULL,
    provider_customer_id text NOT NULL,
    provider_subscription_id text NOT NULL,
    status text NOT NULL,
    current_period_end timestamp with time zone,
    cancel_at_period_end boolean DEFAULT false NOT NULL,
    verified_at timestamp with time zone,
    provider_updated_at timestamp with time zone,
    plan_key text,
    amount_minor bigint,
    currency text,
    currency_exponent smallint,
    interval_months smallint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT subscriptions_amount_minor_check CHECK ((amount_minor >= 0)),
    CONSTRAINT subscriptions_currency_check CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT subscriptions_currency_exponent_check CHECK (((currency_exponent >= 0) AND (currency_exponent <= 6))),
    CONSTRAINT subscriptions_interval_months_check CHECK (((interval_months >= 1) AND (interval_months <= 12))),
    CONSTRAINT subscriptions_plan_key_check CHECK ((plan_key ~ '^[A-Za-z0-9_.:-]{1,80}$'::text)),
    CONSTRAINT subscriptions_provider_check CHECK ((provider ~ '^[a-z][a-z0-9_]{1,30}$'::text)),
    CONSTRAINT subscriptions_status_check CHECK ((status = ANY (ARRAY['incomplete'::text, 'trialing'::text, 'active'::text, 'past_due'::text, 'canceled'::text, 'unpaid'::text, 'expired'::text])))
);


--
-- Name: TABLE subscriptions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.subscriptions IS 'Server-created binding to a provider subscription plus its latest verified state.';


--
-- Name: fj_current_mrr; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.fj_current_mrr WITH (security_invoker='true') AS
 SELECT currency,
    currency_exponent,
    count(*) AS subscriptions,
    sum((((amount_minor)::numeric / power((10)::numeric, (currency_exponent)::numeric)) / (interval_months)::numeric)) AS mrr
   FROM public.subscriptions
  WHERE ((verified_at IS NOT NULL) AND (status = 'active'::text) AND (current_period_end > now()) AND (amount_minor IS NOT NULL) AND (currency IS NOT NULL) AND (currency_exponent IS NOT NULL) AND (interval_months IS NOT NULL))
  GROUP BY currency, currency_exponent;


--
-- Name: fortune_posts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fortune_posts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_key text NOT NULL,
    external_post_id text,
    container_id text,
    body text NOT NULL,
    body_sha256 text NOT NULL,
    topic text DEFAULT 'unclassified'::text NOT NULL,
    method text DEFAULT 'unclassified'::text NOT NULL,
    tone text DEFAULT 'unclassified'::text NOT NULL,
    zodiac text,
    language text DEFAULT 'und'::text NOT NULL,
    hook_text text,
    cta_key text DEFAULT 'none'::text NOT NULL,
    prompt_version text,
    experiment_id text,
    variant_key text,
    status text DEFAULT 'draft'::text NOT NULL,
    scheduled_at timestamp with time zone,
    published_at timestamp with time zone,
    approved_at timestamp with time zone,
    approved_body_sha256 text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT approval_matches_body CHECK (((status <> ALL (ARRAY['approved'::text, 'publishing'::text])) OR ((approved_at IS NOT NULL) AND (approved_body_sha256 = body_sha256)))),
    CONSTRAINT fortune_posts_account_key_check CHECK ((account_key ~ '^[A-Za-z0-9_:-]{1,100}$'::text)),
    CONSTRAINT fortune_posts_approved_body_sha256_check CHECK ((approved_body_sha256 ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT fortune_posts_body_check CHECK (((char_length(body) >= 1) AND (char_length(body) <= 10000))),
    CONSTRAINT fortune_posts_body_sha256_check CHECK ((body_sha256 ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT fortune_posts_container_id_check CHECK ((container_id ~ '^[0-9]{1,80}$'::text)),
    CONSTRAINT fortune_posts_cta_key_check CHECK ((cta_key = ANY (ARRAY['none'::text, 'reflect'::text, 'save'::text, 'reply'::text, 'visit_profile'::text]))),
    CONSTRAINT fortune_posts_experiment_id_check CHECK ((experiment_id ~ '^[A-Za-z0-9_.:-]{1,80}$'::text)),
    CONSTRAINT fortune_posts_external_post_id_check CHECK ((external_post_id ~ '^[0-9]{1,80}$'::text)),
    CONSTRAINT fortune_posts_hook_text_check CHECK ((char_length(hook_text) <= 240)),
    CONSTRAINT fortune_posts_language_check CHECK ((language ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$'::text)),
    CONSTRAINT fortune_posts_method_check CHECK ((method = ANY (ARRAY['tarot'::text, 'numerology'::text, 'mixed'::text, 'unclassified'::text]))),
    CONSTRAINT fortune_posts_prompt_version_check CHECK ((prompt_version ~ '^[A-Za-z0-9_.:-]{1,80}$'::text)),
    CONSTRAINT fortune_posts_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'approved'::text, 'publishing'::text, 'publish_unknown'::text, 'published'::text]))),
    CONSTRAINT fortune_posts_tone_check CHECK ((tone = ANY (ARRAY['empathetic'::text, 'assertive'::text, 'question'::text, 'unclassified'::text]))),
    CONSTRAINT fortune_posts_topic_check CHECK ((topic = ANY (ARRAY['love'::text, 'work'::text, 'money'::text, 'general'::text, 'unclassified'::text]))),
    CONSTRAINT fortune_posts_variant_key_check CHECK ((variant_key ~ '^[A-Za-z0-9_.:-]{1,80}$'::text)),
    CONSTRAINT fortune_posts_zodiac_check CHECK ((zodiac = ANY (ARRAY['aries'::text, 'taurus'::text, 'gemini'::text, 'cancer'::text, 'leo'::text, 'virgo'::text, 'libra'::text, 'scorpio'::text, 'sagittarius'::text, 'capricorn'::text, 'aquarius'::text, 'pisces'::text]))),
    CONSTRAINT published_has_external_id CHECK (((status <> 'published'::text) OR ((external_post_id IS NOT NULL) AND (published_at IS NOT NULL))))
);


--
-- Name: TABLE fortune_posts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.fortune_posts IS 'Operator-owned public marketing posts only, never customer content.';


--
-- Name: post_metric_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.post_metric_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    run_id uuid NOT NULL,
    collected_at timestamp with time zone NOT NULL,
    target_age_hours smallint,
    snapshot_kind text NOT NULL,
    api_version text NOT NULL,
    views bigint,
    likes bigint,
    replies bigint,
    reposts bigint,
    quotes bigint,
    shares bigint,
    CONSTRAINT post_metric_snapshots_api_version_check CHECK ((api_version ~ '^v[0-9]+\.[0-9]+$'::text)),
    CONSTRAINT post_metric_snapshots_likes_check CHECK ((likes >= 0)),
    CONSTRAINT post_metric_snapshots_quotes_check CHECK ((quotes >= 0)),
    CONSTRAINT post_metric_snapshots_replies_check CHECK ((replies >= 0)),
    CONSTRAINT post_metric_snapshots_reposts_check CHECK ((reposts >= 0)),
    CONSTRAINT post_metric_snapshots_shares_check CHECK ((shares >= 0)),
    CONSTRAINT post_metric_snapshots_snapshot_kind_check CHECK ((snapshot_kind = ANY (ARRAY['scheduled'::text, 'manual'::text, 'backfill_now'::text]))),
    CONSTRAINT post_metric_snapshots_target_age_hours_check CHECK ((target_age_hours = ANY (ARRAY[24, 72, 168]))),
    CONSTRAINT post_metric_snapshots_views_check CHECK ((views >= 0)),
    CONSTRAINT scheduled_has_target_age CHECK (((snapshot_kind = 'scheduled'::text) = (target_age_hours IS NOT NULL)))
);


--
-- Name: TABLE post_metric_snapshots; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.post_metric_snapshots IS 'Observed lifetime counters of one post at an actual time (400 days).';


--
-- Name: fj_post_24h; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.fj_post_24h WITH (security_invoker='true') AS
 WITH candidates AS (
         SELECT p.id AS post_id,
            p.account_key,
            p.topic,
            p.tone,
            p.method,
            p.experiment_id,
            p.variant_key,
            p.published_at,
            s.collected_at,
            s.views,
            s.likes,
            s.replies,
            s.reposts,
            s.quotes,
            s.shares,
            (EXTRACT(epoch FROM (s.collected_at - p.published_at)) / (3600)::numeric) AS actual_age_hours,
            row_number() OVER (PARTITION BY p.id ORDER BY (s.collected_at - p.published_at), s.id) AS rn
           FROM (public.fortune_posts p
             JOIN public.post_metric_snapshots s ON ((s.post_id = p.id)))
          WHERE ((s.snapshot_kind = 'scheduled'::text) AND (s.target_age_hours = 24) AND (s.collected_at >= (p.published_at + '24:00:00'::interval)) AND (s.collected_at <= (p.published_at + '26:00:00'::interval)))
        )
 SELECT post_id,
    account_key,
    topic,
    tone,
    method,
    experiment_id,
    variant_key,
    published_at,
    collected_at,
    views,
    likes,
    replies,
    reposts,
    quotes,
    shares,
    actual_age_hours,
        CASE
            WHEN ((views > 0) AND (likes IS NOT NULL) AND (replies IS NOT NULL) AND (reposts IS NOT NULL) AND (quotes IS NOT NULL)) THEN ((100.0 * ((((likes)::numeric + (replies)::numeric) + (reposts)::numeric) + (quotes)::numeric)) / (views)::numeric)
            ELSE NULL::numeric
        END AS engagement_pct
   FROM candidates
  WHERE (rn = 1);


--
-- Name: funnel_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.funnel_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    event_name text NOT NULL,
    dedupe_key text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    source_channel text DEFAULT 'unknown'::text NOT NULL,
    source_evidence text DEFAULT 'unknown'::text NOT NULL,
    observation text NOT NULL,
    post_id uuid,
    reading_id uuid,
    CONSTRAINT funnel_events_dedupe_key_check CHECK (((char_length(dedupe_key) >= 1) AND (char_length(dedupe_key) <= 160))),
    CONSTRAINT funnel_events_event_name_check CHECK ((event_name = ANY (ARRAY['registration'::text, 'analytics_enrolled'::text, 'mcp_connected'::text, 'reading_completed'::text, 'journal_save_reported'::text, 'life_log_reported'::text, 'review_reported'::text]))),
    CONSTRAINT funnel_events_observation_check CHECK ((observation = ANY (ARRAY['server'::text, 'self_reported'::text]))),
    CONSTRAINT funnel_events_source_channel_check CHECK ((source_channel = ANY (ARRAY['threads'::text, 'chatgpt'::text, 'claude'::text, 'direct'::text, 'unknown'::text]))),
    CONSTRAINT funnel_events_source_evidence_check CHECK ((source_evidence = ANY (ARRAY['signed_link'::text, 'self_reported'::text, 'registered_client'::text, 'unknown'::text]))),
    CONSTRAINT observation_matches_event CHECK (((event_name = ANY (ARRAY['journal_save_reported'::text, 'life_log_reported'::text, 'review_reported'::text])) = (observation = 'self_reported'::text)))
);


--
-- Name: TABLE funnel_events; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.funnel_events IS 'Optional, consented product events. Deleted on withdrawal; no anonymous tracking IDs.';


--
-- Name: reading_feedback; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reading_feedback (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    reading_id uuid NOT NULL,
    usefulness smallint NOT NULL,
    match_assessment text NOT NULL,
    followup_date date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT reading_feedback_match_assessment_check CHECK ((match_assessment = ANY (ARRAY['not_assessed'::text, 'matched'::text, 'mixed'::text, 'not_matched'::text, 'unclear'::text]))),
    CONSTRAINT reading_feedback_usefulness_check CHECK (((usefulness >= 1) AND (usefulness <= 5)))
);


--
-- Name: TABLE reading_feedback; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.reading_feedback IS 'Optional fixed-label feedback for one of the user''s own readings.';


--
-- Name: user_access; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_access (
    user_id uuid NOT NULL,
    trial_started_at timestamp with time zone,
    trial_ends_at timestamp with time zone,
    first_calculated_at timestamp with time zone,
    suspended_at timestamp with time zone,
    analytics_consent_at timestamp with time zone,
    interest_consent_at timestamp with time zone,
    consent_version text,
    consent_updated_at timestamp with time zone,
    analytics_revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT interest_requires_analytics CHECK (((interest_consent_at IS NULL) OR (analytics_consent_at IS NOT NULL))),
    CONSTRAINT trial_window CHECK ((((trial_started_at IS NULL) = (trial_ends_at IS NULL)) AND ((trial_ends_at IS NULL) OR (trial_ends_at >= trial_started_at)))),
    CONSTRAINT user_access_consent_version_check CHECK ((consent_version ~ '^[0-9]{4}-[0-9]{2}-v[0-9]+$'::text))
);


--
-- Name: TABLE user_access; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_access IS 'One row per user: trial window, suspension and optional-consent state. No birth or journal data.';


--
-- Name: user_readings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_readings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    request_fingerprint text NOT NULL,
    feature_key text NOT NULL,
    algorithm_version text NOT NULL,
    target_date date NOT NULL,
    topic text,
    tier_at_use text NOT NULL,
    remaining_after integer NOT NULL,
    calculated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_readings_algorithm_version_check CHECK ((algorithm_version ~ '^[A-Za-z0-9_.:-]{1,80}$'::text)),
    CONSTRAINT user_readings_feature_key_check CHECK ((feature_key = ANY (ARRAY['calculate_numerology'::text, 'draw_tarot'::text]))),
    CONSTRAINT user_readings_remaining_after_check CHECK ((remaining_after >= 0)),
    CONSTRAINT user_readings_request_fingerprint_check CHECK ((request_fingerprint ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT user_readings_tier_at_use_check CHECK ((tier_at_use = ANY (ARRAY['free'::text, 'trial'::text, 'premium'::text]))),
    CONSTRAINT user_readings_topic_check CHECK ((topic = ANY (ARRAY['love'::text, 'work'::text, 'money'::text, 'general'::text])))
);


--
-- Name: TABLE user_readings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.user_readings IS '90-day operational ledger: one row per consumed usage unit / idempotent request. No reading text.';


--
-- Name: account_metric_snapshots account_metric_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_metric_snapshots
    ADD CONSTRAINT account_metric_snapshots_pkey PRIMARY KEY (id);


--
-- Name: account_metric_snapshots account_metric_snapshots_run_id_account_key_metric_name_per_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_metric_snapshots
    ADD CONSTRAINT account_metric_snapshots_run_id_account_key_metric_name_per_key UNIQUE NULLS NOT DISTINCT (run_id, account_key, metric_name, period_kind, period_start, period_end);


--
-- Name: automation_runs automation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_runs
    ADD CONSTRAINT automation_runs_pkey PRIMARY KEY (id);


--
-- Name: automation_runs automation_runs_task_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_runs
    ADD CONSTRAINT automation_runs_task_idempotency_key_key UNIQUE (task, idempotency_key);


--
-- Name: billing_events billing_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT billing_events_pkey PRIMARY KEY (provider, event_id);


--
-- Name: fortune_posts fortune_posts_account_key_external_post_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fortune_posts
    ADD CONSTRAINT fortune_posts_account_key_external_post_id_key UNIQUE (account_key, external_post_id);


--
-- Name: fortune_posts fortune_posts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fortune_posts
    ADD CONSTRAINT fortune_posts_pkey PRIMARY KEY (id);


--
-- Name: funnel_events funnel_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funnel_events
    ADD CONSTRAINT funnel_events_pkey PRIMARY KEY (id);


--
-- Name: funnel_events funnel_events_user_id_dedupe_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funnel_events
    ADD CONSTRAINT funnel_events_user_id_dedupe_key_key UNIQUE (user_id, dedupe_key);


--
-- Name: post_metric_snapshots post_metric_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_metric_snapshots
    ADD CONSTRAINT post_metric_snapshots_pkey PRIMARY KEY (id);


--
-- Name: post_metric_snapshots post_metric_snapshots_post_id_run_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_metric_snapshots
    ADD CONSTRAINT post_metric_snapshots_post_id_run_id_key UNIQUE (post_id, run_id);


--
-- Name: reading_feedback reading_feedback_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_feedback
    ADD CONSTRAINT reading_feedback_pkey PRIMARY KEY (id);


--
-- Name: reading_feedback reading_feedback_user_id_reading_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_feedback
    ADD CONSTRAINT reading_feedback_user_id_reading_id_key UNIQUE (user_id, reading_id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_provider_provider_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_provider_provider_subscription_id_key UNIQUE (provider, provider_subscription_id);


--
-- Name: user_access user_access_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_access
    ADD CONSTRAINT user_access_pkey PRIMARY KEY (user_id);


--
-- Name: user_readings user_readings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_readings
    ADD CONSTRAINT user_readings_pkey PRIMARY KEY (id);


--
-- Name: user_readings user_readings_user_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_readings
    ADD CONSTRAINT user_readings_user_id_id_key UNIQUE (user_id, id);


--
-- Name: user_readings user_readings_user_id_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_readings
    ADD CONSTRAINT user_readings_user_id_request_id_key UNIQUE (user_id, request_id);


--
-- Name: account_metric_snapshots_series; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX account_metric_snapshots_series ON public.account_metric_snapshots USING btree (account_key, metric_name, collected_at);


--
-- Name: automation_runs_post; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX automation_runs_post ON public.automation_runs USING btree (post_id) WHERE (post_id IS NOT NULL);


--
-- Name: automation_runs_started; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX automation_runs_started ON public.automation_runs USING btree (started_at);


--
-- Name: billing_events_cash_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_events_cash_time ON public.billing_events USING btree (occurred_at) WHERE (economic_key IS NOT NULL);


--
-- Name: billing_events_economic_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX billing_events_economic_key ON public.billing_events USING btree (provider, economic_key) WHERE (economic_key IS NOT NULL);


--
-- Name: billing_events_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX billing_events_user ON public.billing_events USING btree (user_id) WHERE (user_id IS NOT NULL);


--
-- Name: funnel_events_cohort; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX funnel_events_cohort ON public.funnel_events USING btree (event_name, occurred_at, user_id);


--
-- Name: funnel_events_post; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX funnel_events_post ON public.funnel_events USING btree (post_id) WHERE (post_id IS NOT NULL);


--
-- Name: funnel_events_reading; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX funnel_events_reading ON public.funnel_events USING btree (user_id, reading_id) WHERE (reading_id IS NOT NULL);


--
-- Name: subscriptions_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscriptions_user ON public.subscriptions USING btree (user_id);


--
-- Name: user_readings_user_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_readings_user_time ON public.user_readings USING btree (user_id, calculated_at);


--
-- Name: fortune_posts fj_post_edit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER fj_post_edit BEFORE UPDATE ON public.fortune_posts FOR EACH ROW EXECUTE FUNCTION public.fj_guard_post_edit();


--
-- Name: automation_runs automation_runs_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_runs
    ADD CONSTRAINT automation_runs_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.fortune_posts(id) ON DELETE SET NULL;


--
-- Name: billing_events billing_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.billing_events
    ADD CONSTRAINT billing_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: funnel_events funnel_events_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funnel_events
    ADD CONSTRAINT funnel_events_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.fortune_posts(id) ON DELETE SET NULL;


--
-- Name: funnel_events funnel_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funnel_events
    ADD CONSTRAINT funnel_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: funnel_events funnel_events_user_id_reading_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funnel_events
    ADD CONSTRAINT funnel_events_user_id_reading_id_fkey FOREIGN KEY (user_id, reading_id) REFERENCES public.user_readings(user_id, id) ON DELETE CASCADE;


--
-- Name: post_metric_snapshots post_metric_snapshots_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.post_metric_snapshots
    ADD CONSTRAINT post_metric_snapshots_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.fortune_posts(id) ON DELETE CASCADE;


--
-- Name: reading_feedback reading_feedback_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_feedback
    ADD CONSTRAINT reading_feedback_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: reading_feedback reading_feedback_user_id_reading_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_feedback
    ADD CONSTRAINT reading_feedback_user_id_reading_id_fkey FOREIGN KEY (user_id, reading_id) REFERENCES public.user_readings(user_id, id) ON DELETE CASCADE;


--
-- Name: subscriptions subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_access user_access_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_access
    ADD CONSTRAINT user_access_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_readings user_readings_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_readings
    ADD CONSTRAINT user_readings_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: account_metric_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.account_metric_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: automation_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.automation_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: billing_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.billing_events ENABLE ROW LEVEL SECURITY;

--
-- Name: fortune_posts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fortune_posts ENABLE ROW LEVEL SECURITY;

--
-- Name: funnel_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.funnel_events ENABLE ROW LEVEL SECURITY;

--
-- Name: post_metric_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.post_metric_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: reading_feedback; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.reading_feedback ENABLE ROW LEVEL SECURITY;

--
-- Name: subscriptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: user_access; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_access ENABLE ROW LEVEL SECURITY;

--
-- Name: user_readings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_readings ENABLE ROW LEVEL SECURITY;

--
-- Name: FUNCTION fj_access_status(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_access_status(p_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_access_status(p_user_id uuid) TO service_role;


--
-- Name: FUNCTION fj_access_token_hook(event jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_access_token_hook(event jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_access_token_hook(event jsonb) TO service_role;
GRANT ALL ON FUNCTION public.fj_access_token_hook(event jsonb) TO supabase_auth_admin;


--
-- Name: FUNCTION fj_apply_billing(p_provider text, p_event_id text, p_event jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_apply_billing(p_provider text, p_event_id text, p_event jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_apply_billing(p_provider text, p_event_id text, p_event jsonb) TO service_role;


--
-- Name: FUNCTION fj_approve_post(p_id uuid, p_hash text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_approve_post(p_id uuid, p_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_approve_post(p_id uuid, p_hash text) TO service_role;


--
-- Name: FUNCTION fj_begin_run(p_task text, p_key text, p_actor text, p_post_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_begin_run(p_task text, p_key text, p_actor text, p_post_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_begin_run(p_task text, p_key text, p_actor text, p_post_id uuid) TO service_role;


--
-- Name: FUNCTION fj_claim_publish(p_post_id uuid, p_expected_hash text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_claim_publish(p_post_id uuid, p_expected_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_claim_publish(p_post_id uuid, p_expected_hash text) TO service_role;


--
-- Name: FUNCTION fj_cohort_report(p_from timestamp with time zone, p_until timestamp with time zone, p_asof timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_cohort_report(p_from timestamp with time zone, p_until timestamp with time zone, p_asof timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_cohort_report(p_from timestamp with time zone, p_until timestamp with time zone, p_asof timestamp with time zone) TO service_role;


--
-- Name: FUNCTION fj_finish_publish(p_post_id uuid, p_run_id uuid, p_external_id text, p_container_id text, p_error text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_finish_publish(p_post_id uuid, p_run_id uuid, p_external_id text, p_container_id text, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_finish_publish(p_post_id uuid, p_run_id uuid, p_external_id text, p_container_id text, p_error text) TO service_role;


--
-- Name: FUNCTION fj_finish_run(p_run_id uuid, p_attempt integer, p_success boolean, p_error text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_finish_run(p_run_id uuid, p_attempt integer, p_success boolean, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_finish_run(p_run_id uuid, p_attempt integer, p_success boolean, p_error text) TO service_role;


--
-- Name: FUNCTION fj_follower_growth(p_account text, p_until timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_follower_growth(p_account text, p_until timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_follower_growth(p_account text, p_until timestamp with time zone) TO service_role;


--
-- Name: FUNCTION fj_guard_post_edit(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_guard_post_edit() FROM PUBLIC;


--
-- Name: FUNCTION fj_operation_report(p_from timestamp with time zone, p_until timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_operation_report(p_from timestamp with time zone, p_until timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_operation_report(p_from timestamp with time zone, p_until timestamp with time zone) TO service_role;


--
-- Name: FUNCTION fj_purge_expired(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_purge_expired() FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_purge_expired() TO service_role;


--
-- Name: FUNCTION fj_record_calculation(p_user_id uuid, p_request_id uuid, p_fingerprint text, p_feature text, p_algorithm text, p_target_date date, p_topic text, p_client text, p_collect_analytics boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_record_calculation(p_user_id uuid, p_request_id uuid, p_fingerprint text, p_feature text, p_algorithm text, p_target_date date, p_topic text, p_client text, p_collect_analytics boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_record_calculation(p_user_id uuid, p_request_id uuid, p_fingerprint text, p_feature text, p_algorithm text, p_target_date date, p_topic text, p_client text, p_collect_analytics boolean) TO service_role;


--
-- Name: FUNCTION fj_record_funnel(p_user_id uuid, p_event text, p_dedupe_key text, p_channel text, p_evidence text, p_reading_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_record_funnel(p_user_id uuid, p_event text, p_dedupe_key text, p_channel text, p_evidence text, p_reading_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_record_funnel(p_user_id uuid, p_event text, p_dedupe_key text, p_channel text, p_evidence text, p_reading_id uuid) TO service_role;


--
-- Name: FUNCTION fj_revenue_report(p_from timestamp with time zone, p_until timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_revenue_report(p_from timestamp with time zone, p_until timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_revenue_report(p_from timestamp with time zone, p_until timestamp with time zone) TO service_role;


--
-- Name: FUNCTION fj_set_attribution(p_user_id uuid, p_channel text, p_evidence text, p_post_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_set_attribution(p_user_id uuid, p_channel text, p_evidence text, p_post_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_set_attribution(p_user_id uuid, p_channel text, p_evidence text, p_post_id uuid) TO service_role;


--
-- Name: FUNCTION fj_set_privacy(p_user_id uuid, p_analytics boolean, p_interests boolean, p_version text, p_registered_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_set_privacy(p_user_id uuid, p_analytics boolean, p_interests boolean, p_version text, p_registered_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_set_privacy(p_user_id uuid, p_analytics boolean, p_interests boolean, p_version text, p_registered_at timestamp with time zone) TO service_role;


--
-- Name: FUNCTION fj_submit_feedback(p_user_id uuid, p_reading_id uuid, p_usefulness smallint, p_match text, p_followup date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fj_submit_feedback(p_user_id uuid, p_reading_id uuid, p_usefulness smallint, p_match text, p_followup date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fj_submit_feedback(p_user_id uuid, p_reading_id uuid, p_usefulness smallint, p_match text, p_followup date) TO service_role;


--
-- Name: TABLE account_metric_snapshots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.account_metric_snapshots TO service_role;


--
-- Name: TABLE automation_runs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.automation_runs TO service_role;


--
-- Name: TABLE billing_events; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.billing_events TO service_role;


--
-- Name: TABLE fj_cash_events; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fj_cash_events TO service_role;


--
-- Name: TABLE subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.subscriptions TO service_role;


--
-- Name: TABLE fj_current_mrr; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fj_current_mrr TO service_role;


--
-- Name: TABLE fortune_posts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.fortune_posts TO service_role;


--
-- Name: TABLE post_metric_snapshots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.post_metric_snapshots TO service_role;


--
-- Name: TABLE fj_post_24h; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fj_post_24h TO service_role;


--
-- Name: TABLE funnel_events; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.funnel_events TO service_role;


--
-- Name: TABLE reading_feedback; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.reading_feedback TO service_role;


--
-- Name: TABLE user_access; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_access TO service_role;


--
-- Name: TABLE user_readings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_readings TO service_role;


--
-- PostgreSQL database dump complete
--


