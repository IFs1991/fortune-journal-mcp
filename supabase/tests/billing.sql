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
  -- active vs past_due at the same instant: entitlement is ambiguous, so Premium is withheld until reconciled.
  IF public.fj_access_status('b1000000-0000-4000-8000-000000000001') = 'premium' THEN RAISE EXCEPTION 'ambiguous state kept premium'; END IF;
  r := public.fj_apply_billing('test_provider', 'evt_tie_reconciled', jsonb_build_object(
    'event_type', 'subscription_updated', 'provider_subscription_id', 'sub_1', 'occurred_at', now(), 'reconciled', true,
    'subscription', paid->'subscription'));
  IF NOT (r->>'stateApplied')::boolean OR public.fj_access_status('b1000000-0000-4000-8000-000000000001') <> 'premium' THEN
    RAISE EXCEPTION 'reconciled snapshot did not restore premium: %', r;
  END IF;

  -- Refund and chargeback reduce cash only; they never change entitlement by themselves.
  PERFORM public.fj_apply_billing('test_provider', 'evt_refund', jsonb_build_object(
    'event_type', 'refund_succeeded', 'provider_subscription_id', 'sub_1', 'occurred_at', now(), 'economic_key', 'refund:1',
    'original_payment_key', 'charge:1', 'amount_minor', 99, 'currency', 'USD', 'currency_exponent', 2));
  IF (SELECT sum(signed_amount_minor) FROM public.fj_cash_events WHERE currency = 'USD') <> 400 THEN RAISE EXCEPTION 'refund not netted'; END IF;
  IF (SELECT mrr FROM public.fj_current_mrr WHERE currency = 'USD' AND currency_exponent = 2) IS DISTINCT FROM 4.99 THEN RAISE EXCEPTION 'MRR includes refund'; END IF;
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

-- ===== Account deletion: the binding and the money ledger stay, de-identified =====
RESET ROLE;
DELETE FROM auth.users WHERE id = 'b1000000-0000-4000-8000-000000000001';
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.subscriptions WHERE user_id = 'b1000000-0000-4000-8000-000000000001') THEN RAISE EXCEPTION 'subscription still identifies the user'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions WHERE provider_subscription_id = 'sub_1' AND user_id IS NULL AND provider_customer_id IS NULL) THEN
    RAISE EXCEPTION 'subscription binding not kept de-identified';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.billing_events WHERE event_id = 'evt_1' AND user_id IS NULL) THEN RAISE EXCEPTION 'billing ledger not de-identified'; END IF;
END $$;
ROLLBACK;

-- ===== Regressions (2026-10-17): duplicate cash notice with a newer snapshot, equal-time changes, refunds after
-- account deletion, payment failure, cancel at period end =====
BEGIN;
INSERT INTO auth.users (id) VALUES ('b2000000-0000-4000-8000-000000000001'), ('b2000000-0000-4000-8000-000000000002');
SET LOCAL ROLE service_role;
INSERT INTO public.subscriptions (user_id, provider, provider_customer_id, provider_subscription_id, status)
VALUES ('b2000000-0000-4000-8000-000000000001', 'test_provider', 'cust_r1', 'sub_r1', 'incomplete'),
       ('b2000000-0000-4000-8000-000000000002', 'test_provider', 'cust_r2', 'sub_r2', 'incomplete');
DO $$
DECLARE
  t0 timestamptz := now() - interval '10 minutes';
  snap jsonb := jsonb_build_object('status', 'active', 'current_period_end', now() + interval '30 days',
    'cancel_at_period_end', false, 'plan_key', 'premium', 'amount_minor', 499, 'currency', 'USD',
    'currency_exponent', 2, 'interval_months', 1);
  charge jsonb := jsonb_build_object('event_type', 'payment_succeeded', 'provider_subscription_id', 'sub_r1',
    'occurred_at', t0, 'economic_key', 'charge:r1', 'amount_minor', 499, 'currency', 'USD', 'currency_exponent', 2,
    'billing_reason', 'initial');
  r jsonb;
