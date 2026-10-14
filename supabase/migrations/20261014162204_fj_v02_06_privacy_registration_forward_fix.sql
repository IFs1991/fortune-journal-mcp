-- Forward fix for 20261014160922_fj_v02_03_transactional_commands.sql (never edited in place).
-- Defect: fj_set_privacy read auth.users.created_at while running as service_role (SECURITY INVOKER).
-- Supabase does not grant service_role SELECT on auth.users, so every first analytics opt-in failed.
-- Fix: the trusted backend passes the registration time it read from the verified Supabase Auth user.
-- NULL registration time records no signup-cohort event (never fabricated). Invoker rights only; no auth schema grants.
BEGIN;
DROP FUNCTION public.fj_set_privacy(uuid,boolean,boolean,text);
CREATE FUNCTION public.fj_set_privacy(p_user_id uuid,p_analytics boolean,p_interests boolean,p_version text,p_registered_at timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE a public.user_access%ROWTYPE;
BEGIN
 IF p_user_id IS NULL OR p_analytics IS NULL OR p_interests IS NULL OR p_version IS NULL OR p_version<>'2026-10-v2' OR (p_interests AND NOT p_analytics)
    OR p_registered_at>now()+interval '5 minutes' THEN
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
  -- Only near-signup opt-ins with no previous observed calculation enter signup cohorts.
  -- Older opt-ins are enrollment cohorts, not retroactively fabricated registrations.
  IF p_registered_at IS NOT NULL AND p_registered_at>=now()-interval '24 hours' AND a.first_calculated_at IS NULL
     AND NOT EXISTS(SELECT 1 FROM public.usage_counters WHERE user_id=p_user_id AND used_count>0) THEN
   INSERT INTO public.funnel_events(user_id,event_name,dedupe_key,occurred_at,observation)
    VALUES(p_user_id,'registration','registration',p_registered_at,'server') ON CONFLICT DO NOTHING;
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
REVOKE ALL ON FUNCTION public.fj_set_privacy(uuid,boolean,boolean,text,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fj_set_privacy(uuid,boolean,boolean,text,timestamptz) TO service_role;
COMMIT;
