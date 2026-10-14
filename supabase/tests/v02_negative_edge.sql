-- Disposable database only. Rolls back. Covers anon / user A / user B / service_role negative paths,
-- atomic rollback, billing edge cases, retention, FK deletion and KPI denominators.
BEGIN;
INSERT INTO auth.users(id) VALUES('a0000000-0000-4000-8000-00000000000a'),('b0000000-0000-4000-8000-00000000000b');
SET LOCAL ROLE service_role;
SELECT public.fj_set_privacy('a0000000-0000-4000-8000-00000000000a',true,true,'2026-10-v2');
SELECT public.fj_record_calculation('a0000000-0000-4000-8000-00000000000a','a1111111-1111-4111-8111-111111111111',repeat('a',64),'calculate_numerology','test-v1',current_date,'love','unknown',true);
SELECT public.fj_record_calculation('b0000000-0000-4000-8000-00000000000b','b1111111-1111-4111-8111-111111111111',repeat('b',64),'calculate_numerology','test-v1',current_date,NULL,'unknown',false);
INSERT INTO public.subscriptions(user_id,provider,provider_customer_id,provider_subscription_id,status,current_period_end)
 VALUES('b0000000-0000-4000-8000-00000000000b','test_provider','cust_b','sub_b','active',now()+interval '30 days');
RESET ROLE;

-- ===== User A (authenticated) cannot see or mutate B, nor escalate self =====
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','a0000000-0000-4000-8000-00000000000a',true);
DO $$ BEGIN
 IF (SELECT count(*) FROM public.user_access)<>1 OR EXISTS(SELECT 1 FROM public.user_access WHERE user_id<>'a0000000-0000-4000-8000-00000000000a') THEN RAISE EXCEPTION 'A sees other user_access';END IF;
 IF EXISTS(SELECT 1 FROM public.subscriptions) THEN RAISE EXCEPTION 'A sees B subscription';END IF;
 IF EXISTS(SELECT 1 FROM public.usage_counters WHERE user_id<>'a0000000-0000-4000-8000-00000000000a') THEN RAISE EXCEPTION 'A sees B counters';END IF;
 IF EXISTS(SELECT 1 FROM public.user_readings WHERE user_id<>'a0000000-0000-4000-8000-00000000000a') THEN RAISE EXCEPTION 'A sees B readings';END IF;
 BEGIN INSERT INTO public.usage_counters(user_id,feature_key,quota_bucket,period_start,used_count) VALUES('a0000000-0000-4000-8000-00000000000a','calculate_numerology','premium_day',current_date,0);RAISE EXCEPTION 'A can insert counters';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN UPDATE public.usage_counters SET used_count=0;RAISE EXCEPTION 'A can reset quota';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN DELETE FROM public.usage_counters;RAISE EXCEPTION 'A can delete quota';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN INSERT INTO public.subscriptions(user_id,provider,provider_customer_id,provider_subscription_id,status,current_period_end,verified_at) VALUES('a0000000-0000-4000-8000-00000000000a','self','c','s','active',now()+interval '1 year',now());RAISE EXCEPTION 'A can self-grant premium';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN UPDATE public.user_access SET trial_started_at=NULL,trial_ends_at=NULL;RAISE EXCEPTION 'A can reset trial';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN UPDATE public.user_access SET suspended_at=NULL;RAISE EXCEPTION 'A can unsuspend';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN INSERT INTO public.user_readings(user_id,request_id,request_fingerprint,feature_key,algorithm_version,target_date,tier_at_use,quota_bucket,quota_period_start,remaining_after) VALUES('a0000000-0000-4000-8000-00000000000a',gen_random_uuid(),repeat('e',64),'draw_tarot','x',current_date,'premium','premium_day',current_date,0);RAISE EXCEPTION 'A can forge readings';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN INSERT INTO public.reading_feedback(user_id,reading_id,usefulness,match_assessment) SELECT user_id,id,5,'matched' FROM public.user_readings LIMIT 1;RAISE EXCEPTION 'A bypasses consent RPC';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN INSERT INTO public.funnel_events(user_id,event_name,dedupe_key,occurred_at,observation) VALUES('a0000000-0000-4000-8000-00000000000a','registration','x',now(),'server');RAISE EXCEPTION 'A forges funnel';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM 1 FROM public.billing_events;RAISE EXCEPTION 'A reads billing events';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM 1 FROM public.automation_runs;RAISE EXCEPTION 'A reads ops runs';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM 1 FROM public.fj_current_mrr;RAISE EXCEPTION 'A reads MRR view';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM 1 FROM public.fj_cash_events;RAISE EXCEPTION 'A reads cash view';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM 1 FROM public.fj_post_24h;RAISE EXCEPTION 'A reads post view';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.fj_record_calculation('a0000000-0000-4000-8000-00000000000a',gen_random_uuid(),repeat('f',64),'calculate_numerology','x',current_date);RAISE EXCEPTION 'A calls quota RPC';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.fj_apply_billing('test_provider','e',jsonb_build_object('event_type','subscription_updated'));RAISE EXCEPTION 'A calls billing RPC';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.fj_set_privacy('b0000000-0000-4000-8000-00000000000b',true,true,'2026-10-v2');RAISE EXCEPTION 'A changes B consent';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.consume_usage('a0000000-0000-4000-8000-00000000000a','calculate_numerology','premium_day',current_date,10000);RAISE EXCEPTION 'A calls legacy quota RPC';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END; $$;
