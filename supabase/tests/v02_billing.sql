BEGIN;
INSERT INTO auth.users(id) VALUES('11111111-1111-4111-8111-111111111111');
SET LOCAL ROLE service_role;
INSERT INTO public.subscriptions(user_id,provider,provider_customer_id,provider_subscription_id,status) VALUES('11111111-1111-4111-8111-111111111111','test_provider','test_customer','test_sub','incomplete');
DO $$ DECLARE e jsonb;r jsonb;BEGIN
 e:=jsonb_build_object('event_type','payment_succeeded','provider_subscription_id','test_sub','occurred_at',now(),'economic_key','charge:test1','amount_minor',499,'currency','USD','currency_exponent',2,'billing_reason','initial','plan_key','premium',
 'subscription',jsonb_build_object('status','active','provider_updated_at',now(),'current_period_end',now()+interval '30 days','cancel_at_period_end',false,'plan_key','premium','amount_minor',499,'currency','USD','currency_exponent',2,'interval_months',1));
 r:=public.fj_apply_billing('test_provider','event1',e);
 IF (r->>'stateApplied')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'paid snapshot not applied';END IF;
 r:=public.fj_apply_billing('test_provider','event1',e);IF (r->>'duplicate')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'duplicate event accepted';END IF;
 r:=public.fj_apply_billing('test_provider','another_notification_for_same_charge',e);IF (r->>'duplicate')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'economic event counted twice';END IF;
 e:=jsonb_build_object('event_type','subscription_canceled','provider_subscription_id','test_sub','occurred_at',now()-interval '1 hour','billing_reason','not_applicable','subscription',jsonb_build_object('status','canceled','provider_updated_at',now()-interval '1 hour','current_period_end',now()-interval '1 hour'));
 PERFORM public.fj_apply_billing('test_provider','older_event',e);
 IF (SELECT status FROM public.subscriptions WHERE provider='test_provider' AND provider_subscription_id='test_sub')<>'active' THEN RAISE EXCEPTION 'out-of-order event regressed entitlement';END IF;
 e:=jsonb_build_object('event_type','refund_succeeded','provider_subscription_id','test_sub','occurred_at',now(),'economic_key','refund:test1','original_payment_key','charge:test1','amount_minor',99,'currency','USD','currency_exponent',2,'billing_reason','not_applicable');
 PERFORM public.fj_apply_billing('test_provider','refund1',e);
 IF (SELECT sum(signed_amount_minor) FROM public.fj_cash_events WHERE provider='test_provider')<>400 THEN RAISE EXCEPTION 'cash incorrect';END IF;
 IF (SELECT mrr FROM public.fj_current_mrr WHERE currency='USD' AND currency_exponent=2)<>4.99 THEN RAISE EXCEPTION 'MRR incorrectly includes refund';END IF;
END; $$;
RESET ROLE;
ROLLBACK;
