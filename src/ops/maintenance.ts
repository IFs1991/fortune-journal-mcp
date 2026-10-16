import {dueAges, type SnapshotAge} from '@/src/domain/threads';
import {isEnabled} from '@/src/lib/env';
import {adminSupabase} from '@/src/lib/supabase/server';
import {collectAccountMetrics, collectPostMetrics} from '@/src/ops/insights';
import {threadsAccount} from '@/src/ops/posts';
import {runOnce} from '@/src/ops/runs';

/** Snapshot calls per cron run, so one run always finishes well inside the function time limit. */
const MAX_POST_SNAPSHOTS = 3;
const HOUR_MS = 3_600_000;

/**
 * Hourly cron: retention purge (once per UTC day), then bounded scheduled Insights collection when enabled.
 * Never publishes. Each step reports its own failure code so one failure does not hide the others.
 */
export async function maintenance(now = new Date()) {
  const day = now.toISOString().slice(0, 10);
  const results: Record<string, unknown>[] = [];

  try {
    const purge = await runOnce('purge', `purge:${day}`, {actor: 'server_cron'}, async () => {
      const {error} = await adminSupabase().rpc('fj_purge_expired');
      if (error) throw new Error('PURGE_FAILED');
    });
    // Not acquired = today's purge already ran (or is running) in an earlier invocation.
    if (purge.acquired) results.push({purged: true});
  } catch {
    results.push({purged: false});
  }
  if (!isEnabled('THREADS_INSIGHTS_ENABLED')) return {results, insights: 'disabled'};

  for (const [postId, age] of await duePostSnapshots(now)) {
    try {
      results.push(
        await collectPostMetrics(postId, `${postId}:${age}h`, {
          targetAgeHours: age,
          kind: 'scheduled',
          actor: 'server_cron',
        }),
      );
    } catch {
      results.push({postId, errorCode: 'SCHEDULED_SNAPSHOT_FAILED'});
    }
  }

  const today = new Date(`${day}T00:00:00Z`);
  const yesterday = new Date(+today - 24 * HOUR_MS);
  try {
    results.push(
      await collectAccountMetrics(
        `account:${day}`,
        yesterday.toISOString(),
        today.toISOString(),
        'server_cron',
      ),
    );
  } catch {
    results.push({errorCode: 'ACCOUNT_SNAPSHOT_FAILED'});
  }
  return {results, boundedPosts: MAX_POST_SNAPSHOTS};
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
