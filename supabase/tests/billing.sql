-- fj_apply_billing and the money views: duplicates, economic-key dedupe, ordering, refunds, chargebacks,
-- currencies, malformed and unbound events. The caller must have verified the provider signature first.
-- Disposable database only; everything rolls back.
BEGIN;
INSERT INTO auth.users (id) VALUES ('b1000000-0000-4000-8000-000000000001'), ('b1000000-0000-4000-8000-000000000002');
SET LOCAL ROLE service_role;
-- The server creates the binding at checkout; provider metadata never chooses the user.
INSERT INTO public.subscriptions (user_id, provider, provider_customer_id, provider_subscription_id, status)
VALUES ('b1000000-0000-4000-8000-000000000001', 'test_provider', 'cust_1', 'sub_1', 'incomplete'),
       ('b1000000-0000-4000-8000-000000000002', 'test_provider', 'cust_2', 'sub_2', 'incomplete');

DO $$
DECLARE
  paid jsonb := jsonb_build_object(
    'event_type', 'payment_succeeded', 'provider_subscription_id', 'sub_1', 'occurred_at', now(),
    'economic_key', 'charge:1', 'amount_minor', 499, 'currency', 'USD', 'currency_exponent', 2,
    'billing_reason', 'initial', 'plan_key', 'premium',
    'subscription', jsonb_build_object('status', 'active', 'provider_updated_at', now(), 'current_period_end', now() + interval '30 days',
      'cancel_at_period_end', false, 'plan_key', 'premium', 'amount_minor', 499, 'currency', 'USD', 'currency_exponent', 2, 'interval_months', 1));
  r jsonb;
BEGIN
  r := public.fj_apply_billing('test_provider', 'evt_1', paid);
  IF NOT (r->>'stateApplied')::boolean OR r->>'stateDisposition' <> 'applied' THEN RAISE EXCEPTION 'snapshot not applied: %', r; END IF;
  IF (SELECT status FROM public.subscriptions WHERE provider_subscription_id = 'sub_1') <> 'active'
     OR (SELECT verified_at FROM public.subscriptions WHERE provider_subscription_id = 'sub_1') IS NULL THEN
    RAISE EXCEPTION 'subscription not activated and verified';
  END IF;
  IF public.fj_access_status('b1000000-0000-4000-8000-000000000001') <> 'premium' THEN RAISE EXCEPTION 'verified payment did not grant premium'; END IF;

  -- Same event, and another notification for the same charge, are duplicates.
  r := public.fj_apply_billing('test_provider', 'evt_1', paid);
  IF NOT (r->>'duplicate')::boolean THEN RAISE EXCEPTION 'duplicate event accepted'; END IF;
  r := public.fj_apply_billing('test_provider', 'evt_1_resent', paid);
  IF NOT (r->>'duplicate')::boolean THEN RAISE EXCEPTION 'same charge counted twice'; END IF;
  IF (SELECT count(*) FROM public.billing_events) <> 1 THEN RAISE EXCEPTION 'duplicate rows written'; END IF;
  BEGIN
    PERFORM public.fj_apply_billing('test_provider', 'evt_1', paid || jsonb_build_object('amount_minor', 1));
    RAISE EXCEPTION 'conflicting replay accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'BILLING_IDEMPOTENCY_CONFLICT' THEN RAISE; END IF;
  END;

  -- An older snapshot never regresses entitlement; an equal-time different snapshot needs reconciliation.
  r := public.fj_apply_billing('test_provider', 'evt_old', jsonb_build_object(
    'event_type', 'subscription_canceled', 'provider_subscription_id', 'sub_1', 'occurred_at', now() - interval '1 hour',
    'subscription', jsonb_build_object('status', 'canceled', 'provider_updated_at', now() - interval '1 hour', 'current_period_end', now() - interval '1 hour')));
  IF r->>'stateDisposition' <> 'older_or_identical' OR (SELECT status FROM public.subscriptions WHERE provider_subscription_id = 'sub_1') <> 'active' THEN
    RAISE EXCEPTION 'out-of-order event regressed entitlement: %', r;
  END IF;
  r := public.fj_apply_billing('test_provider', 'evt_tie', jsonb_build_object(
    'event_type', 'subscription_updated', 'provider_subscription_id', 'sub_1', 'occurred_at', now(),
    'subscription', jsonb_build_object('status', 'past_due', 'provider_updated_at', now(), 'current_period_end', now() + interval '30 days')));
  IF r->>'stateDisposition' <> 'needs_reconciliation' OR (SELECT state_disposition FROM public.billing_events WHERE event_id = 'evt_tie') <> 'needs_reconciliation' THEN
    RAISE EXCEPTION 'same-time conflicting snapshot not flagged: %', r;
  END IF;

  -- Refund and chargeback reduce cash only; they never change entitlement by themselves.
  PERFORM public.fj_apply_billing('test_provider', 'evt_refund', jsonb_build_object(
    'event_type', 'refund_succeeded', 'provider_subscription_id', 'sub_1', 'occurred_at', now(), 'economic_key', 'refund:1',
    'original_payment_key', 'charge:1', 'amount_minor', 99, 'currency', 'USD', 'currency_exponent', 2));
  IF (SELECT sum(signed_amount_minor) FROM public.fj_cash_events WHERE currency = 'USD') <> 400 THEN RAISE EXCEPTION 'refund not netted'; END IF;
  IF (SELECT mrr FROM public.fj_current_mrr WHERE currency = 'USD' AND currency_exponent = 2) <> 4.99 THEN RAISE EXCEPTION 'MRR includes refund'; END IF;
  PERFORM public.fj_apply_billing('test_provider', 'evt_cb', jsonb_build_object(
    'event_type', 'chargeback', 'provider_subscription_id', 'sub_1', 'occurred_at', now(), 'economic_key', 'cb:1',
    'original_payment_key', 'charge:1', 'amount_minor', 400, 'currency', 'USD', 'currency_exponent', 2));
  IF (SELECT sum(signed_amount_minor) FROM public.fj_cash_events WHERE currency = 'USD') <> 0 THEN RAISE EXCEPTION 'chargeback not netted'; END IF;
  IF (SELECT status FROM public.subscriptions WHERE provider_subscription_id = 'sub_1') <> 'active' THEN RAISE EXCEPTION 'cash event changed entitlement'; END IF;

  -- Currencies are never combined.
  PERFORM public.fj_apply_billing('test_provider', 'evt_jpy', jsonb_build_object(
    'event_type', 'payment_succeeded', 'provider_subscription_id', 'sub_2', 'occurred_at', now(), 'economic_key', 'charge:jpy',
    'amount_minor', 500, 'currency', 'JPY', 'currency_exponent', 0, 'billing_reason', 'initial'));
  r := public.fj_revenue_report(now() - interval '1 day', now() + interval '1 minute');
  IF jsonb_array_length(r->'rows') <> 2 OR r->>'measure' <> 'net_cash_collected_not_mrr_or_accounting_revenue' THEN
    RAISE EXCEPTION 'revenue report merged currencies: %', r;
  END IF;
  IF public.fj_access_status('b1000000-0000-4000-8000-000000000002') <> 'free' THEN
    RAISE EXCEPTION 'payment without a subscription snapshot granted premium';
  END IF;
