BEGIN;
-- Forward fix 08 (MCP round trips). Applied migrations are not edited.
-- 1. draw_tarot: the app used to read user_readings for the original draw date before calling
--    fj_record_calculation (2 PostgREST calls). The replay lookup now happens here, so one call suffices.
--    Tarot is not keyed to a calendar date: an identical retry replays regardless of p_target_date and
--    keeps the original row. Numerology replays still require the same target date.
-- 2. An identical retry of an existing reading is checked before the tier gate, so a retry made after the
--    trial ended replays the already-delivered result (no new usage, no new draw). Suspension still wins,
--    and a new tarot draw on Free is still FEATURE_NOT_INCLUDED.
-- Everything else (validation, locking order, trial start, tier, quota, ledger, consent) is unchanged from 03.
CREATE OR REPLACE FUNCTION public.fj_record_calculation(
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
 SELECT * INTO old FROM public.user_readings WHERE user_id=p_user_id AND request_id=p_request_id;
 IF FOUND THEN
  IF old.request_fingerprint<>p_fingerprint OR old.feature_key<>p_feature OR old.algorithm_version<>p_algorithm OR
     (p_feature<>'draw_tarot' AND old.target_date<>p_target_date) THEN
   RETURN jsonb_build_object('ok',false,'reason','IDEMPOTENCY_CONFLICT');
  END IF;
  RETURN jsonb_build_object('ok',true,'readingId',old.id,'tier',v_tier,'remainingAtCompletion',old.remaining_after,'replayed',true);
 END IF;
 IF v_tier='free' AND p_feature='draw_tarot' THEN RETURN jsonb_build_object('ok',false,'reason','FEATURE_NOT_INCLUDED'); END IF;
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

-- 3. get_access_status: one read-only call returns exactly the rows memberTier() used to read with two
--    queries. The tier is still resolved by resolveEntitlement() in TypeScript, so policy is not duplicated.
--    Billing identifiers (customer/subscription IDs, amounts) are not returned.
CREATE FUNCTION public.fj_access_snapshot(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
BEGIN
 IF p_user_id IS NULL THEN RAISE EXCEPTION 'INVALID_USER'; END IF;
 RETURN jsonb_build_object(
  'access',(SELECT jsonb_build_object('trial_ends_at',a.trial_ends_at,'suspended_at',a.suspended_at)
            FROM public.user_access a WHERE a.user_id=p_user_id),
  'subscriptions',coalesce((SELECT jsonb_agg(jsonb_build_object('status',s.status,'current_period_end',s.current_period_end,'verified_at',s.verified_at))
            FROM public.subscriptions s WHERE s.user_id=p_user_id),'[]'::jsonb));
END; $$;
REVOKE ALL ON FUNCTION public.fj_access_snapshot(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fj_access_snapshot(uuid) TO service_role;
COMMIT;
