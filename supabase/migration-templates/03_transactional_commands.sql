BEGIN;
ALTER TABLE public.user_access ADD COLUMN first_calculated_at timestamptz;

-- Critical operations are one transaction. Only the trusted backend can execute these functions.
CREATE FUNCTION public.fj_record_calculation(
 p_user_id uuid, p_request_id uuid, p_fingerprint text, p_feature text,
 p_algorithm text, p_target_date date, p_topic text DEFAULT NULL, p_client text DEFAULT 'unknown', p_collect_analytics boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
 a public.user_access%ROWTYPE; old public.user_readings%ROWTYPE;
 v_tier text; v_bucket text; v_start date; v_limit integer; v_used integer;
 v_id uuid; v_now timestamptz := now();
BEGIN
 IF p_user_id IS NULL OR p_request_id IS NULL OR p_target_date IS NULL OR
    p_fingerprint IS NULL OR p_fingerprint !~ '^[a-f0-9]{64}$' OR
    p_feature IS NULL OR p_feature NOT IN ('calculate_numerology','draw_tarot') OR
    p_algorithm IS NULL OR p_algorithm !~ '^[A-Za-z0-9_.:-]{1,80}$' OR
    (p_topic IS NOT NULL AND p_topic NOT IN ('love','work','money','general')) OR
    p_client IS NULL OR p_client NOT IN ('chatgpt','claude','unknown') THEN
  RAISE EXCEPTION 'INVALID_CALCULATION_METADATA';
 END IF;
 INSERT INTO public.user_access(user_id) VALUES (p_user_id) ON CONFLICT DO NOTHING;
 SELECT * INTO a FROM public.user_access WHERE user_id = p_user_id FOR UPDATE;
 IF a.suspended_at IS NOT NULL THEN RETURN jsonb_build_object('ok',false,'reason','ACCOUNT_SUSPENDED'); END IF;
 IF a.trial_started_at IS NULL THEN
  UPDATE public.user_access SET trial_started_at=v_now,trial_ends_at=v_now+interval '14 days' WHERE user_id=p_user_id RETURNING * INTO a;
 END IF;
 IF EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.user_id=p_user_id AND s.verified_at IS NOT NULL
   AND s.status IN ('active','trialing') AND s.current_period_end > v_now) THEN v_tier := 'premium';
 ELSIF a.trial_ends_at > v_now THEN v_tier := 'trial'; ELSE v_tier := 'free'; END IF;
 IF v_tier='free' AND p_feature='draw_tarot' THEN RETURN jsonb_build_object('ok',false,'reason','FEATURE_NOT_INCLUDED'); END IF;
 SELECT * INTO old FROM public.user_readings WHERE user_id=p_user_id AND request_id=p_request_id;
 IF FOUND THEN
  IF old.request_fingerprint<>p_fingerprint OR old.feature_key<>p_feature OR old.algorithm_version<>p_algorithm OR old.target_date<>p_target_date THEN
   RETURN jsonb_build_object('ok',false,'reason','IDEMPOTENCY_CONFLICT');
  END IF;
  RETURN jsonb_build_object('ok',true,'readingId',old.id,'tier',v_tier,'remainingAtCompletion',old.remaining_after,'replayed',true);
 END IF;
 v_limit := CASE v_tier WHEN 'free' THEN 3 WHEN 'trial' THEN 100 ELSE 200 END;
 v_bucket := CASE v_tier WHEN 'free' THEN 'free_week' WHEN 'trial' THEN 'trial_day' ELSE 'premium_day' END;
 v_start := CASE WHEN v_tier='free' THEN date_trunc('week',v_now AT TIME ZONE 'UTC')::date ELSE (v_now AT TIME ZONE 'UTC')::date END;
 INSERT INTO public.usage_counters(user_id,feature_key,quota_bucket,period_start,used_count)
 VALUES(p_user_id,p_feature,v_bucket,v_start,1)
 ON CONFLICT (user_id,feature_key,quota_bucket,period_start) DO UPDATE
 SET used_count=public.usage_counters.used_count+1,updated_at=v_now
 WHERE public.usage_counters.used_count<v_limit RETURNING used_count INTO v_used;
 IF v_used IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','USAGE_LIMIT_REACHED'); END IF;
 INSERT INTO public.user_readings(user_id,request_id,request_fingerprint,feature_key,algorithm_version,target_date,topic,tier_at_use,quota_bucket,quota_period_start,remaining_after)
 VALUES(p_user_id,p_request_id,p_fingerprint,p_feature,p_algorithm,p_target_date,
 CASE WHEN p_collect_analytics IS TRUE AND a.analytics_consent_at IS NOT NULL AND a.interest_consent_at IS NOT NULL THEN p_topic ELSE NULL END,
 v_tier,v_bucket,v_start,v_limit-v_used) RETURNING id INTO v_id;
 UPDATE public.user_access SET first_calculated_at=coalesce(first_calculated_at,v_now) WHERE user_id=p_user_id;
 IF p_collect_analytics IS TRUE AND a.analytics_consent_at IS NOT NULL THEN
  INSERT INTO public.funnel_events(user_id,event_name,dedupe_key,occurred_at,observation,reading_id,source_channel,source_evidence)
  VALUES(p_user_id,'reading_completed','reading:'||v_id,v_now,'server',v_id,p_client,
   CASE WHEN p_client='unknown' THEN 'unknown' ELSE 'registered_client' END);
 END IF;
 RETURN jsonb_build_object('ok',true,'readingId',v_id,'tier',v_tier,'remainingAtCompletion',v_limit-v_used,'replayed',false);