BEGIN
  -- (1) The first notice of a charge has no snapshot; a second notice of the SAME charge (other event id) carries
  -- the newer subscription state. Cash is counted once, but the state must not be dropped as a duplicate.
  r := public.fj_apply_billing('test_provider', 'evt_r1_charge', charge);
  IF (SELECT status FROM public.subscriptions WHERE provider_subscription_id = 'sub_r1') <> 'incomplete' THEN RAISE EXCEPTION 'cash alone changed state'; END IF;
  r := public.fj_apply_billing('test_provider', 'evt_r1_invoice', charge || jsonb_build_object('subscription', snap || jsonb_build_object('provider_updated_at', t0)));
  IF NOT (r->>'duplicate')::boolean OR NOT (r->>'stateApplied')::boolean THEN
    RAISE EXCEPTION 'REGRESSION 1: newer state in a duplicate cash notice was ignored: %', r;
  END IF;
  IF public.fj_access_status('b2000000-0000-4000-8000-000000000001') <> 'premium' THEN RAISE EXCEPTION 'REGRESSION 1: premium not granted'; END IF;
  IF (SELECT count(*) FROM public.billing_events WHERE economic_key = 'charge:r1') <> 1 THEN RAISE EXCEPTION 'charge counted twice'; END IF;
  -- Redelivery of either notice stays a no-op.
  r := public.fj_apply_billing('test_provider', 'evt_r1_invoice', charge || jsonb_build_object('subscription', snap || jsonb_build_object('provider_updated_at', t0)));
  IF NOT (r->>'duplicate')::boolean OR (r->>'stateApplied')::boolean THEN RAISE EXCEPTION 'redelivery re-applied: %', r; END IF;

  -- (3) Same provider timestamp, different plan / price / cancellation: never silently "identical".
  FOR r IN SELECT public.fj_apply_billing('test_provider', 'evt_r1_tie_' || n, jsonb_build_object(
      'event_type', 'subscription_updated', 'provider_subscription_id', 'sub_r1', 'occurred_at', t0,
      'subscription', snap || jsonb_build_object('provider_updated_at', t0) || change))
    FROM (VALUES (1, '{"plan_key":"premium_plus"}'::jsonb), (2, '{"amount_minor":999}'), (3, '{"cancel_at_period_end":true}'),
      (4, '{"interval_months":12}'), (5, '{"currency":"EUR"}')) AS v(n, change) LOOP
    IF r->>'stateDisposition' <> 'needs_reconciliation' THEN
      RAISE EXCEPTION 'REGRESSION 3: equal-time change not flagged: %', r;
    END IF;
  END LOOP;
  -- Both snapshots entitle: access is kept while flagged.
  IF public.fj_access_status('b2000000-0000-4000-8000-000000000001') <> 'premium' THEN RAISE EXCEPTION 'entitled tie revoked access'; END IF;
  -- An equal-time snapshot that would end entitlement is ambiguous: fail closed until reconciled.
  r := public.fj_apply_billing('test_provider', 'evt_r1_tie_cancel', jsonb_build_object(
    'event_type', 'subscription_canceled', 'provider_subscription_id', 'sub_r1', 'occurred_at', t0,
    'subscription', snap || jsonb_build_object('provider_updated_at', t0, 'status', 'canceled')));
  IF r->>'stateDisposition' <> 'needs_reconciliation' OR public.fj_access_status('b2000000-0000-4000-8000-000000000001') = 'premium' THEN
    RAISE EXCEPTION 'ambiguous cancellation kept premium: %', r;
  END IF;
  -- A snapshot the adapter fetched from the provider API resolves the tie.
  r := public.fj_apply_billing('test_provider', 'evt_r1_reconciled', jsonb_build_object(
    'event_type', 'subscription_updated', 'provider_subscription_id', 'sub_r1', 'occurred_at', t0, 'reconciled', true,
    'subscription', snap || jsonb_build_object('provider_updated_at', t0, 'plan_key', 'premium_plus', 'amount_minor', 999)));
  IF NOT (r->>'stateApplied')::boolean OR public.fj_access_status('b2000000-0000-4000-8000-000000000001') <> 'premium'
     OR (SELECT plan_key FROM public.subscriptions WHERE provider_subscription_id = 'sub_r1') <> 'premium_plus' THEN
    RAISE EXCEPTION 'reconciled snapshot not applied: %', r;
  END IF;
  -- A reconciled snapshot never moves state backwards in time.
  r := public.fj_apply_billing('test_provider', 'evt_r1_reconciled_old', jsonb_build_object(
    'event_type', 'subscription_updated', 'provider_subscription_id', 'sub_r1', 'occurred_at', t0, 'reconciled', true,
    'subscription', snap || jsonb_build_object('provider_updated_at', t0 - interval '1 minute', 'status', 'canceled')));
  IF r->>'stateDisposition' <> 'older_or_identical' THEN RAISE EXCEPTION 'old reconciled snapshot applied: %', r; END IF;

  -- Payment failure with a past_due snapshot ends Premium; cancel at period end keeps it until the period ends.
  r := public.fj_apply_billing('test_provider', 'evt_r2_paid', jsonb_build_object('event_type', 'payment_succeeded',
    'provider_subscription_id', 'sub_r2', 'occurred_at', t0, 'economic_key', 'charge:r2', 'amount_minor', 499, 'currency', 'USD',
    'currency_exponent', 2, 'billing_reason', 'initial', 'subscription', snap || jsonb_build_object('provider_updated_at', t0)));
  r := public.fj_apply_billing('test_provider', 'evt_r2_cancel_later', jsonb_build_object('event_type', 'subscription_updated',
    'provider_subscription_id', 'sub_r2', 'occurred_at', t0 + interval '1 minute',
    'subscription', snap || jsonb_build_object('provider_updated_at', t0 + interval '1 minute', 'cancel_at_period_end', true)));
  IF public.fj_access_status('b2000000-0000-4000-8000-000000000002') <> 'premium' THEN RAISE EXCEPTION 'cancel at period end revoked early'; END IF;
  r := public.fj_apply_billing('test_provider', 'evt_r2_failed', jsonb_build_object('event_type', 'payment_failed',
    'provider_subscription_id', 'sub_r2', 'occurred_at', t0 + interval '2 minutes',
    'subscription', snap || jsonb_build_object('provider_updated_at', t0 + interval '2 minutes', 'status', 'past_due')));
  IF public.fj_access_status('b2000000-0000-4000-8000-000000000002') = 'premium' THEN RAISE EXCEPTION 'past_due kept premium'; END IF;
  IF EXISTS (SELECT 1 FROM public.fj_cash_events WHERE event_id = 'evt_r2_failed') THEN RAISE EXCEPTION 'failed payment counted as cash'; END IF;
