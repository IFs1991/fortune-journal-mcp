import {dueAges, type SnapshotAge} from '@/src/domain/threads';
import {isEnabled} from '@/src/lib/env';
import {adminSupabase} from '@/src/lib/supabase/server';
import {collectAccountMetrics, collectPostMetrics} from '@/src/ops/insights';
import {threadsAccount} from '@/src/ops/posts';
import {MAX_RUN_ATTEMPTS, RunFailure, runOnce, safeErrorCode} from '@/src/ops/runs';

/** Snapshot calls per cron run, so one run always finishes well inside the function time limit. */
const MAX_POST_SNAPSHOTS = 3;
const HOUR_MS = 3_600_000;

/**
 * One maintenance step. `failed` is never success: `retryable` says whether a later cron run will try the same
 * key again by itself (attempts left, transient cause) or a person must act (attempts exhausted, configuration or
 * permission). Only fixed codes and ids of operator posts appear here; no payloads, tokens or customer data.
 */
export type StepResult =
  | {step: string; status: 'succeeded' | 'already_done' | 'in_progress'; postId?: string}
  | {step: string; status: 'failed'; errorCode: string; retryable: boolean; postId?: string};

/** Causes that another attempt with the same configuration cannot fix. */
const PERMANENT_CODES = new Set([
  'THREADS_NOT_CONFIGURED',
  'THREADS_PERMISSION_DENIED',
  'SECRET_NOT_CONFIGURED',
  'INVALID_PERIOD',
  'POST_NOT_FOUND',
  'IDEMPOTENCY_CONFLICT',
]);

/** Outcome of a run that was not acquired: finished earlier, held by another invocation, or out of attempts. */
export function refusedRun(
  step: string,
  lease: {status: string; exhausted?: boolean; errorCode?: string | null},
  postId?: string,
): StepResult {
  if (lease.exhausted || lease.status === 'failed' || lease.status === 'unknown') {
    const errorCode = `${step.toUpperCase()}_RETRIES_EXHAUSTED`;
    return {step, status: 'failed', errorCode, retryable: false, ...(postId ? {postId} : {})};
  }
  const status = lease.status === 'succeeded' ? 'already_done' : 'in_progress';
  return {step, status, ...(postId ? {postId} : {})};
}

/** Outcome of an attempt that threw. */
export function failedRun(step: string, error: unknown, postId?: string): StepResult {
  const errorCode = safeErrorCode(error);
  const attemptsLeft = !(error instanceof RunFailure) || error.attempt < MAX_RUN_ATTEMPTS;
  return {
    step,
    status: 'failed',
    errorCode,
    retryable: attemptsLeft && !PERMANENT_CODES.has(errorCode),
    ...(postId ? {postId} : {}),
  };
}

export function summarize(results: StepResult[]) {
  const failed = results.filter((result) => result.status === 'failed');
  return {
    ok: failed.length === 0,
    failures: failed.length,
    permanentFailures: failed.filter((result) => result.status === 'failed' && !result.retryable).length,
    errorCodes: [...new Set(failed.map((result) => (result.status === 'failed' ? result.errorCode : '')))],
  };
}

/**
 * Hourly cron: retention purge (once per UTC day), then bounded scheduled Insights collection when enabled.
 * Never publishes. Each step reports its own outcome so one failure does not hide the others.
 */
export async function maintenance(now = new Date()) {
  const day = now.toISOString().slice(0, 10);
  const results: StepResult[] = [];

  try {
    const purge = await runOnce('purge', `purge:${day}`, {actor: 'server_cron'}, async () => {
      const {error} = await adminSupabase().rpc('fj_purge_expired');
      if (error) throw new Error('PURGE_FAILED');
    });
    results.push(purge.acquired ? {step: 'purge', status: 'succeeded'} : refusedRun('purge', purge));
  } catch (error) {
    results.push(failedRun('purge', error));
  }
  if (!isEnabled('THREADS_INSIGHTS_ENABLED')) return {...summarize(results), results, insights: 'disabled'};

  let due: [string, SnapshotAge][] = [];
  try {
    due = await duePostSnapshots(now);
  } catch (error) {
    results.push(failedRun('snapshot_lookup', error));
  }
  for (const [postId, age] of due) {
    try {
      const outcome = await collectPostMetrics(postId, `${postId}:${age}h`, {
        targetAgeHours: age,
        kind: 'scheduled',
        actor: 'server_cron',
      });
      results.push(
        outcome.collected
          ? {step: 'post_snapshot', status: 'succeeded', postId}
          : refusedRun('post_snapshot', outcome, postId),
      );
    } catch (error) {
      results.push(failedRun('post_snapshot', error, postId));
    }
  }

  const today = new Date(`${day}T00:00:00Z`);
  const yesterday = new Date(+today - 24 * HOUR_MS);
  try {
    const outcome = await collectAccountMetrics(
      `account:${day}`,
      yesterday.toISOString(),
      today.toISOString(),
      'server_cron',
    );
    results.push(
      outcome.collected
        ? {step: 'account_snapshot', status: 'succeeded'}
        : refusedRun('account_snapshot', outcome),
    );
  } catch (error) {
    results.push(failedRun('account_snapshot', error));
  }
  return {...summarize(results), results, boundedPosts: MAX_POST_SNAPSHOTS};
}

/** Published posts whose 24/72/168h snapshot is due now and not yet taken (two queries, no per-post lookup). */
async function duePostSnapshots(now: Date): Promise<[string, SnapshotAge][]> {
  const db = adminSupabase();
  const {data: posts, error} = await db
    .from('fortune_posts')
    .select('id,published_at')
    .eq('status', 'published')
    .eq('account_key', threadsAccount())
    .gte('published_at', new Date(+now - 170 * HOUR_MS).toISOString())
    .order('published_at')
    .limit(250);
  if (error) throw new Error('MAINTENANCE_LOOKUP_FAILED');
  if (!posts?.length) return [];

  const {data: taken, error: snapshotError} = await db
    .from('post_metric_snapshots')
    .select('post_id,target_age_hours')
    .in(
      'post_id',
      posts.map((post) => post.id),
    )
    .eq('snapshot_kind', 'scheduled');
  if (snapshotError) throw new Error('SNAPSHOT_LOOKUP_FAILED');

  const due: [string, SnapshotAge][] = [];
  for (const post of posts) {
    const existing = (taken ?? [])
      .filter((row) => row.post_id === post.id)
      .map((row) => Number(row.target_age_hours));
    for (const age of dueAges(post.published_at, now, existing)) {
      if (due.length < MAX_POST_SNAPSHOTS) due.push([post.id, age]);
    }
  }
  return due;
}