END; $$;

CREATE FUNCTION public.fj_set_privacy(p_user_id uuid,p_analytics boolean,p_interests boolean,p_version text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE a public.user_access%ROWTYPE; registered timestamptz;
BEGIN
 IF p_user_id IS NULL OR p_analytics IS NULL OR p_interests IS NULL OR p_version<>'2026-10-v2' OR p_version IS NULL OR (p_interests AND NOT p_analytics) THEN
  RAISE EXCEPTION 'INVALID_PRIVACY_CHOICE'; END IF;
 INSERT INTO public.user_access(user_id) VALUES(p_user_id) ON CONFLICT DO NOTHING;
 SELECT * INTO a FROM public.user_access WHERE user_id=p_user_id FOR UPDATE;
 IF NOT p_analytics THEN
  DELETE FROM public.funnel_events WHERE user_id=p_user_id;
  DELETE FROM public.reading_feedback WHERE user_id=p_user_id;
  UPDATE public.user_readings SET topic=NULL WHERE user_id=p_user_id;
 ELSIF a.analytics_consent_at IS NULL THEN
  INSERT INTO public.funnel_events(user_id,event_name,dedupe_key,occurred_at,observation)
   VALUES(p_user_id,'analytics_enrolled','enrollment',now(),'server') ON CONFLICT DO NOTHING;
  SELECT created_at INTO registered FROM auth.users WHERE id=p_user_id;
  -- Only near-signup opt-ins with no previous observed calculation enter signup cohorts.
  -- Older opt-ins are enrollment cohorts, not retroactively fabricated registrations.
  IF registered >= now()-interval '24 hours' AND a.first_calculated_at IS NULL AND NOT EXISTS(SELECT 1 FROM public.usage_counters WHERE user_id=p_user_id AND used_count>0) THEN
   INSERT INTO public.funnel_events(user_id,event_name,dedupe_key,occurred_at,observation)
    VALUES(p_user_id,'registration','registration',registered,'server') ON CONFLICT DO NOTHING;
  END IF;
 END IF;
 IF NOT p_interests THEN UPDATE public.user_readings SET topic=NULL WHERE user_id=p_user_id; END IF;
 UPDATE public.user_access SET
  analytics_consent_at=CASE WHEN p_analytics THEN coalesce(a.analytics_consent_at,now()) ELSE NULL END,
  interest_consent_at=CASE WHEN p_interests THEN coalesce(a.interest_consent_at,now()) ELSE NULL END,
  consent_version=p_version,consent_updated_at=now(),
  analytics_revoked_at=CASE WHEN NOT p_analytics THEN now() ELSE a.analytics_revoked_at END
 WHERE user_id=p_user_id;
 RETURN jsonb_build_object('analytics',p_analytics,'interests',p_interests,'version',p_version);
END; $$;

CREATE FUNCTION public.fj_record_funnel(
 p_user_id uuid,p_event text,p_dedupe_key text,p_channel text DEFAULT 'unknown',
 p_evidence text DEFAULT 'unknown',p_reading_id uuid DEFAULT NULL,p_post_id uuid DEFAULT NULL
) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE a public.user_access%ROWTYPE; exp text;
BEGIN
 IF p_user_id IS NULL OR p_dedupe_key IS NULL OR char_length(p_dedupe_key) NOT BETWEEN 1 AND 160 OR
    p_event IS NULL OR p_event NOT IN ('mcp_connected','journal_save_reported','life_log_reported','review_reported') OR
    p_channel IS NULL OR p_channel NOT IN ('threads','chatgpt','claude','direct','unknown') OR
    p_evidence IS NULL OR p_evidence NOT IN ('signed_link','self_reported','registered_client','unknown') THEN
  RAISE EXCEPTION 'INVALID_FUNNEL_EVENT'; END IF;
 SELECT * INTO a FROM public.user_access WHERE user_id=p_user_id FOR UPDATE;
 IF NOT FOUND OR a.analytics_consent_at IS NULL OR a.suspended_at IS NOT NULL THEN RETURN false; END IF;
 IF p_post_id IS NOT NULL THEN
  SELECT experiment_id INTO exp FROM public.fortune_posts WHERE id=p_post_id AND status='published';
  IF NOT FOUND THEN RAISE EXCEPTION 'ATTRIBUTION_POST_NOT_FOUND'; END IF;
 END IF;
 IF p_reading_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.user_readings WHERE id=p_reading_id AND user_id=p_user_id) THEN
  RAISE EXCEPTION 'READING_NOT_FOUND'; END IF;
 INSERT INTO public.funnel_events(user_id,event_name,dedupe_key,occurred_at,observation,source_channel,source_evidence,reading_id,post_id,experiment_id)
 VALUES(p_user_id,p_event,p_dedupe_key,now(),CASE WHEN p_event='mcp_connected' THEN 'server' ELSE 'self_reported' END,
 p_channel,p_evidence,p_reading_id,p_post_id,exp) ON CONFLICT(user_id,dedupe_key) DO NOTHING;
 -- The client used is NOT evidence of acquisition. Do not rewrite signup attribution here.
 RETURN true;