END $$;

-- ===== Malformed, unbound and future events are refused before any write =====
DO $$
DECLARE
  base jsonb := jsonb_build_object('event_type', 'subscription_updated', 'provider_subscription_id', 'sub_2', 'occurred_at', now());
  before bigint := (SELECT count(*) FROM public.billing_events);
  cases text[][] := ARRAY[
    ARRAY['{"provider_subscription_id":"sub_unknown"}', 'BILLING_BINDING_REQUIRED'],
    ARRAY['{"amount_minor":5}', 'NON_FINANCIAL_AMOUNT'],
    ARRAY['{"event_type":"payment_succeeded","economic_key":"charge:w","amount_minor":5}', 'INVALID_FINANCIAL_FIELDS'],
    ARRAY['{"event_type":"gift"}', 'INVALID_BILLING_EVENT'],
    ARRAY['{"subscription":{"status":"active"}}', 'INVALID_SUBSCRIPTION_SNAPSHOT'],
    ARRAY['{"subscription":{"status":"paused","provider_updated_at":"2026-01-01T00:00:00Z"}}', 'INVALID_SUBSCRIPTION_SNAPSHOT']];
  i int;
BEGIN
  FOR i IN 1..array_length(cases, 1) LOOP
    BEGIN
      PERFORM public.fj_apply_billing('test_provider', 'evt_bad_' || i, base || cases[i][1]::jsonb);
      RAISE EXCEPTION 'case % accepted', cases[i][2];
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> cases[i][2] THEN RAISE EXCEPTION 'case % raised %', cases[i][2], SQLERRM; END IF;
    END;
  END LOOP;
  BEGIN
    PERFORM public.fj_apply_billing('test_provider', 'evt_future', base || jsonb_build_object('occurred_at', now() + interval '1 hour'));
    RAISE EXCEPTION 'future event accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_BILLING_EVENT' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.fj_apply_billing('Bad Provider', 'evt_x', base);
    RAISE EXCEPTION 'invalid provider accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'INVALID_BILLING_EVENT' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM public.billing_events) <> before THEN RAISE EXCEPTION 'refused event left a row'; END IF;
END $$;

-- ===== Account deletion: subscriptions cascade, the money ledger keeps a de-identified row =====
RESET ROLE;
DELETE FROM auth.users WHERE id = 'b1000000-0000-4000-8000-000000000001';
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.subscriptions WHERE user_id = 'b1000000-0000-4000-8000-000000000001') THEN RAISE EXCEPTION 'subscription survived deletion'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.billing_events WHERE event_id = 'evt_1' AND user_id IS NULL) THEN RAISE EXCEPTION 'billing ledger not de-identified'; END IF;
END $$;
ROLLBACK;