RESET ROLE;

-- ===== anon sees nothing and calls nothing =====
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['user_access','subscriptions','usage_counters','billing_events','fortune_posts','post_metric_snapshots','account_metric_snapshots','automation_runs','user_readings','funnel_events','reading_feedback','fj_post_24h','fj_cash_events','fj_current_mrr'] LOOP
  BEGIN EXECUTE format('SELECT 1 FROM public.%I LIMIT 1',t);RAISE EXCEPTION 'anon reads %',t;EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 END LOOP;
 BEGIN PERFORM public.fj_purge_expired();RAISE EXCEPTION 'anon purges';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
END; $$;
RESET ROLE;

-- ===== Atomicity: a failure after the counter increment rolls back the whole RPC =====
CREATE FUNCTION pg_temp.fail_reading() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'INJECTED_FAILURE';END;$$;
CREATE TRIGGER fj_test_fail BEFORE INSERT ON public.user_readings FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_reading();
SET LOCAL ROLE service_role;
DO $$ DECLARE before_count bigint; BEGIN
 SELECT coalesce(sum(used_count),0) INTO before_count FROM public.usage_counters WHERE user_id='a0000000-0000-4000-8000-00000000000a';
 BEGIN PERFORM public.fj_record_calculation('a0000000-0000-4000-8000-00000000000a','a2222222-2222-4222-8222-222222222222',repeat('a',64),'calculate_numerology','test-v1',current_date);
  RAISE EXCEPTION 'injected failure not raised';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INJECTED_FAILURE' THEN RAISE; END IF; END;
 IF (SELECT coalesce(sum(used_count),0) FROM public.usage_counters WHERE user_id='a0000000-0000-4000-8000-00000000000a')<>before_count THEN RAISE EXCEPTION 'quota consumed without a reading';END IF;
END; $$;
RESET ROLE;
DROP TRIGGER fj_test_fail ON public.user_readings;