END; $$;

CREATE FUNCTION public.fj_submit_feedback(p_user_id uuid,p_reading_id uuid,p_usefulness smallint,p_match text,p_followup date DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE a public.user_access%ROWTYPE;
BEGIN
 IF p_usefulness IS NULL OR p_usefulness NOT BETWEEN 1 AND 5 OR p_match IS NULL OR p_match NOT IN ('not_assessed','matched','mixed','not_matched','unclear') THEN
  RAISE EXCEPTION 'INVALID_FEEDBACK'; END IF;
 SELECT * INTO a FROM public.user_access WHERE user_id=p_user_id FOR UPDATE;
 IF NOT FOUND OR a.analytics_consent_at IS NULL OR a.suspended_at IS NOT NULL THEN RETURN false; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.user_readings WHERE id=p_reading_id AND user_id=p_user_id) THEN RAISE EXCEPTION 'READING_NOT_FOUND'; END IF;
 INSERT INTO public.reading_feedback(user_id,reading_id,usefulness,match_assessment,followup_date)
 VALUES(p_user_id,p_reading_id,p_usefulness,p_match,p_followup)
 ON CONFLICT(user_id,reading_id) DO UPDATE SET usefulness=excluded.usefulness,match_assessment=excluded.match_assessment,
 followup_date=excluded.followup_date,updated_at=now();
 RETURN true;
END; $$;

