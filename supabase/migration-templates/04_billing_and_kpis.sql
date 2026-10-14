BEGIN;
-- The caller MUST first verify the provider signature and normalize an authoritative event.
-- No user id comes from provider metadata: a prior server-created subscription binding is mandatory.
CREATE FUNCTION public.fj_apply_billing(p_provider text,p_event_id text,p_event jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
 s public.subscriptions%ROWTYPE; prev public.billing_events%ROWTYPE;
 kind text := p_event->>'event_type'; stamp timestamptz := (p_event->>'occurred_at')::timestamptz;
 econ text := p_event->>'economic_key'; inserted text; cash boolean;
 state jsonb := p_event->'subscription'; new_status text; effective timestamptz;
BEGIN
 IF p_provider IS NULL OR p_provider !~ '^[a-z][a-z0-9_]{1,30}$' OR p_event_id IS NULL OR char_length(p_event_id) NOT BETWEEN 1 AND 200 OR
   kind IS NULL OR kind NOT IN ('subscription_updated','payment_succeeded','payment_failed','subscription_canceled','refund_succeeded','chargeback') OR
   stamp IS NULL OR stamp>now()+interval '5 minutes' THEN RAISE EXCEPTION 'INVALID_BILLING_EVENT'; END IF;
 SELECT * INTO s FROM public.subscriptions WHERE provider=p_provider AND provider_subscription_id=p_event->>'provider_subscription_id' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'BILLING_BINDING_REQUIRED'; END IF;
 cash := kind IN ('payment_succeeded','refund_succeeded','chargeback');
 IF cash AND (econ IS NULL OR p_event->>'amount_minor' IS NULL OR p_event->>'currency' IS NULL OR p_event->>'currency_exponent' IS NULL) THEN
  RAISE EXCEPTION 'INVALID_FINANCIAL_FIELDS'; END IF;
 IF NOT cash AND (econ IS NOT NULL OR p_event->>'amount_minor' IS NOT NULL) THEN RAISE EXCEPTION 'NON_FINANCIAL_AMOUNT'; END IF;
 SELECT * INTO prev FROM public.billing_events WHERE provider=p_provider AND
  (event_id=p_event_id OR (econ IS NOT NULL AND economic_key=econ)) LIMIT 1;
 IF FOUND THEN
  IF prev.event_type IS DISTINCT FROM kind OR prev.amount_minor IS DISTINCT FROM (p_event->>'amount_minor')::bigint OR
     prev.currency IS DISTINCT FROM (p_event->>'currency') OR prev.currency_exponent IS DISTINCT FROM (p_event->>'currency_exponent')::smallint OR prev.provider_subscription_id IS DISTINCT FROM s.provider_subscription_id THEN
   RAISE EXCEPTION 'BILLING_IDEMPOTENCY_CONFLICT'; END IF;
  RETURN jsonb_build_object('duplicate',true,'stateApplied',false);
 END IF;
 INSERT INTO public.billing_events(provider,event_id,user_id,processing_status,event_type,provider_subscription_id,occurred_at,verified_at,
 economic_key,original_payment_key,amount_minor,currency,currency_exponent,billing_reason,plan_key)
 VALUES(p_provider,p_event_id,s.user_id,'received',kind,s.provider_subscription_id,stamp,now(),econ,p_event->>'original_payment_key',
 (p_event->>'amount_minor')::bigint,p_event->>'currency',(p_event->>'currency_exponent')::smallint,p_event->>'billing_reason',p_event->>'plan_key');
 -- Financial events alone never imply entitlement. Apply only an authoritative subscription snapshot.
 IF state IS NOT NULL AND state<>'null'::jsonb THEN
  new_status := state->>'status'; effective := (state->>'provider_updated_at')::timestamptz;
  IF new_status IS NULL OR effective IS NULL OR effective>now()+interval '5 minutes' OR
    new_status NOT IN ('incomplete','trialing','active','past_due','canceled','unpaid','expired') THEN RAISE EXCEPTION 'INVALID_SUBSCRIPTION_SNAPSHOT'; END IF;
  IF s.provider_updated_at IS NULL OR effective>s.provider_updated_at THEN
   UPDATE public.subscriptions SET status=new_status,current_period_end=(state->>'current_period_end')::timestamptz,
    cancel_at_period_end=coalesce((state->>'cancel_at_period_end')::boolean,false),verified_at=now(),provider_updated_at=effective,
    plan_key=state->>'plan_key',amount_minor=(state->>'amount_minor')::bigint,currency=state->>'currency',
    currency_exponent=(state->>'currency_exponent')::smallint,interval_months=(state->>'interval_months')::smallint,updated_at=now()
    WHERE id=s.id;
   inserted := 'applied';
  ELSIF effective=s.provider_updated_at AND (new_status IS DISTINCT FROM s.status OR (state->>'current_period_end')::timestamptz IS DISTINCT FROM s.current_period_end) THEN
   inserted := 'needs_reconciliation';
  ELSE inserted := 'older_or_identical'; END IF;
 END IF;
 UPDATE public.billing_events SET processing_status='processed',processed_at=now(),
  error_code=CASE WHEN inserted='needs_reconciliation' THEN 'ORDERING_RECONCILIATION_REQUIRED' ELSE NULL END
 WHERE provider=p_provider AND event_id=p_event_id;
 RETURN jsonb_build_object('duplicate',false,'stateApplied',coalesce(inserted='applied',false),'stateDisposition',coalesce(inserted,'none'));
END; $$;

CREATE VIEW public.fj_post_24h WITH (security_invoker=true) AS
 WITH candidates AS (
 SELECT p.id AS post_id,p.account_key,p.topic,p.tone,p.method,p.experiment_id,p.variant_key,p.published_at,
 s.collected_at,s.views,s.likes,s.replies,s.reposts,s.quotes,s.shares,
 extract(epoch FROM(s.collected_at-p.published_at))/3600 AS actual_age_hours,
 row_number() OVER(PARTITION BY p.id ORDER BY s.collected_at-p.published_at,s.id) AS rn
 FROM public.fortune_posts p JOIN public.post_metric_snapshots s ON s.post_id=p.id
 WHERE s.snapshot_kind='scheduled' AND s.target_age_hours=24
 AND s.collected_at>=p.published_at+interval '24 hours' AND s.collected_at<=p.published_at+interval '26 hours'
 ) SELECT *,CASE WHEN views>0 AND likes IS NOT NULL AND replies IS NOT NULL AND reposts IS NOT NULL AND quotes IS NOT NULL
 THEN 100.0*(likes::numeric+replies+reposts+quotes)/views ELSE NULL END AS engagement_pct
 FROM candidates WHERE rn=1;

CREATE VIEW public.fj_cash_events WITH (security_invoker=true) AS
 SELECT provider,event_id,user_id,provider_subscription_id,economic_key,occurred_at,event_type,
 currency,currency_exponent,billing_reason,
 CASE WHEN event_type='payment_succeeded' THEN amount_minor ELSE -amount_minor END AS signed_amount_minor
 FROM public.billing_events WHERE processing_status='processed' AND verified_at IS NOT NULL
 AND event_type IN ('payment_succeeded','refund_succeeded','chargeback');

CREATE VIEW public.fj_current_mrr WITH (security_invoker=true) AS
 SELECT currency,currency_exponent,count(*) AS subscriptions,
 sum(amount_minor::numeric/power(10::numeric,currency_exponent)/interval_months) AS mrr
 FROM public.subscriptions WHERE verified_at IS NOT NULL AND status='active' AND current_period_end>now()
 AND amount_minor IS NOT NULL AND currency IS NOT NULL AND currency_exponent IS NOT NULL AND interval_months IS NOT NULL
 GROUP BY currency,currency_exponent;
REVOKE ALL ON public.fj_post_24h,public.fj_cash_events,public.fj_current_mrr FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.fj_post_24h,public.fj_cash_events,public.fj_current_mrr TO service_role;

CREATE FUNCTION public.fj_cohort_report(p_from timestamptz,p_until timestamptz,p_asof timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE output jsonb;
BEGIN
 IF p_from IS NULL OR p_until IS NULL OR p_asof IS NULL OR p_until<=p_from OR p_until>p_asof OR
    p_from<p_asof-interval '90 days' OR p_asof>now()+interval '5 minutes' THEN RAISE EXCEPTION 'INVALID_COHORT_WINDOW'; END IF;
 WITH registrations AS (
  SELECT user_id,occurred_at,source_channel FROM public.funnel_events
  WHERE event_name='registration' AND occurred_at>=p_from AND occurred_at<p_until
 ), cohort AS (
  SELECT r.*,a.first_calculated_at,
   EXISTS(SELECT 1 FROM public.user_readings u WHERE u.user_id=r.user_id AND u.calculated_at>=a.first_calculated_at+interval '7 days'
    AND u.calculated_at<a.first_calculated_at+interval '8 days' AND u.calculated_at<=p_asof) AS d7,
   EXISTS(SELECT 1 FROM public.billing_events b WHERE b.user_id=r.user_id AND b.verified_at IS NOT NULL AND b.processing_status='processed'
    AND b.event_type='payment_succeeded' AND b.amount_minor>0 AND b.occurred_at>=r.occurred_at
    AND b.occurred_at<r.occurred_at+interval '35 days' AND b.occurred_at<=p_asof) AS paid35
  FROM registrations r JOIN public.user_access a ON a.user_id=r.user_id
 ), groups AS (
 SELECT source_channel,count(*) AS cohort_size,
 count(*) FILTER(WHERE occurred_at<=p_asof-interval '24 hours') AS activation_eligible,
 count(*) FILTER(WHERE occurred_at<=p_asof-interval '24 hours' AND first_calculated_at>=occurred_at AND first_calculated_at<occurred_at+interval '24 hours') AS activated,
 count(*) FILTER(WHERE first_calculated_at<=p_asof-interval '8 days') AS d7_eligible,
 count(*) FILTER(WHERE first_calculated_at<=p_asof-interval '8 days' AND d7) AS d7_returned,
 count(*) FILTER(WHERE occurred_at<=p_asof-interval '35 days') AS conversion_eligible,
 count(*) FILTER(WHERE occurred_at<=p_asof-interval '35 days' AND paid35) AS paid_35d
 FROM cohort GROUP BY source_channel
 ) SELECT jsonb_build_object('population','consented_near_signup_accounts_only','windowStart',p_from,'windowEnd',p_until,'asOf',p_asof,
 'rows',coalesce(jsonb_agg(to_jsonb(groups)||jsonb_build_object(
 'activation_24h_pct',100.0*activated/nullif(activation_eligible,0),
 'd7_exact_pct',100.0*d7_returned/nullif(d7_eligible,0),
 'paid_35d_pct',100.0*paid_35d/nullif(conversion_eligible,0))),'[]'::jsonb)) INTO output FROM groups;
 RETURN output;
END; $$;


CREATE FUNCTION public.fj_set_attribution(p_user_id uuid,p_channel text,p_evidence text,p_post_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE a public.user_access%ROWTYPE; exp text;
BEGIN
 IF p_channel IS NULL OR p_channel NOT IN ('threads','chatgpt','claude','direct','unknown') OR
 p_evidence IS NULL OR p_evidence NOT IN ('signed_link','self_reported','unknown') OR
 (p_evidence='signed_link' AND (p_post_id IS NULL OR p_channel<>'threads')) THEN RAISE EXCEPTION 'INVALID_ATTRIBUTION'; END IF;
 SELECT * INTO a FROM public.user_access WHERE user_id=p_user_id FOR UPDATE;
 IF NOT FOUND OR a.analytics_consent_at IS NULL THEN RETURN false; END IF;
 IF p_post_id IS NOT NULL THEN SELECT experiment_id INTO exp FROM public.fortune_posts WHERE id=p_post_id AND status='published';
 IF NOT FOUND THEN RAISE EXCEPTION 'ATTRIBUTION_POST_NOT_FOUND'; END IF; END IF;
 UPDATE public.funnel_events SET source_channel=p_channel,source_evidence=p_evidence,post_id=p_post_id,experiment_id=exp
 WHERE user_id=p_user_id AND event_name='registration' AND (source_channel='unknown' OR (p_evidence='signed_link' AND source_evidence<>'signed_link'));
 RETURN FOUND;
END; $$;

CREATE FUNCTION public.fj_revenue_report(p_from timestamptz,p_until timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE output jsonb;
BEGIN
 IF p_from IS NULL OR p_until IS NULL OR p_until<=p_from OR p_until>now()+interval '5 minutes' OR p_from<p_until-interval '400 days' THEN RAISE EXCEPTION 'INVALID_REPORT_WINDOW'; END IF;
 WITH sums AS (
 SELECT currency,currency_exponent,
 count(*) FILTER(WHERE event_type='payment_succeeded') AS payments,
 count(*) FILTER(WHERE event_type IN ('refund_succeeded','chargeback')) AS reversals,
 sum(signed_amount_minor)::text AS net_collected_minor
 FROM public.fj_cash_events WHERE occurred_at>=p_from AND occurred_at<p_until GROUP BY currency,currency_exponent
 ) SELECT jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(sums)),'[]'::jsonb),'measure','net_cash_collected_not_mrr_or_accounting_revenue') INTO output FROM sums;
 RETURN output;
END; $$;

DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname LIKE 'fj_%' LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',f.signature);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f.signature);
 END LOOP;
END; $$;

-- Endpoint snapshots, never sums. Each endpoint must be observed in the preceding 26 hours.
CREATE FUNCTION public.fj_follower_growth(p_account text,p_until timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE a public.account_metric_snapshots%ROWTYPE; b public.account_metric_snapshots%ROWTYPE;
BEGIN
 IF p_account IS NULL OR p_until IS NULL OR p_until>now()+interval '5 minutes' THEN RAISE EXCEPTION 'INVALID_GROWTH_WINDOW'; END IF;
 SELECT * INTO a FROM public.account_metric_snapshots WHERE account_key=p_account AND metric_name='followers_count'
 AND metric_value IS NOT NULL AND collected_at<=p_until-interval '7 days' AND collected_at>=p_until-interval '7 days 26 hours'
 ORDER BY collected_at DESC,id LIMIT 1;
 SELECT * INTO b FROM public.account_metric_snapshots WHERE account_key=p_account AND metric_name='followers_count'
 AND metric_value IS NOT NULL AND collected_at<=p_until AND collected_at>=p_until-interval '26 hours'
 ORDER BY collected_at DESC,id LIMIT 1;
 RETURN jsonb_build_object('account',p_account,'requestedEnd',p_until,'baselineAt',a.collected_at,'latestAt',b.collected_at,
 'baselineCount',a.metric_value,'latestCount',b.metric_value,'netGrowth',b.metric_value-a.metric_value,
 'actualDays',extract(epoch FROM (b.collected_at-a.collected_at))/86400.0,
 'complete',a.id IS NOT NULL AND b.id IS NOT NULL,'definition','endpoint_difference_with_26h_freshness_not_sum');
END; $$;
REVOKE ALL ON FUNCTION public.fj_follower_growth(text,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.fj_follower_growth(text,timestamptz) TO service_role;

CREATE FUNCTION public.fj_operation_report(p_from timestamptz,p_until timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE task_rows jsonb;cost_rows jsonb;
BEGIN
 IF p_from IS NULL OR p_until IS NULL OR p_until<=p_from OR p_until>now()+interval '5 minutes' OR p_from<p_until-interval '90 days' THEN RAISE EXCEPTION 'INVALID_OPERATION_WINDOW';END IF;
 WITH t AS (
 SELECT task,count(*) AS runs,count(*) FILTER(WHERE status='succeeded') AS succeeded,
 count(*) FILTER(WHERE status='failed') AS failed,count(*) FILTER(WHERE status='unknown') AS unknown,
 count(*) FILTER(WHERE status='running') AS running,count(*) FILTER(WHERE attempts>1) AS retried,
 count(*) FILTER(WHERE estimated_cost IS NOT NULL) AS cost_observed,
 avg(duration_ms) FILTER(WHERE duration_ms IS NOT NULL) AS mean_duration_ms
 FROM public.automation_runs WHERE started_at>=p_from AND started_at<p_until GROUP BY task
 ) SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) INTO task_rows FROM t;
 WITH c AS (
 SELECT cost_currency,cost_source,count(*) AS runs,sum(estimated_cost)::text AS recorded_cost
 FROM public.automation_runs WHERE started_at>=p_from AND started_at<p_until AND estimated_cost IS NOT NULL
 GROUP BY cost_currency,cost_source
 ) SELECT coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) INTO cost_rows FROM c;
 RETURN jsonb_build_object('tasks',task_rows,'costByCurrencyAndSource',cost_rows,
 'caveat','Missing cost is unobserved, not zero. Customer-host LLM costs are not observable.');
END; $$;
REVOKE ALL ON FUNCTION public.fj_operation_report(timestamptz,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.fj_operation_report(timestamptz,timestamptz) TO service_role;
COMMIT;
