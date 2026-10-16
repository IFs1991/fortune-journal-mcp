/** Provider-neutral NORMALIZED contract. This does not authenticate a webhook. */
export type SubscriptionSnapshot = {
  status: 'incomplete' | 'trialing' | 'active' | 'past_due' | 'canceled' | 'unpaid' | 'expired';
  provider_updated_at: string;
  current_period_end: string | null;
  cancel_at_period_end: boolean;
  plan_key: string | null;
  amount_minor: number | null;
  currency: string | null;
  currency_exponent: number | null;
  interval_months: number | null;
};
export type NormalizedBillingEvent = {
  event_type:
    | 'subscription_updated'
    | 'payment_succeeded'
    | 'payment_failed'
    | 'subscription_canceled'
    | 'refund_succeeded'
    | 'chargeback';
  provider_subscription_id: string;
  occurred_at: string;
  economic_key: string | null;
  original_payment_key: string | null;
  amount_minor: number | null;
  currency: string | null;
  currency_exponent: number | null;
  billing_reason: 'initial' | 'recurring' | 'one_time' | 'not_applicable';
  plan_key: string | null;
  subscription: SubscriptionSnapshot | null;
};
export function validateBillingEvent(e: NormalizedBillingEvent): NormalizedBillingEvent {
  if (
    !e ||
    ![
      'subscription_updated',
      'payment_succeeded',
      'payment_failed',
      'subscription_canceled',
      'refund_succeeded',
      'chargeback',
    ].includes(e.event_type) ||
    !e.provider_subscription_id ||
    !Number.isFinite(Date.parse(e.occurred_at))
  )
    throw new Error('INVALID_BILLING_EVENT');
  if (['payment_succeeded', 'refund_succeeded', 'chargeback'].includes(e.event_type)) {
    if (
      !e.economic_key ||
      e.economic_key.length > 160 ||
      !Number.isSafeInteger(e.amount_minor) ||
      e.amount_minor! < 0 ||
      !e.currency ||
      !/^[A-Z]{3}$/.test(e.currency) ||
      !Number.isInteger(e.currency_exponent) ||
      e.currency_exponent! < 0 ||
      e.currency_exponent! > 6
    )
      throw new Error('INVALID_MONEY');
  } else if (e.economic_key !== null || e.amount_minor !== null) throw new Error('NON_FINANCIAL_AMOUNT');
  if (e.subscription) {
    const s = e.subscription;
    if (
      !Number.isFinite(Date.parse(s.provider_updated_at)) ||
      !['incomplete', 'trialing', 'active', 'past_due', 'canceled', 'unpaid', 'expired'].includes(s.status)
    )
      throw new Error('INVALID_SUBSCRIPTION');
  }
  return e;
}
