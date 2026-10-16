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

export async function publishPost(postId: string) {
  if (!isEnabled('THREADS_PUBLISH_ENABLED')) throw new Error('PUBLISH_DISABLED');
  const api = threadsClient();
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
  if (!run.acquired) return {published: false, disposition: run.status};

  let containerId: string | null = null;
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
    const externalPostId = await api.publishContainer(containerId);
    const {data: finished, error: finishError} = await db.rpc('fj_finish_publish', {
      p_post_id: postId,
      p_run_id: run.runId,
      p_external_id: externalPostId,
      p_container_id: containerId,
    });
    if (finishError || finished !== true) throw new Error('PUBLISH_COMPLETION_FAILED');
    return {published: true, externalPostId, postId};
  } catch (error) {
    // A network error or a failed final write never proves the remote POST did not happen: record unknown.
    await db.rpc('fj_finish_publish', {
      p_post_id: postId,
      p_run_id: run.runId,
      p_external_id: null,
      p_container_id: containerId,
      p_error: safeErrorCode(error),
    });
    return {published: null, disposition: 'publish_unknown', postId, errorCode: safeErrorCode(error)};
  }
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
