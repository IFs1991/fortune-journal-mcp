import type {SupabaseClient, User} from '@supabase/supabase-js';
import {readReferral} from '@/src/domain/security';
import {isEnabled} from '@/src/lib/env';
import {adminSupabase} from '@/src/lib/supabase/server';

/**
 * Customer self-service on the login page: optional-data preferences, export and account deletion.
 * Callers pass a user already verified by Supabase Auth; ids never come from form or query input.
 */

/** Version of the consent text on the login page. Bump it when that text changes. */
export const PRIVACY_VERSION = '2026-10-v2';

export async function loadPreferences(userId: string) {
  const {data, error} = await adminSupabase()
    .from('user_access')
    .select('analytics_consent_at,interest_consent_at')
    .eq('user_id', userId)
    .maybeSingle();
  if (error) return null;
  return {analytics: !!data?.analytics_consent_at, interests: !!data?.interest_consent_at};
}

type PreferenceResult = 'saved' | 'analytics_disabled' | 'unavailable';

export async function savePreferences(user: User, form: URLSearchParams): Promise<PreferenceResult> {
  const analytics = form.get('analytics') === 'yes';
  const interests = analytics && form.get('interests') === 'yes';
  if (analytics && !isEnabled('PRODUCT_ANALYTICS_ENABLED')) return 'analytics_disabled';
  const db = adminSupabase();
  const {error} = await db.rpc('fj_set_privacy', {
    p_user_id: user.id,
    p_analytics: analytics,
    p_interests: interests,
    p_version: PRIVACY_VERSION,
    // service_role cannot read auth.users, so the verified Auth user supplies its registration time.
    p_registered_at: user.created_at ?? null,
  });
  if (error) return 'unavailable';
  if (analytics) await recordAttribution(db, user.id, form);
  return 'saved';
}

const SELF_REPORTED_CHANNELS = ['threads', 'chatgpt', 'claude', 'direct'];

/** A valid signed Threads link wins over the user's own answer; attribution failure never blocks consent. */
async function recordAttribution(db: SupabaseClient, userId: string, form: URLSearchParams): Promise<void> {
  const referral = readReferral(process.env.ATTRIBUTION_HMAC_KEY, form.get('ref') ?? undefined);
  const source = form.get('source') ?? '';
  let reply;
  if (referral) {
    reply = await db.rpc('fj_set_attribution', {
      p_user_id: userId,
      p_channel: 'threads',
      p_evidence: 'signed_link',
      p_post_id: referral.postId,
    });
  } else if (SELF_REPORTED_CHANNELS.includes(source)) {
    reply = await db.rpc('fj_set_attribution', {
      p_user_id: userId,
      p_channel: source,
      p_evidence: 'self_reported',
    });
  }
  if (reply?.error) console.warn('FJ_ATTRIBUTION_NOT_RECORDED');
}

/** Exportable service data per resource. Fingerprints, tokens and provider customer ids are never exported. */
const EXPORTS: Record<string, {table: string; columns: string; time: string; order: string[]}> = {
  access: {
    table: 'user_access',
    columns:
      'user_id,trial_started_at,trial_ends_at,first_calculated_at,suspended_at,analytics_consent_at,' +
      'interest_consent_at,consent_version,consent_updated_at,analytics_revoked_at,created_at',
    time: 'created_at',
    order: ['user_id'],
  },
  subscriptions: {
    table: 'subscriptions',
    columns:
      'id,provider,provider_subscription_id,status,current_period_end,cancel_at_period_end,plan_key,amount_minor,' +
      'currency,currency_exponent,interval_months,created_at',
    time: 'created_at',
    order: ['id'],
  },
  readings: {
    table: 'user_readings',
    columns: 'id,request_id,feature_key,algorithm_version,target_date,topic,tier_at_use,calculated_at',
    time: 'calculated_at',
    order: ['id'],
  },
  feedback: {
    table: 'reading_feedback',
    columns: 'id,reading_id,usefulness,match_assessment,followup_date,created_at,updated_at',
    time: 'created_at',
    order: ['id'],
  },
  events: {
    table: 'funnel_events',
    columns:
      'id,event_name,occurred_at,received_at,source_channel,source_evidence,observation,post_id,reading_id',
    time: 'received_at',
    order: ['id'],
  },
  billing: {
    table: 'billing_events',
    columns:
      'provider,event_id,event_type,occurred_at,received_at,amount_minor,currency,currency_exponent,billing_reason',
    time: 'received_at',
    order: ['event_id', 'provider'],
  },
};
const PAGE_SIZE = 100;

