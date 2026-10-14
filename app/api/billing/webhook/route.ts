/** Intentionally fail-closed until a real provider's signed webhook contract is implemented.
 * NEVER trust caller-supplied userId, price, tier, or subscription state here. */
export async function POST() {
  return Response.json({error:'BILLING_PROVIDER_NOT_CONFIGURED'}, {status:501,
    headers:{'Cache-Control':'no-store'}});
}
