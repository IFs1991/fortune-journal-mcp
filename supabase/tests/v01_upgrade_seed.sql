INSERT INTO auth.users(id) VALUES ('99999999-9999-4999-8999-999999999999');
INSERT INTO public.user_access(user_id,trial_started_at,trial_ends_at) VALUES('99999999-9999-4999-8999-999999999999',now()-interval '20 days',now()-interval '6 days');
INSERT INTO public.subscriptions(user_id,provider,provider_customer_id,provider_subscription_id,status,current_period_end)
 VALUES('99999999-9999-4999-8999-999999999999','legacy','customer_legacy','sub_legacy','active',now()+interval '30 days');
INSERT INTO public.billing_events(provider,event_id,user_id,processing_status) VALUES('legacy','event_legacy','99999999-9999-4999-8999-999999999999','processed');
