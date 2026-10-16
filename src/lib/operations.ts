import {adminSupabase} from '@/src/lib/supabase/server';
import {ThreadsClient} from '@/src/integrations/threads';
import {sha256, issueReferral} from '@/src/domain/security';
import {dueAges} from '@/src/domain/threads';
import {appOrigin} from '@/src/lib/env';

type Run = {acquired: boolean; runId: string; attempt?: number; status?: string};
function threads() {
  return new ThreadsClient({
    accountId: process.env.THREADS_ACCOUNT_ID ?? '',
    accessToken: process.env.THREADS_ACCESS_TOKEN ?? '',
    apiVersion: process.env.THREADS_API_VERSION ?? '',
  });
}
export function threadsAccount(): string {
  const account = process.env.THREADS_ACCOUNT_ID;
  if (!account || !/^\d{1,80}$/.test(account)) throw new Error('THREADS_NOT_CONFIGURED');
  return account;
}
const safeError = (e: unknown) =>
  e instanceof Error && /^THREADS_[A-Z_]+$/.test(e.message) ? e.message : 'OPERATION_FAILED';
async function begin(
  task: string,
  key: string,
  postId: string | null = null,
  actor = 'owner_agent',
): Promise<Run> {
  const {data, error} = await adminSupabase().rpc('fj_begin_run', {
    p_task: task,
    p_key: key,
    p_actor: actor,
    p_post_id: postId,
  });
  if (error || !data) throw new Error('RUN_BACKEND_FAILURE');
  return data as Run;
}
async function end(run: Run, success: boolean, errorCode: string | null = null) {
  const {data, error} = await adminSupabase().rpc('fj_finish_run', {
    p_run_id: run.runId,
    p_attempt: run.attempt,
    p_success: success,
    p_error: errorCode,
  });
  if (error || data !== true) throw new Error('RUN_COMPLETION_FAILED');
}
export type DraftInput = {
  body: string;
  topic: 'love' | 'work' | 'money' | 'general';
  method: 'tarot' | 'numerology' | 'mixed';
  tone: 'empathetic' | 'assertive' | 'question';
  language: string;
  hookText?: string;
  ctaKey: 'none' | 'reflect' | 'save' | 'reply' | 'visit_profile';
  promptVersion: string;
  experimentId?: string;
  variantKey?: string;
  scheduledAt?: string;
  zodiac?: string;
};
export async function draftPost(requestId: string, input: DraftInput) {
  const db = adminSupabase();
  const hash = sha256(input.body);
  const {data: existing, error: lookup} = await db
    .from('fortune_posts')
    .select('id,body_sha256,status')
    .eq('id', requestId)
    .maybeSingle();
  if (lookup) throw new Error('POST_BACKEND_FAILURE');
  if (existing) {
    if (existing.body_sha256 !== hash) throw new Error('IDEMPOTENCY_CONFLICT');
    return {postId: existing.id, bodySha256: hash, status: existing.status, replayed: true};
  }
  const {error} = await db.from('fortune_posts').insert({
    id: requestId,
    account_key: threadsAccount(),
    body: input.body,
    body_sha256: hash,
    topic: input.topic,
    method: input.method,
    tone: input.tone,
    language: input.language,
    hook_text: input.hookText ?? null,
    cta_key: input.ctaKey,
    prompt_version: input.promptVersion,
    experiment_id: input.experimentId ?? null,
    variant_key: input.variantKey ?? null,
    scheduled_at: input.scheduledAt ?? null,
    zodiac: input.zodiac ?? null,
  });
  if (error) throw new Error('POST_BACKEND_FAILURE');
  return {postId: requestId, bodySha256: hash, status: 'draft', replayed: false};
}
export async function approvePost(id: string, hash: string) {
  const {data, error} = await adminSupabase().rpc('fj_approve_post', {p_id: id, p_hash: hash});
  if (error || data !== true) throw new Error('POST_NOT_APPROVED');
  return {approved: true, postId: id, bodySha256: hash};
}
export async function publishPost(id: string) {
  if (process.env.THREADS_PUBLISH_ENABLED !== 'true') throw new Error('PUBLISH_DISABLED');
  const api = threads();
  const db = adminSupabase();
  const {data: p, error: pe} = await db
    .from('fortune_posts')
    .select('id,account_key,body,body_sha256')
    .eq('id', id)
    .single();
  if (pe || !p || p.account_key !== threadsAccount() || sha256(p.body) !== p.body_sha256)
    throw new Error('POST_INTEGRITY_ERROR');
  const {data: claim, error: ce} = await db.rpc('fj_claim_publish', {
    p_post_id: id,
    p_expected_hash: p.body_sha256,
  });
  if (ce || !claim) throw new Error('PUBLISH_NOT_CLAIMED');
  const run = claim as Run;
  if (!run.acquired) return {published: false, disposition: run.status};
  let containerId: string | null = null;
  try {
    containerId = await api.createTextContainer(p.body);
    const {data: saved, error: saveError} = await db
      .from('fortune_posts')
      .update({container_id: containerId})
      .eq('id', id)
      .eq('status', 'publishing')
      .select('id')
      .single();
    if (saveError || !saved) throw new Error('CONTAINER_PERSIST_FAILED');
    const external = await api.publishContainer(containerId);
    const {data, error} = await db.rpc('fj_finish_publish', {
      p_post_id: id,
      p_run_id: run.runId,
      p_external_id: external,
      p_container_id: containerId,
    });
    if (error || data !== true) throw new Error('PUBLISH_COMPLETION_FAILED');
    return {published: true, externalPostId: external, postId: id};
  } catch (e) {
    // A network error or a failed final DB write never implies the remote POST was not performed.
    await db.rpc('fj_finish_publish', {
      p_post_id: id,
      p_run_id: run.runId,
      p_external_id: null,
      p_container_id: containerId,
      p_error: safeError(e),
    });
    return {published: null, disposition: 'publish_unknown', postId: id, errorCode: safeError(e)};
  }
}
export async function collectPost(
  postId: string,
  key: string,
  target: number | null = null,
  kind: 'scheduled' | 'manual' | 'backfill_now' = 'manual',
  actor = 'owner_agent',
) {
  if (process.env.THREADS_INSIGHTS_ENABLED !== 'true') throw new Error('INSIGHTS_DISABLED');
  const api = threads();
  const db = adminSupabase();
  const {data: p, error} = await db
    .from('fortune_posts')
    .select('id,account_key,external_post_id,published_at')
    .eq('id', postId)
    .eq('status', 'published')
    .single();
  if (error || !p || p.account_key !== threadsAccount() || !p.external_post_id)
    throw new Error('POST_NOT_FOUND');
  const run = await begin('collect_post_metrics', key, postId, actor);
  if (!run.acquired) return {collected: false, status: run.status};
  try {
    const values = await api.postMetrics(p.external_post_id);
    if (Object.values(values).every((v) => v === null)) throw new Error('THREADS_METRICS_UNAVAILABLE');
    const {error: write} = await db.from('post_metric_snapshots').upsert(
      {
        post_id: postId,
        run_id: run.runId,
        collected_at: new Date().toISOString(),
        target_age_hours: target,
        snapshot_kind: kind,
        api_version: process.env.THREADS_API_VERSION,
        ...values,
      },
      {onConflict: 'run_id,post_id', ignoreDuplicates: true},
    );
    if (write) throw new Error('SNAPSHOT_BACKEND_FAILURE');
    await end(run, true);
    return {collected: true, postId};
  } catch (e) {
    await end(run, false, safeError(e));
    throw e;
  }
}
export async function collectAccount(key: string, since: string, until: string, actor = 'owner_agent') {
  if (process.env.THREADS_INSIGHTS_ENABLED !== 'true') throw new Error('INSIGHTS_DISABLED');
  const api = threads(),
    db = adminSupabase();
  const run = await begin('collect_account_metrics', key, null, actor);
  if (!run.acquired) return {collected: false, status: run.status};
  try {
    const a = new Date(since),
      b = new Date(until);
    if (
      !Number.isFinite(+a) ||
      !Number.isFinite(+b) ||
      +b <= +a ||
      +b - +a > 31 * 86400000 ||
      +b > Date.now() + 300000
    )
      throw new Error('INVALID_PERIOD');
    const values = await api.accountMetrics(a, b);
    if (!values.length) throw new Error('THREADS_METRICS_UNAVAILABLE');
    const collectedAt = new Date().toISOString();
    // Retries use the same run id; already committed metrics are retained, never overwritten.
    const {error} = await db.from('account_metric_snapshots').upsert(
      values.map((v) => ({
        ...v,
        account_key: threadsAccount(),
        run_id: run.runId,
        capture_key: run.runId,
        collected_at: collectedAt,
        api_version: process.env.THREADS_API_VERSION,
      })),
      {
        onConflict: 'capture_key,account_key,metric_name,period_kind,period_start,period_end',
        ignoreDuplicates: true,
      },
    );
    if (error) throw new Error('SNAPSHOT_BACKEND_FAILURE');
    await end(run, true);
    return {collected: true, rows: values.length};
  } catch (e) {
    await end(run, false, safeError(e));
    throw e;
  }
}
export async function importPosts(key: string, after?: string) {
  const api = threads(),
    db = adminSupabase();
  const run = await begin('import_posts', key);
  if (!run.acquired)
    return {
      imported: false,
      status: run.status,
      recovery:
        'Use a new operation key and the last confirmed cursor; upsert will skip existing external IDs.',
    };
  try {
    const result = await api.listPosts(after);
    if (result.posts.length) {
      const {error} = await db.from('fortune_posts').upsert(
        result.posts.map((p) => ({
          ...p,
          account_key: threadsAccount(),
          body_sha256: sha256(p.body),
          status: 'published',
        })),
        {onConflict: 'account_key,external_post_id', ignoreDuplicates: true},
      );
      if (error) throw new Error('IMPORT_BACKEND_FAILURE');
    }
    await end(run, true);
    return {
      imported: true,
      processed: result.posts.length,
      skipped: result.skipped,
      nextCursor: result.nextCursor,
      history: 'No historical 24h/72h/7d insights were fabricated.',
    };
  } catch (e) {
    await end(run, false, safeError(e));
    throw e;
  }
}
export async function report(from: string, until: string) {
  const db = adminSupabase();
  const {data: cohorts, error: ce} = await db.rpc('fj_cohort_report', {p_from: from, p_until: until});
  const {data: posts, error: pe} = await db
    .from('fj_post_24h')
    .select('*')
    .gte('published_at', from)
    .lt('published_at', until)
    .order('published_at')
    .limit(1001);
  const {data: mrr, error: me} = await db.from('fj_current_mrr').select('*');
  const {data: cash, error: be} = await db.rpc('fj_revenue_report', {p_from: from, p_until: until});
  const account = process.env.THREADS_ACCOUNT_ID;
  const follower = account ? await db.rpc('fj_follower_growth', {p_account: account, p_until: until}) : null;
  const {data: runs, error: re} = await db.rpc('fj_operation_report', {p_from: from, p_until: until});
  if (ce || pe || me || be || re || follower?.error) throw new Error('REPORT_BACKEND_FAILURE');
  return {
    cohorts,
    post24h: posts?.slice(0, 1000) ?? [],
    postRowsTruncated: (posts?.length ?? 0) > 1000,
    mrrByCurrency: mrr,
    cash,
    operations: runs,
    follower7d: follower?.data ?? null,
    caveats: [
      '24h observations require actual ages 24–26 hours; null is not zero.',
      'Cohorts contain consenting near-signup users only, not all visitors.',
      'MCP calculation success is not Google Sheets save success.',
      'No customer-host ChatGPT/Claude token or inference cost is observable.',
      'MRR and cash collections are separate; currencies are not combined.',
    ],
  };
}
export async function referralLink(postId: string) {
  const {data, error} = await adminSupabase()
    .from('fortune_posts')
    .select('id')
    .eq('id', postId)
    .eq('status', 'published')
    .single();
  if (error || !data) throw new Error('POST_NOT_FOUND');
  const token = issueReferral(process.env.ATTRIBUTION_HMAC_KEY ?? '', postId);
  return {url: `${appOrigin()}/login?ref=${encodeURIComponent(token)}`, expiresInDays: 7};
}
export async function recordRunCost(
  runId: string,
  cost: {
    model?: string;
    inputTokens?: number;
    outputTokens?: number;
    estimatedCost?: number;
    currency?: string;
  },
) {
  if ((cost.estimatedCost === undefined) !== (cost.currency === undefined)) throw new Error('INVALID_COST');
  const {data, error} = await adminSupabase()
    .from('automation_runs')
    .update({
      model: cost.model ?? null,
      input_tokens: cost.inputTokens ?? null,
      output_tokens: cost.outputTokens ?? null,
      estimated_cost: cost.estimatedCost ?? null,
      cost_currency: cost.currency ?? null,
      cost_source: 'external_reported',
    })
    .eq('id', runId)
    .select('id')
    .single();
  if (error || !data) throw new Error('RUN_NOT_FOUND');
  return {recorded: true, source: 'external_reported_not_provider_verified'};
}
export type ExternalRun = {
  task: 'weekly_analysis' | 'draft_post';
  startedAt: string;
  finishedAt: string;
  success: boolean;
  errorCode?: string;
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  estimatedCost?: number;
  currency?: string;
};
export async function recordExternalRun(requestId: string, input: ExternalRun) {
  const start = Date.parse(input.startedAt),
    finish = Date.parse(input.finishedAt);
  if (
    !Number.isFinite(start) ||
    !Number.isFinite(finish) ||
    finish < start ||
    finish > Date.now() + 300000 ||
    finish - start > 86400000
  )
    throw new Error('INVALID_RUN_PERIOD');
  if ((input.estimatedCost === undefined) !== (input.currency === undefined)) throw new Error('INVALID_COST');
  if (input.success && input.errorCode) throw new Error('INVALID_RUN_STATUS');
  const row = {
    task: input.task,
    idempotency_key: `external:${requestId}`,
    status: input.success ? 'succeeded' : 'failed',
    actor_kind: 'external_report',
    started_at: new Date(start).toISOString(),
    finished_at: new Date(finish).toISOString(),
    lease_expires_at: new Date(finish).toISOString(),
    duration_ms: finish - start,
    model: input.model ?? null,
    input_tokens: input.inputTokens ?? null,
    output_tokens: input.outputTokens ?? null,
    estimated_cost: input.estimatedCost ?? null,
    cost_currency: input.currency ?? null,
    cost_source: 'external_reported',
    error_code: input.errorCode ?? null,
  };
  const db = adminSupabase();
  const {error} = await db
    .from('automation_runs')
    .upsert(row, {onConflict: 'task,idempotency_key', ignoreDuplicates: true});
  if (error) throw new Error('RUN_BACKEND_FAILURE');
  const {data: stored, error: lookup} = await db
    .from('automation_runs')
    .select('*')
    .eq('task', row.task)
    .eq('idempotency_key', row.idempotency_key)
    .single();
  if (lookup || !stored) throw new Error('RUN_BACKEND_FAILURE');
  const times = ['started_at', 'finished_at', 'lease_expires_at'];
  const numbers = ['duration_ms', 'input_tokens', 'output_tokens', 'estimated_cost'];
  for (const [key, value] of Object.entries(row)) {
    const actual = stored[key];
    const same = times.includes(key)
      ? Date.parse(String(actual)) === Date.parse(String(value))
      : numbers.includes(key)
        ? value === null
          ? actual === null
          : actual !== null && Number(actual) === Number(value)
        : actual === value;
    if (!same) throw new Error('IDEMPOTENCY_CONFLICT');
  }
  return {recorded: true, runId: stored.id, source: 'external_reported_not_provider_verified'};
}
export async function maintenance() {
  const now = new Date(),
    day = now.toISOString().slice(0, 10),
    db = adminSupabase();
  const results: unknown[] = [];
  const purgeRun = await begin('purge', `purge:${day}`, null, 'server_cron');
  if (purgeRun.acquired) {
    const {error} = await db.rpc('fj_purge_expired');
    await end(purgeRun, !error, error ? 'PURGE_FAILED' : null);
    results.push({purged: !error});
  }
  if (process.env.THREADS_INSIGHTS_ENABLED !== 'true') return {results, insights: 'disabled'};
  const {data: posts, error} = await db
    .from('fortune_posts')
    .select('id,published_at')
    .eq('status', 'published')
    .eq('account_key', threadsAccount())
    .gte('published_at', new Date(+now - 170 * 3600000).toISOString())
    .order('published_at')
    .limit(250);
  if (error) throw new Error('MAINTENANCE_LOOKUP_FAILED');
  let collected = 0;
  for (const p of posts ?? []) {
    if (dueAges(p.published_at, now, []).length === 0) continue;
    const {data: snapshots, error: se} = await db
      .from('post_metric_snapshots')
      .select('target_age_hours')
      .eq('post_id', p.id)
      .eq('snapshot_kind', 'scheduled');
    if (se) throw new Error('SNAPSHOT_LOOKUP_FAILED');
    const ages = dueAges(
      p.published_at,
      now,
      (snapshots ?? []).map((s) => s.target_age_hours).filter((x): x is number => typeof x === 'number'),
    );
    for (const age of ages) {
      if (collected >= 3) break;
      try {
        results.push(await collectPost(p.id, `${p.id}:${age}h`, age, 'scheduled', 'server_cron'));
      } catch {
        results.push({postId: p.id, errorCode: 'SCHEDULED_SNAPSHOT_FAILED'});
      }
      collected++;
    }
    if (collected >= 3) break;
  }
  const today = new Date(`${day}T00:00:00Z`),
    yesterday = new Date(+today - 86400000);
  try {
    results.push(
      await collectAccount(`account:${day}`, yesterday.toISOString(), today.toISOString(), 'server_cron'),
    );
  } catch {
    results.push({errorCode: 'ACCOUNT_SNAPSHOT_FAILED'});
  }
  return {results, boundedPosts: 3};
}
