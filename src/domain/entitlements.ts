/** Pure policy module; the DB enforces the counter atomically. */
export type Entitlement = 'free' | 'trial' | 'premium' | 'suspended';
export type Subscription = { status: string; current_period_end: string | null; verified_at?: string | null };
export type UserAccess = { trial_ends_at: string | null; suspended_at: string | null };
export type Feature = 'calculate_numerology' | 'draw_tarot';

export function resolveEntitlement(
  access: UserAccess | null,
  subscriptions: Subscription[],
  now: Date,
): Entitlement {
  if (access?.suspended_at) return 'suspended';
  if (subscriptions.some((s) =>
    !!s.verified_at && ['active', 'trialing'].includes(s.status) && !!s.current_period_end &&
    Date.parse(s.current_period_end) > now.getTime())) return 'premium';
  if (access?.trial_ends_at && Date.parse(access.trial_ends_at) > now.getTime()) return 'trial';
  return 'free';
}

const isTime=(v:unknown)=>v===null||typeof v==='string';
/**
 * Parses the fj_access_snapshot RPC result (the same rows memberTier() used to read in two queries) and resolves
 * it with resolveEntitlement, so tier policy lives in one TypeScript function. Unexpected shapes fail closed.
 */
export function entitlementFromSnapshot(snapshot:unknown,now:Date):Entitlement {
  const s=snapshot as {access?:unknown;subscriptions?:unknown}|null;
  const a=s?.access as Record<string,unknown>|null|undefined;
  const subs=s?.subscriptions;
  const validAccess=a===null||(!!a&&typeof a==='object'&&isTime(a.trial_ends_at)&&isTime(a.suspended_at));
  const validSubs=Array.isArray(subs)&&subs.every((x)=>!!x&&typeof x==='object'&&typeof x.status==='string'&&isTime(x.current_period_end)&&isTime(x.verified_at));
  if(!s||typeof s!=='object'||!validAccess||!validSubs)throw new Error('ACCESS_BACKEND_FAILURE');
  return resolveEntitlement(a as UserAccess|null,subs as Subscription[],now);
}

export function permission(entitlement: Entitlement, feature: Feature): {
  enabled: boolean;
  maxUses: number;
  period: 'day' | 'iso_week';
} {
  if (entitlement === 'suspended') return { enabled: false, maxUses: 0, period: 'day' };
  if (entitlement === 'free') return {
    enabled: feature === 'calculate_numerology', maxUses: 3, period: 'iso_week',
  };
  return { enabled: true, maxUses: entitlement === 'premium' ? 200 : 100, period: 'day' };
}

export function periodStartUTC(now: Date, period: 'day' | 'iso_week'): string {
  const utc = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  if (period === 'iso_week') {
    const isoDay = (utc.getUTCDay() + 6) % 7;
    utc.setUTCDate(utc.getUTCDate() - isoDay);
  }
  return utc.toISOString().slice(0, 10);
}