-- ===== Entitlements: unverified/expired subscriptions never grant Premium; trial is server-side =====
SET LOCAL ROLE service_role;
DO $$ DECLARE r jsonb; BEGIN
 -- B has an ACTIVE but UNVERIFIED subscription (v0.1-style or client-forged): still trial, not premium.
 r:=public.fj_record_calculation('b0000000-0000-4000-8000-00000000000b','b2222222-2222-4222-8222-222222222222',repeat('b',64),'draw_tarot','test-v1',current_date);
 IF r->>'tier'<>'trial' THEN RAISE EXCEPTION 'unverified subscription granted %',r->>'tier';END IF;
 UPDATE public.subscriptions SET verified_at=now(),current_period_end=now()-interval '1 second' WHERE provider_subscription_id='sub_b';
 r:=public.fj_record_calculation('b0000000-0000-4000-8000-00000000000b','b3333333-3333-4333-8333-333333333333',repeat('b',64),'draw_tarot','test-v1',current_date);
 IF r->>'tier'<>'trial' THEN RAISE EXCEPTION 'expired subscription granted %',r->>'tier';END IF;
 UPDATE public.subscriptions SET current_period_end=now()+interval '1 day' WHERE provider_subscription_id='sub_b';
 r:=public.fj_record_calculation('b0000000-0000-4000-8000-00000000000b','b4444444-4444-4444-8444-444444444444',repeat('b',64),'draw_tarot','test-v1',current_date);
 IF r->>'tier'<>'premium' OR (r->>'remainingAtCompletion')::int<>199 THEN RAISE EXCEPTION 'verified premium not applied: %',r;END IF;
 -- Trial expiry falls back to Free: tarot denied, numerology allowed 3/week.
 UPDATE public.subscriptions SET status='canceled' WHERE provider_subscription_id='sub_b';
 UPDATE public.user_access SET trial_started_at=now()-interval '15 days',trial_ends_at=now()-interval '1 day' WHERE user_id='b0000000-0000-4000-8000-00000000000b';
 r:=public.fj_record_calculation('b0000000-0000-4000-8000-00000000000b','b5555555-5555-4555-8555-555555555555',repeat('b',64),'draw_tarot','test-v1',current_date);
 IF r->>'reason'<>'FEATURE_NOT_INCLUDED' THEN RAISE EXCEPTION 'free user drew tarot: %',r;END IF;
 r:=public.fj_record_calculation('b0000000-0000-4000-8000-00000000000b','b6666666-6666-4666-8666-666666666666',repeat('b',64),'calculate_numerology','test-v1',current_date);
 IF r->>'tier'<>'free' OR (r->>'remainingAtCompletion')::int<>2 THEN RAISE EXCEPTION 'free quota wrong: %',r;END IF;
 -- Invalid metadata is rejected before any write.
 BEGIN PERFORM public.fj_record_calculation('b0000000-0000-4000-8000-00000000000b',gen_random_uuid(),'not-a-hash','calculate_numerology','test-v1',current_date);RAISE EXCEPTION 'bad fingerprint accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVALID_CALCULATION_METADATA' THEN RAISE;END IF;END;
 BEGIN PERFORM public.fj_record_calculation('b0000000-0000-4000-8000-00000000000b',gen_random_uuid(),repeat('b',64),'calculate_numerology','test-v1',current_date,'health');RAISE EXCEPTION 'unknown topic accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVALID_CALCULATION_METADATA' THEN RAISE;END IF;END;
 -- Topic is NOT stored without separate interest consent (B never consented).
 IF EXISTS(SELECT 1 FROM public.user_readings WHERE user_id='b0000000-0000-4000-8000-00000000000b' AND topic IS NOT NULL) THEN RAISE EXCEPTION 'topic stored without consent';END IF;
 -- Feedback without analytics consent is refused (returns false, no row).
 IF public.fj_submit_feedback('b0000000-0000-4000-8000-00000000000b',(SELECT id FROM public.user_readings WHERE user_id='b0000000-0000-4000-8000-00000000000b' LIMIT 1),4::smallint,'mixed') THEN RAISE EXCEPTION 'feedback without consent';END IF;
 -- A cannot attach feedback to B's reading even via the RPC.
 BEGIN PERFORM public.fj_submit_feedback('a0000000-0000-4000-8000-00000000000a',(SELECT id FROM public.user_readings WHERE user_id='b0000000-0000-4000-8000-00000000000b' LIMIT 1),4::smallint,'mixed');RAISE EXCEPTION 'cross-user feedback via RPC';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'READING_NOT_FOUND' THEN RAISE;END IF;END;
END; $$;
RESET ROLE;

