import {adminSupabase} from '@/src/lib/supabase/server';
import {validateBillingEvent, type NormalizedBillingEvent} from '@/src/domain/billing-event';
export interface BillingProvider {
  createHostedCheckout(userId: string, successUrl: string, cancelUrl: string): Promise<{url: string}>;
  createCustomerPortal(userId: string): Promise<{url: string}>;
  verifyWebhook(
    rawBody: Uint8Array,
    headers: Headers,
  ): Promise<{provider: string; eventId: string; event: NormalizedBillingEvent}>;
}
/** Adapter-owned operation; no public route accepts this shape as already verified. */
export async function processProviderWebhook(
  provider: BillingProvider,
  rawBody: Uint8Array,
  headers: Headers,
) {
  const verified = await provider.verifyWebhook(rawBody, headers);
  const event = validateBillingEvent(verified.event);
  const {data, error} = await adminSupabase().rpc('fj_apply_billing', {
    p_provider: verified.provider,
    p_event_id: verified.eventId,
    p_event: event,
  });
  if (error) throw new Error('BILLING_RECONCILIATION_REQUIRED');
  return data;
}
// No default provider, fake signature, mock payment, or Premium-grant endpoint is supplied.