END $$;

-- (2) Refund notified after the account was deleted: still recorded (de-identified) so cash nets correctly.
RESET ROLE;
UPDATE public.subscriptions SET status = 'canceled' WHERE provider_subscription_id = 'sub_r2';
DELETE FROM auth.users WHERE id = 'b2000000-0000-4000-8000-000000000002';
SET LOCAL ROLE service_role;
DO $$
DECLARE
  r jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.subscriptions WHERE provider_subscription_id = 'sub_r2' AND user_id IS NULL AND provider_customer_id IS NULL) THEN
    RAISE EXCEPTION 'REGRESSION 2: subscription binding not kept de-identified after deletion';
  END IF;
  r := public.fj_apply_billing('test_provider', 'evt_r2_refund', jsonb_build_object('event_type', 'refund_succeeded',
    'provider_subscription_id', 'sub_r2', 'occurred_at', now(), 'economic_key', 'refund:r2', 'original_payment_key', 'charge:r2',
    'amount_minor', 499, 'currency', 'USD', 'currency_exponent', 2));
  IF (SELECT sum(signed_amount_minor) FROM public.fj_cash_events WHERE provider_subscription_id = 'sub_r2') <> 0 THEN
    RAISE EXCEPTION 'REGRESSION 2: refund after deletion not netted';
  END IF;
  IF (SELECT user_id FROM public.billing_events WHERE event_id = 'evt_r2_refund') IS NOT NULL THEN RAISE EXCEPTION 'refund row identifies a user'; END IF;
  -- A de-identified binding never grants anything, whatever the provider later says.
  r := public.fj_apply_billing('test_provider', 'evt_r2_reactivated', jsonb_build_object('event_type', 'subscription_updated',
    'provider_subscription_id', 'sub_r2', 'occurred_at', now(),
    'subscription', jsonb_build_object('status', 'active', 'provider_updated_at', now(), 'current_period_end', now() + interval '30 days')));
  IF r->>'stateDisposition' <> 'needs_reconciliation' THEN RAISE EXCEPTION 'activity on a deleted account not flagged: %', r; END IF;
  r := public.fj_revenue_report(now() - interval '1 day', now() + interval '1 minute');
  IF (r->>'eventsNeedingReconciliation')::int < 1 THEN RAISE EXCEPTION 'report hides reconciliation work: %', r; END IF;
END $$;
ROLLBACK;