-- ===== Billing: multi-currency, conflicts, unbound and malformed events =====
SET LOCAL ROLE service_role;
DO $$ DECLARE e jsonb; r jsonb; BEGIN
 UPDATE public.subscriptions SET status='incomplete',verified_at=NULL,provider_updated_at=NULL WHERE provider_subscription_id='sub_b';
 e:=jsonb_build_object('event_type','payment_succeeded','provider_subscription_id','sub_b','occurred_at',now(),'economic_key','charge:jpy1','amount_minor',500,'currency','JPY','currency_exponent',0,'billing_reason','initial',
  'subscription',jsonb_build_object('status','active','provider_updated_at',now(),'current_period_end',now()+interval '30 days','amount_minor',500,'currency','JPY','currency_exponent',0,'interval_months',1));
 r:=public.fj_apply_billing('test_provider','evt_jpy1',e);
 e:=jsonb_build_object('event_type','payment_succeeded','provider_subscription_id','sub_b','occurred_at',now(),'economic_key','charge:usd1','amount_minor',499,'currency','USD','currency_exponent',2,'billing_reason','recurring');
 r:=public.fj_apply_billing('test_provider','evt_usd1',e);
 IF (SELECT count(DISTINCT currency) FROM public.fj_cash_events WHERE provider='test_provider')<>2 THEN RAISE EXCEPTION 'currencies merged';END IF;
 IF (SELECT sum(signed_amount_minor) FROM public.fj_cash_events WHERE provider='test_provider' AND currency='JPY')<>500 THEN RAISE EXCEPTION 'JPY cash wrong';END IF;
 r:=public.fj_revenue_report(now()-interval '1 day',now()+interval '1 minute');
 IF jsonb_array_length(r->'rows')<>2 THEN RAISE EXCEPTION 'revenue report merged currencies: %',r;END IF;
 -- Same event id, different amount: conflict, not silently accepted.
 BEGIN PERFORM public.fj_apply_billing('test_provider','evt_usd1',e||jsonb_build_object('amount_minor',1));RAISE EXCEPTION 'conflicting replay accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'BILLING_IDEMPOTENCY_CONFLICT' THEN RAISE;END IF;END;
 -- Unknown subscription (no server-created binding) is refused: no user id from provider metadata.
 BEGIN PERFORM public.fj_apply_billing('test_provider','evt_x',e||jsonb_build_object('provider_subscription_id','sub_unknown','economic_key','charge:x'));RAISE EXCEPTION 'unbound event accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'BILLING_BINDING_REQUIRED' THEN RAISE;END IF;END;
 -- Non-financial event carrying money, future-dated events, and cash without currency are refused.
 BEGIN PERFORM public.fj_apply_billing('test_provider','evt_y',jsonb_build_object('event_type','subscription_updated','provider_subscription_id','sub_b','occurred_at',now(),'amount_minor',5));RAISE EXCEPTION 'amount on non-cash event';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'NON_FINANCIAL_AMOUNT' THEN RAISE;END IF;END;
 BEGIN PERFORM public.fj_apply_billing('test_provider','evt_z',jsonb_build_object('event_type','subscription_updated','provider_subscription_id','sub_b','occurred_at',now()+interval '1 hour'));RAISE EXCEPTION 'future event accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVALID_BILLING_EVENT' THEN RAISE;END IF;END;
 BEGIN PERFORM public.fj_apply_billing('test_provider','evt_w',jsonb_build_object('event_type','payment_succeeded','provider_subscription_id','sub_b','occurred_at',now(),'economic_key','charge:w','amount_minor',5));RAISE EXCEPTION 'cash without currency';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVALID_FINANCIAL_FIELDS' THEN RAISE;END IF;END;
 -- A chargeback reduces cash but never touches entitlement by itself.
 r:=public.fj_apply_billing('test_provider','evt_cb',jsonb_build_object('event_type','chargeback','provider_subscription_id','sub_b','occurred_at',now(),'economic_key','cb:usd1','original_payment_key','charge:usd1','amount_minor',499,'currency','USD','currency_exponent',2,'billing_reason','not_applicable'));
 IF (SELECT sum(signed_amount_minor) FROM public.fj_cash_events WHERE provider='test_provider' AND currency='USD')<>0 THEN RAISE EXCEPTION 'chargeback not netted';END IF;
 IF (SELECT status FROM public.subscriptions WHERE provider_subscription_id='sub_b')<>'active' THEN RAISE EXCEPTION 'cash event changed entitlement';END IF;
END; $$;
RESET ROLE;