export type ExportRequest = {resource: string; offset: number; asOf: string};

/** Validates query input. asOf pins the page set so follow-up pages are consistent in time. */
export function parseExportRequest(
  params: URLSearchParams,
): ExportRequest | 'invalid_resource' | 'invalid_page' {
  const resource = params.get('resource') ?? 'access';
  if (!Object.hasOwn(EXPORTS, resource)) return 'invalid_resource';
  const offset = Number(params.get('offset') ?? '0');
  const asOf = params.get('asOf') ?? new Date().toISOString();
  const validOffset = Number.isSafeInteger(offset) && offset >= 0 && offset <= 1_000_000;
  const validAsOf = Number.isFinite(Date.parse(asOf)) && Date.parse(asOf) <= Date.now() + 300_000;
  return validOffset && validAsOf ? {resource, offset, asOf} : 'invalid_page';
}

export async function exportPage(userId: string, {resource, offset, asOf}: ExportRequest) {
  const definition = EXPORTS[resource];
  let query = adminSupabase()
    .from(definition.table)
    .select(definition.columns)
    .eq('user_id', userId)
    .lte(definition.time, asOf);
  for (const column of definition.order) query = query.order(column);
  // One extra row tells whether another page exists.
  const {data, error} = await query.range(offset, offset + PAGE_SIZE);
  if (error) return null;
  const rows = data ?? [];
  const hasMore = rows.length > PAGE_SIZE;
  return {
    resource,
    asOf,
    rows: rows.slice(0, PAGE_SIZE),
    hasMore,
    nextOffset: hasMore ? offset + PAGE_SIZE : null,
    availableResources: Object.keys(EXPORTS),
    note:
      'Paged export of service data only. Your journal is in your Google account. No request fingerprint, ' +
      'OAuth token or payment credential is exported.',
  };
}

const OPEN_BILLING_STATUSES = ['active', 'trialing', 'past_due', 'incomplete', 'unpaid'];
type DeletionResult =
  'deleted' | 'billing_open' | 'billing_unverifiable' | 'suspend_failed' | 'signout_failed' | 'delete_failed';

/**
 * Suspend → revoke every session → delete the Auth user (FK cascades remove per-user rows; billing_events keep a
 * de-identified row). Suspension first means a failure part-way still blocks every MCP call.
 */
export async function deleteAccount(session: SupabaseClient, userId: string): Promise<DeletionResult> {
  const admin = adminSupabase();
  const {data: subscriptions, error: lookupError} = await admin
    .from('subscriptions')
    .select('status')
    .eq('user_id', userId);
  if (lookupError) return 'billing_unverifiable';
  if ((subscriptions ?? []).some((row) => OPEN_BILLING_STATUSES.includes(row.status))) return 'billing_open';

  const {error: suspendError} = await admin
    .from('user_access')
    .upsert({user_id: userId, suspended_at: new Date().toISOString()}, {onConflict: 'user_id'});
  if (suspendError) return 'suspend_failed';
  const {error: signOutError} = await session.auth.signOut({scope: 'global'});
  if (signOutError) return 'signout_failed';
  // Every MCP request re-checks the user with Auth.getUser, so unexpired tokens of a deleted user stop working.
  const {error: deleteError} = await admin.auth.admin.deleteUser(userId);
  if (deleteError) return 'delete_failed';
  await session.auth.signOut();
  return 'deleted';
}
