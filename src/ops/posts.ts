import {issueReferral, sha256} from '@/src/domain/security';
import {ThreadsClient} from '@/src/integrations/threads';
import {appOrigin, isEnabled} from '@/src/lib/env';
import {secret} from '@/src/lib/secrets';
import {adminSupabase} from '@/src/lib/supabase/server';
import {parseRunLease, runOnce, safeErrorCode} from '@/src/ops/runs';

/** Operator-owned Threads posts: draft → approve (body hash) → publish (never re-posted when unknown). */
export function threadsAccount(): string {
  const account = process.env.THREADS_ACCOUNT_ID;
  if (!account || !/^\d{1,80}$/.test(account)) throw new Error('THREADS_NOT_CONFIGURED');
  return account;
}

export function threadsClient(): ThreadsClient {
  return new ThreadsClient({
    accountId: process.env.THREADS_ACCOUNT_ID ?? '',
    accessToken: process.env.THREADS_ACCESS_TOKEN ?? '',
    apiVersion: process.env.THREADS_API_VERSION ?? '',
  });
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

const UNIQUE_VIOLATION = '23505';

/** The requestId becomes the post id, so a retried draft is a replay (same body) or a conflict. */
export async function draftPost(requestId: string, input: DraftInput) {
  const db = adminSupabase();
  const bodySha256 = sha256(input.body);
  const {error} = await db.from('fortune_posts').insert({
    id: requestId,
    account_key: threadsAccount(),
    body: input.body,
    body_sha256: bodySha256,
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
  if (!error) return {postId: requestId, bodySha256, status: 'draft', replayed: false};
  if (error.code !== UNIQUE_VIOLATION) throw new Error('POST_BACKEND_FAILURE');

  const {data: existing, error: lookupError} = await db
    .from('fortune_posts')
    .select('body_sha256,status')
    .eq('id', requestId)
    .single();
  if (lookupError || !existing) throw new Error('POST_BACKEND_FAILURE');
  if (existing.body_sha256 !== bodySha256) throw new Error('IDEMPOTENCY_CONFLICT');
  return {postId: requestId, bodySha256, status: existing.status, replayed: true};
}

export async function approvePost(postId: string, bodySha256: string) {
  const {data, error} = await adminSupabase().rpc('fj_approve_post', {p_id: postId, p_hash: bodySha256});
  if (error || data !== true) throw new Error('POST_NOT_APPROVED');
  return {approved: true, postId, bodySha256};
}

/**
 * Publishes one approved post at most once. Outcomes:
 *  - success: Threads returned the post id and it was recorded.
 *  - failed: the error happened before the publish call (container creation or saving it), so nothing can be
 *    live; the post is back to 'approved' and a new explicit publish_post may try again.
 *  - unknown: the publish call was sent but its result is not confirmed (timeout, lost or malformed response, or
 *    the success could not be recorded). Never re-posted automatically: a person checks the Threads profile and
 *    calls resolve_publish. Every unknown is an automation_runs row (status unknown) and an FJ_PUBLISH_UNKNOWN log.
 */
export async function publishPost(postId: string, api: ThreadsClient = threadsClient()) {
  if (!isEnabled('THREADS_PUBLISH_ENABLED')) throw new Error('PUBLISH_DISABLED');
  const db = adminSupabase();
  const {data: post, error: postError} = await db
    .from('fortune_posts')
    .select('account_key,body,body_sha256')
    .eq('id', postId)
    .single();
  if (postError || !post || post.account_key !== threadsAccount() || sha256(post.body) !== post.body_sha256) {
    throw new Error('POST_INTEGRITY_ERROR');
  }
  const {data: claimed, error: claimError} = await db.rpc('fj_claim_publish', {
    p_post_id: postId,
    p_expected_hash: post.body_sha256,
  });
  if (claimError) throw new Error('PUBLISH_NOT_CLAIMED');
  const run = parseRunLease(claimed);
  if (!run.acquired) return {published: false, outcome: 'not_claimed', disposition: run.status, postId};

  const finish = async (
    externalId: string | null,
    containerId: string | null,
    code: string | null,
    notPublished = false,
  ) => {
    const {data, error} = await db.rpc('fj_finish_publish', {
      p_post_id: postId,
      p_run_id: run.runId,
      p_external_id: externalId,
      p_container_id: containerId,
      p_error: code,
      p_not_published: notPublished,
    });
    return !error && data === true;
  };

  let containerId: string;
  try {
    containerId = await api.createTextContainer(post.body);
    const {data: saved, error: saveError} = await db
      .from('fortune_posts')
      .update({container_id: containerId})
      .eq('id', postId)
      .eq('status', 'publishing')
      .select('id')
      .single();
    if (saveError || !saved) throw new Error('CONTAINER_PERSIST_FAILED');
  } catch (error) {
    // The publish call was never made: definitely not live.
    const errorCode = safeErrorCode(error);
    const recorded = await finish(null, null, errorCode, true);
    console.error(JSON.stringify({code: 'FJ_PUBLISH_FAILED', postId, errorCode, recorded}));
    return {
      published: false,
      outcome: 'failed',
      disposition: 'not_published',
      retryable: true,
      postId,
      errorCode,
      recorded,
    };
  }

  let externalPostId: string | null = null;
  try {
    externalPostId = await api.publishContainer(containerId);
    if (!(await finish(externalPostId, containerId, null))) throw new Error('PUBLISH_COMPLETION_FAILED');
    return {published: true, outcome: 'success', externalPostId, postId};
  } catch (error) {
    const errorCode = safeErrorCode(error);
    if (externalPostId !== null) {
      // Threads confirmed the post; only recording failed. Retry the write once, then read the state back.
      if (await finish(externalPostId, containerId, null))
        return {published: true, outcome: 'success', externalPostId, postId};
      const {data: row} = await db
        .from('fortune_posts')
        .select('status,external_post_id')
        .eq('id', postId)
        .single();
      if (row?.status === 'published' && row.external_post_id === externalPostId)
        return {published: true, outcome: 'success', externalPostId, postId};
    }
    const recorded = await finish(null, containerId, errorCode);
    console.error(JSON.stringify({code: 'FJ_PUBLISH_UNKNOWN', postId, errorCode, recorded}));
    return {
      published: null,
      outcome: 'unknown',
      disposition: 'publish_unknown',
      postId,
      errorCode,
      recorded,
      // A Threads id we did receive, so the operator can resolve without searching.
      ...(externalPostId ? {externalPostId} : {}),
      recovery:
        'Do not publish again. Check the Threads profile, then resolve_publish with the live post id, or with ' +
        'outcome not_published if it is absent; only then may publish_post run again.',
    };
  }
}

/** Human decision on a publish_unknown post (see publishPost). */
export async function resolvePublish(postId: string, externalPostId: string | null) {
  const {data, error} = await adminSupabase().rpc('fj_resolve_publish', {
    p_post_id: postId,
    p_external_id: externalPostId,
  });
  if (error) {
    if (error.message === 'POST_NOT_UNKNOWN') throw new Error('POST_NOT_UNKNOWN');
    if (error.code === UNIQUE_VIOLATION) throw new Error('EXTERNAL_ID_CONFLICT');
    throw new Error('POST_BACKEND_FAILURE');
  }
  return data as {resolved: boolean; status: string};
}

/** Imports one page of already-published posts. Existing external ids are skipped, never overwritten. */
export async function importPosts(requestId: string, after?: string) {
  const api = threadsClient();
  const account = threadsAccount();
  const outcome = await runOnce('import_posts', requestId, {}, async () => {
    const page = await api.listPosts(after);
    if (page.posts.length) {
      const rows = page.posts.map((post) => ({
        ...post,
        account_key: account,
        body_sha256: sha256(post.body),
        status: 'published',
      }));
      const {error} = await adminSupabase()
        .from('fortune_posts')
        .upsert(rows, {onConflict: 'account_key,external_post_id', ignoreDuplicates: true});
      if (error) throw new Error('IMPORT_BACKEND_FAILURE');
    }
    return page;
  });
  if (!outcome.acquired) {
    return {
      imported: false,
      status: outcome.status,
      recovery:
        'Use a new operation key and the last confirmed cursor; upsert will skip existing external IDs.',
    };
  }
  return {
    imported: true,
    processed: outcome.value.posts.length,
    skipped: outcome.value.skipped,
    nextCursor: outcome.value.nextCursor,
    history: 'No historical 24h/72h/7d insights were fabricated.',
  };
}

/** Signed, expiring link carrying only the public post id (no person-level tracking id). */
export async function referralLink(postId: string) {
  const {data, error} = await adminSupabase()
    .from('fortune_posts')
    .select('id')
    .eq('id', postId)
    .eq('status', 'published')
    .single();
  if (error || !data) throw new Error('POST_NOT_FOUND');
  const token = issueReferral(secret('ATTRIBUTION_HMAC_KEY'), postId);
  return {url: `${appOrigin()}/login?ref=${encodeURIComponent(token)}`, expiresInDays: 7};
}