-- ===== Retention: 90-day ledger purge cascades feedback/linked events; recent rows survive =====
SET LOCAL ROLE service_role;
DO $$ DECLARE old_id uuid; new_id uuid; BEGIN
 SELECT id INTO new_id FROM public.user_readings WHERE user_id='a0000000-0000-4000-8000-00000000000a' LIMIT 1;
 INSERT INTO public.user_readings(user_id,request_id,request_fingerprint,feature_key,algorithm_version,target_date,tier_at_use,quota_bucket,quota_period_start,remaining_after,calculated_at)
  VALUES('a0000000-0000-4000-8000-00000000000a',gen_random_uuid(),repeat('9',64),'calculate_numerology','test-v1',current_date-91,'trial','trial_day',current_date-91,99,now()-interval '91 days') RETURNING id INTO old_id;
 PERFORM public.fj_submit_feedback('a0000000-0000-4000-8000-00000000000a',old_id,3::smallint,'unclear');
 INSERT INTO public.usage_counters(user_id,feature_key,quota_bucket,period_start,used_count) VALUES('a0000000-0000-4000-8000-00000000000a','calculate_numerology','trial_day',current_date-91,1);
 INSERT INTO public.automation_runs(task,idempotency_key,status,actor_kind,started_at,finished_at) VALUES('purge','old-run','succeeded','server_cron',now()-interval '91 days',now()-interval '91 days');
 PERFORM public.fj_purge_expired();
 IF EXISTS(SELECT 1 FROM public.user_readings WHERE id=old_id) OR EXISTS(SELECT 1 FROM public.reading_feedback WHERE reading_id=old_id) THEN RAISE EXCEPTION 'expired ledger/feedback kept';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.user_readings WHERE id=new_id) THEN RAISE EXCEPTION 'recent reading purged';END IF;
 IF EXISTS(SELECT 1 FROM public.usage_counters WHERE period_start=current_date-91) THEN RAISE EXCEPTION 'expired counter kept';END IF;
 IF EXISTS(SELECT 1 FROM public.automation_runs WHERE idempotency_key='old-run') THEN RAISE EXCEPTION 'expired run kept';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.billing_events WHERE provider='test_provider') THEN RAISE EXCEPTION 'billing purged without a retention decision';END IF;
END; $$;
RESET ROLE;

-- ===== KPI: empty/immature cohorts are NULL, not 0% =====
SET LOCAL ROLE service_role;
DO $$ DECLARE r jsonb; row jsonb; BEGIN
 r:=public.fj_cohort_report(now()-interval '2 days',now());
 IF r->>'population'<>'consented_near_signup_accounts_only' THEN RAISE EXCEPTION 'population label missing';END IF;
 FOR row IN SELECT * FROM jsonb_array_elements(r->'rows') LOOP
  IF (row->>'d7_eligible')::int=0 AND row->>'d7_exact_pct' IS NOT NULL THEN RAISE EXCEPTION 'immature D7 reported as %',row->>'d7_exact_pct';END IF;
  IF (row->>'conversion_eligible')::int=0 AND row->>'paid_35d_pct' IS NOT NULL THEN RAISE EXCEPTION 'immature conversion not null';END IF;
 END LOOP;
 BEGIN PERFORM public.fj_cohort_report(now(),now()-interval '1 day');RAISE EXCEPTION 'inverted window accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVALID_COHORT_WINDOW' THEN RAISE;END IF;END;
END; $$;
RESET ROLE;

-- ===== Account deletion: personal rows cascade, billing ledger keeps a de-identified row =====
DELETE FROM auth.users WHERE id='b0000000-0000-4000-8000-00000000000b';
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.user_access WHERE user_id='b0000000-0000-4000-8000-00000000000b') OR EXISTS(SELECT 1 FROM public.user_readings WHERE user_id='b0000000-0000-4000-8000-00000000000b')
  OR EXISTS(SELECT 1 FROM public.usage_counters WHERE user_id='b0000000-0000-4000-8000-00000000000b') OR EXISTS(SELECT 1 FROM public.subscriptions WHERE user_id='b0000000-0000-4000-8000-00000000000b') THEN RAISE EXCEPTION 'deleted user data remains';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.billing_events WHERE provider='test_provider' AND user_id IS NULL) THEN RAISE EXCEPTION 'billing ledger not de-identified';END IF;
END; $$;
ROLLBACK;
