import type {SnapshotAge} from '@/src/domain/threads';
import {isEnabled} from '@/src/lib/env';
import {adminSupabase} from '@/src/lib/supabase/server';
import {threadsAccount, threadsClient} from '@/src/ops/posts';
import {runOnce} from '@/src/ops/runs';

/** Threads Insights snapshots. Values are stored as observed with their time and API version; NULL is not 0. */
type Actor = 'owner_agent' | 'server_cron';
type SnapshotKind = 'scheduled' | 'manual' | 'backfill_now';

export async function collectPostMetrics(
  postId: string,
  key: string,
  options: {targetAgeHours?: SnapshotAge; kind?: SnapshotKind; actor?: Actor} = {},
) {
  if (!isEnabled('THREADS_INSIGHTS_ENABLED')) throw new Error('INSIGHTS_DISABLED');
  const api = threadsClient();
  const db = adminSupabase();
  const {data: post, error} = await db
    .from('fortune_posts')
    .select('account_key,external_post_id')
    .eq('id', postId)
    .eq('status', 'published')
    .single();
  if (error || !post || post.account_key !== threadsAccount() || !post.external_post_id)
    throw new Error('POST_NOT_FOUND');

  const outcome = await runOnce('collect_post_metrics', key, {postId, actor: options.actor}, async (run) => {
    const metrics = await api.postMetrics(post.external_post_id);
    if (Object.values(metrics).every((value) => value === null))
      throw new Error('THREADS_METRICS_UNAVAILABLE');
    const {error: writeError} = await db.from('post_metric_snapshots').upsert(
      {
        post_id: postId,
        run_id: run.runId,
        collected_at: new Date().toISOString(),
        target_age_hours: options.targetAgeHours ?? null,
        snapshot_kind: options.kind ?? 'manual',
        api_version: process.env.THREADS_API_VERSION,
        ...metrics,
      },
      {onConflict: 'post_id,run_id', ignoreDuplicates: true},
    );
    if (writeError) throw new Error('SNAPSHOT_BACKEND_FAILURE');
  });
  return outcome.acquired
    ? {collected: true as const, postId}
    : {collected: false as const, status: outcome.status, exhausted: outcome.exhausted ?? false};
}

const MAX_PERIOD_MS = 31 * 86_400_000;

export async function collectAccountMetrics(
  key: string,
  since: string,
  until: string,
  actor: Actor = 'owner_agent',
) {
  if (!isEnabled('THREADS_INSIGHTS_ENABLED')) throw new Error('INSIGHTS_DISABLED');
  const api = threadsClient();
  const account = threadsAccount();
  const start = new Date(since);
  const end = new Date(until);
  const validPeriod =
    Number.isFinite(+start) &&
    Number.isFinite(+end) &&
    +end > +start &&
    +end - +start <= MAX_PERIOD_MS &&
    +end <= Date.now() + 300_000;
  if (!validPeriod) throw new Error('INVALID_PERIOD');

  const outcome = await runOnce('collect_account_metrics', key, {actor}, async (run) => {
    const metrics = await api.accountMetrics(start, end);
    if (!metrics.length) throw new Error('THREADS_METRICS_UNAVAILABLE');
    const collectedAt = new Date().toISOString();
    const rows = metrics.map((metric) => ({
      ...metric,
      account_key: account,
      run_id: run.runId,
      collected_at: collectedAt,
      api_version: process.env.THREADS_API_VERSION,
    }));
    // A retry of the same run keeps rows already committed; it never overwrites them.
    const {error} = await adminSupabase().from('account_metric_snapshots').upsert(rows, {
      onConflict: 'run_id,account_key,metric_name,period_kind,period_start,period_end',
      ignoreDuplicates: true,
    });
    if (error) throw new Error('SNAPSHOT_BACKEND_FAILURE');
    return rows.length;
  });
  return outcome.acquired
    ? {collected: true as const, rows: outcome.value}
    : {collected: false as const, status: outcome.status, exhausted: outcome.exhausted ?? false};
}