CREATE FUNCTION public.fj_begin_run(p_task text,p_key text,p_actor text,p_post_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE r public.automation_runs%ROWTYPE; new_id uuid;
BEGIN
 INSERT INTO public.automation_runs(task,idempotency_key,actor_kind,post_id) VALUES(p_task,p_key,p_actor,p_post_id)
 ON CONFLICT(task,idempotency_key) DO NOTHING RETURNING id INTO new_id;
 SELECT * INTO r FROM public.automation_runs WHERE task=p_task AND idempotency_key=p_key FOR UPDATE;
 IF r.post_id IS DISTINCT FROM p_post_id THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT'; END IF;
 IF new_id IS NOT NULL THEN RETURN jsonb_build_object('acquired',true,'runId',r.id,'attempt',r.attempts); END IF;
 IF r.status='running' AND r.lease_expires_at<=now() AND p_task='publish_post' THEN
  UPDATE public.automation_runs SET status='unknown',finished_at=now(),error_code='LEASE_EXPIRED' WHERE id=r.id;
  UPDATE public.fortune_posts SET status='publish_unknown' WHERE id=p_post_id AND status='publishing';
  RETURN jsonb_build_object('acquired',false,'runId',r.id,'status','unknown');
 END IF;
 IF p_task<>'publish_post' AND r.attempts<3 AND (r.status='failed' OR (r.status='running' AND r.lease_expires_at<=now())) THEN
  UPDATE public.automation_runs SET status='running',attempts=attempts+1,started_at=now(),finished_at=NULL,
   lease_expires_at=now()+interval '2 minutes',error_code=NULL WHERE id=r.id RETURNING * INTO r;
  RETURN jsonb_build_object('acquired',true,'runId',r.id,'attempt',r.attempts);
 END IF;
 RETURN jsonb_build_object('acquired',false,'runId',r.id,'status',r.status);
END; $$;

CREATE FUNCTION public.fj_finish_run(p_run_id uuid,p_attempt integer,p_success boolean,p_error text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
 UPDATE public.automation_runs SET status=CASE WHEN p_success THEN 'succeeded' ELSE 'failed' END,
  finished_at=now(),duration_ms=greatest(0,extract(epoch FROM(now()-started_at))*1000)::bigint,
  error_code=CASE WHEN p_success THEN NULL ELSE p_error END
 WHERE id=p_run_id AND attempts=p_attempt AND status='running' AND task<>'publish_post';
 RETURN FOUND;
END; $$;

CREATE FUNCTION public.fj_approve_post(p_id uuid,p_hash text) RETURNS boolean
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
 UPDATE public.fortune_posts SET status='approved',approved_at=now(),approved_body_sha256=p_hash
 WHERE id=p_id AND body_sha256=p_hash AND status IN ('draft','approved') AND char_length(body)<=500;
 RETURN FOUND;
END; $$;

CREATE FUNCTION public.fj_claim_publish(p_post_id uuid,p_expected_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE p public.fortune_posts%ROWTYPE; r jsonb;
BEGIN
 SELECT * INTO p FROM public.fortune_posts WHERE id=p_post_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'POST_NOT_FOUND'; END IF;
 IF p.status IN ('publishing','publish_unknown','published') THEN
  RETURN jsonb_build_object('acquired',false,'status',p.status); END IF;
 IF p_expected_hash IS NULL OR p_expected_hash IS DISTINCT FROM p.body_sha256 OR p.status<>'approved' OR p.approved_body_sha256<>p.body_sha256 OR (p.scheduled_at IS NOT NULL AND p.scheduled_at>now()) THEN
  RAISE EXCEPTION 'POST_NOT_APPROVED_OR_NOT_DUE'; END IF;
 r := public.fj_begin_run('publish_post','publish:'||p.id,'owner_agent',p.id);
 IF (r->>'acquired')::boolean THEN UPDATE public.fortune_posts SET status='publishing' WHERE id=p.id; END IF;
 RETURN r;
END; $$;

CREATE FUNCTION public.fj_finish_publish(p_post_id uuid,p_run_id uuid,p_external_id text,p_container_id text,p_error text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE r public.automation_runs%ROWTYPE;
BEGIN
 -- Same lock order as claim: post then run.
 PERFORM 1 FROM public.fortune_posts WHERE id=p_post_id FOR UPDATE;
 SELECT * INTO r FROM public.automation_runs WHERE id=p_run_id AND post_id=p_post_id AND task='publish_post' FOR UPDATE;
 IF NOT FOUND OR r.status NOT IN ('running','unknown') THEN RETURN false; END IF;
 UPDATE public.fortune_posts SET status=CASE WHEN p_external_id IS NULL THEN 'publish_unknown' ELSE 'published' END,
  external_post_id=p_external_id,container_id=coalesce(p_container_id,container_id),
  published_at=CASE WHEN p_external_id IS NULL THEN NULL ELSE now() END WHERE id=p_post_id;
 UPDATE public.automation_runs SET status=CASE WHEN p_external_id IS NULL THEN 'unknown' ELSE 'succeeded' END,
 finished_at=now(),duration_ms=greatest(0,extract(epoch FROM(now()-started_at))*1000)::bigint,error_code=p_error WHERE id=p_run_id;
 RETURN true;
END; $$;

-- Close the nullable-limit bypass in the legacy RPC. Its caller remains backend-only.
CREATE OR REPLACE FUNCTION public.consume_usage(p_user_id uuid,p_feature_key text,p_quota_bucket text,p_period_start date,p_limit integer)
RETURNS TABLE(allowed boolean,used_count integer) LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE n integer;
BEGIN
 IF p_user_id IS NULL OR p_period_start IS NULL OR p_feature_key IS NULL OR p_quota_bucket IS NULL OR p_limit IS NULL OR
    p_feature_key NOT IN ('calculate_numerology','draw_tarot') OR p_quota_bucket NOT IN ('free_week','trial_day','premium_day') OR p_limit NOT BETWEEN 1 AND 10000 THEN
  RAISE EXCEPTION 'INVALID_QUOTA_REQUEST'; END IF;
 INSERT INTO public.usage_counters(user_id,feature_key,quota_bucket,period_start,used_count) VALUES(p_user_id,p_feature_key,p_quota_bucket,p_period_start,1)
 ON CONFLICT(user_id,feature_key,quota_bucket,period_start) DO UPDATE SET used_count=public.usage_counters.used_count+1,updated_at=now()
 WHERE public.usage_counters.used_count<p_limit RETURNING public.usage_counters.used_count INTO n;
 IF n IS NOT NULL THEN RETURN QUERY SELECT true,n; ELSE
  SELECT c.used_count INTO n FROM public.usage_counters c WHERE c.user_id=p_user_id AND c.feature_key=p_feature_key AND c.quota_bucket=p_quota_bucket AND c.period_start=p_period_start;
  RETURN QUERY SELECT false,coalesce(n,0); END IF;
END; $$;

DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND (p.proname LIKE 'fj_%' OR p.proname='consume_usage') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',f.signature);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',f.signature);
 END LOOP;
END; $$;
COMMIT;
