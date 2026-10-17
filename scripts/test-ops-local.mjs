// LOCAL-ONLY integration test of the operator state machines against the local Supabase CLI stack's real
// Postgres: Threads publishing outcomes (success / failed / unknown), no automatic re-post, human resolution, and
// maintenance failure reporting. graph.threads.net is replaced by a scripted fake inside this process: nothing
// reaches Meta, and no real token exists here. Refuses any non-loopback database. Creates its own rows and
// removes them at the end.
// Usage: supabase start; node --experimental-strip-types --import ./tests/support/register.mjs scripts/test-ops-local.mjs
import {spawnSync} from 'node:child_process';
import {createHash, randomUUID} from 'node:crypto';

const status = JSON.parse(
  spawnSync('supabase', ['status', '-o', 'json'], {encoding: 'utf8', input: ''}).stdout || '{}',
);
const loopback = (u) => ['127.0.0.1', 'localhost', '[::1]'].includes(new URL(u).hostname);
if (!status.API_URL || !loopback(status.API_URL)) throw new Error('Refusing: loopback Supabase stack only.');
Object.assign(process.env, {
  NEXT_PUBLIC_SUPABASE_URL: status.API_URL,
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: status.PUBLISHABLE_KEY,
  SUPABASE_SECRET_KEY: status.SECRET_KEY,
  APP_ORIGIN: 'http://localhost:3000',
  THREADS_ACCOUNT_ID: '9000000001',
  THREADS_ACCESS_TOKEN: 'fake-local-test-token-not-a-real-credential',
  THREADS_API_VERSION: 'v1.0',
  THREADS_PUBLISH_ENABLED: 'true',
  THREADS_INSIGHTS_ENABLED: 'false',
});

// ----- Scripted Threads fake: every graph.threads.net call takes the next scripted answer for its endpoint -----
const realFetch = globalThis.fetch;
const script = {threads: [], threads_publish: []};
const calls = {threads: 0, threads_publish: 0};
globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === 'string' ? input : (input.url ?? String(input)));
  if (url.hostname !== 'graph.threads.net') return realFetch(input, init);
  const endpoint = url.pathname.endsWith('/threads_publish') ? 'threads_publish' : 'threads';
  calls[endpoint] += 1;
  const next = script[endpoint].shift();
  if (!next) throw new Error(`unscripted Threads call to ${endpoint}`);
  if (next === 'network') throw new TypeError('fetch failed');
  return new Response(typeof next.body === 'string' ? next.body : JSON.stringify(next.body), {
    status: next.status ?? 200,
    headers: {'content-type': 'application/json'},
  });
};

const {adminSupabase} = await import('../src/lib/supabase/server.ts');
const {publishPost} = await import('../src/ops/posts.ts');
const {runCommand} = await import('../src/ops/commands.ts');
const {maintenance} = await import('../src/ops/maintenance.ts');
const db = adminSupabase();

const results = [];
let failures = 0;
async function step(name, fn) {
  try {
    await fn();
    results.push({name, result: 'PASS'});
    console.log('PASS', name);
  } catch (e) {
    failures++;
    results.push({name, result: 'FAIL', error: String(e?.message ?? e).slice(0, 300)});
    console.log('FAIL', name, '-', String(e?.message ?? e).slice(0, 300));
  }
}
const ok = (cond, msg) => {
  if (!cond) throw new Error(msg);
};
const created = [];
async function approvedPost(label) {
  const id = randomUUID();
  const body = `Local ops test post ${label} ${id}`;
  const hash = createHash('sha256').update(body).digest('hex');
  const {error} = await db.from('fortune_posts').insert({
    id,
    account_key: process.env.THREADS_ACCOUNT_ID,
    body,
    body_sha256: hash,
  });
  if (error) throw new Error(`fixture: ${error.message}`);
  created.push(id);
  const {data} = await db.rpc('fj_approve_post', {p_id: id, p_hash: hash});
  ok(data === true, 'fixture approval failed');
  return id;
}
const state = async (postId) => {
  const {data: post} = await db
    .from('fortune_posts')
    .select('status,external_post_id')
    .eq('id', postId)
    .single();
  const {data: runs} = await db
    .from('automation_runs')
    .select('status,attempts,error_code')
    .eq('post_id', postId)
    .eq('task', 'publish_post');
  return {post: post?.status, externalId: post?.external_post_id, run: runs?.[0]};
};
const reset = () => {
  script.threads.length = 0;
  script.threads_publish.length = 0;
  calls.threads = 0;
  calls.threads_publish = 0;
};
const unique = () => String(Date.now()).slice(-9) + String(Math.floor(Math.random() * 1e6)).padStart(6, '0');
const day = new Date().toISOString().slice(0, 10);
let purgeBefore = null;

try {
  await step('Publish success: Threads id recorded, run succeeded', async () => {
    reset();
    const postId = await approvedPost('success');
    const externalId = unique();
    script.threads.push({body: {id: unique()}});
    script.threads_publish.push({body: {id: externalId}});
    const out = await publishPost(postId);
    ok(out.outcome === 'success' && out.externalPostId === externalId, JSON.stringify(out));
    const s = await state(postId);
    ok(
      s.post === 'published' && s.externalId === externalId && s.run.status === 'succeeded',
      JSON.stringify(s),
    );
  });

  await step(
    'Container creation fails: outcome failed (not published), post back to approved, explicit retry works',
    async () => {
      reset();
      const postId = await approvedPost('container-fail');
      script.threads.push({status: 500, body: {error: {message: 'server'}}});
      const out = await publishPost(postId);
      ok(
        out.outcome === 'failed' && out.recorded === true && calls.threads_publish === 0,
        JSON.stringify(out),
      );
      let s = await state(postId);
      ok(s.post === 'approved' && s.run.status === 'failed', `after failure ${JSON.stringify(s)}`);
      script.threads.push({body: {id: unique()}});
      script.threads_publish.push({body: {id: unique()}});
      const again = await publishPost(postId);
      s = await state(postId);
      ok(
        again.outcome === 'success' && s.post === 'published' && s.run.attempts === 2,
        `retry ${JSON.stringify(again)} ${JSON.stringify(s)}`,
      );
    },
  );

  await step(
    'Publish call loses its response: unknown is recorded, never re-posted, resolved by a person',
    async () => {
      reset();
      const postId = await approvedPost('lost-response');
      script.threads.push({body: {id: unique()}});
      script.threads_publish.push('network');
      const out = await publishPost(postId);
      ok(
        out.outcome === 'unknown' && out.recorded === true && out.errorCode === 'THREADS_NETWORK_ERROR',
        JSON.stringify(out),
      );
      let s = await state(postId);
      ok(s.post === 'publish_unknown' && s.run.status === 'unknown', JSON.stringify(s));
      const before = {...calls};
      const again = await publishPost(postId);
      ok(
        again.published === false &&
          again.disposition === 'publish_unknown' &&
          calls.threads === before.threads &&
          calls.threads_publish === before.threads_publish,
        `unknown was re-posted: ${JSON.stringify(again)}`,
      );
      const resolved = await runCommand({
        requestId: randomUUID(),
        action: 'resolve_publish',
        postId,
        outcome: 'not_published',
      });
      s = await state(postId);
      ok(
        resolved.status === 'approved' &&
          s.post === 'approved' &&
          s.run.error_code === 'RESOLVED_NOT_PUBLISHED',
        JSON.stringify(s),
      );
      script.threads.push({body: {id: unique()}});
      script.threads_publish.push({body: {id: unique()}});
      ok((await publishPost(postId)).outcome === 'success', 'resolved post could not be published');
    },
  );

  await step(
    'Malformed success response is unknown; resolving as published records the live id',
    async () => {
      reset();
      const postId = await approvedPost('malformed');
      script.threads.push({body: {id: unique()}});
      script.threads_publish.push({body: 'not json'});
      const out = await publishPost(postId);
      ok(out.outcome === 'unknown' && out.errorCode === 'THREADS_RESPONSE_SHAPE', JSON.stringify(out));
      const liveId = unique();
      await runCommand({
        requestId: randomUUID(),
        action: 'resolve_publish',
        postId,
        outcome: 'published',
        externalPostId: liveId,
      });
      const s = await state(postId);
      ok(
        s.post === 'published' && s.externalId === liveId && s.run.status === 'succeeded',
        JSON.stringify(s),
      );
    },
  );

  await step(
    'Threads accepted but the success cannot be recorded: unknown with the received id, not silent',
    async () => {
      reset();
      const first = await approvedPost('taken-id');
      const takenId = unique();
      script.threads.push({body: {id: unique()}});
      script.threads_publish.push({body: {id: takenId}});
      ok((await publishPost(first)).outcome === 'success', 'fixture publish');
      // A second post receives an id the ledger already holds: the success write violates a unique key.
      const postId = await approvedPost('record-fails');
      script.threads.push({body: {id: unique()}});
      script.threads_publish.push({body: {id: takenId}});
      const out = await publishPost(postId);
      ok(
        out.outcome === 'unknown' &&
          out.externalPostId === takenId &&
          out.recorded === true &&
          out.errorCode === 'PUBLISH_COMPLETION_FAILED',
        JSON.stringify(out),
      );
      ok((await state(postId)).post === 'publish_unknown', 'not recorded as unknown');
      let refused = '';
      try {
        await runCommand({
          requestId: randomUUID(),
          action: 'resolve_publish',
          postId,
          outcome: 'published',
          externalPostId: takenId,
        });
      } catch (error) {
        refused = error.message;
      }
      ok(refused === 'EXTERNAL_ID_CONFLICT', `conflicting resolution: ${refused}`);
    },
  );

  await step('Maintenance: a purge out of attempts is a permanent failure, never "OK"', async () => {
    const {data} = await db
      .from('automation_runs')
      .select('*')
      .eq('task', 'purge')
      .eq('idempotency_key', `purge:${day}`)
      .maybeSingle();
    purgeBefore = data;
    if (!data) {
      const first = await maintenance();
      ok(first.ok && first.results[0].status === 'succeeded', `fresh purge ${JSON.stringify(first)}`);
    }
    const exhausted = await db
      .from('automation_runs')
      .update({
        status: 'failed',
        attempts: 3,
        error_code: 'PURGE_FAILED',
        finished_at: new Date().toISOString(),
      })
      .eq('task', 'purge')
      .eq('idempotency_key', `purge:${day}`);
    ok(!exhausted.error, 'fixture update');
    const out = await maintenance();
    ok(
      out.ok === false &&
        out.failures === 1 &&
        out.permanentFailures === 1 &&
        out.results[0].errorCode === 'PURGE_RETRIES_EXHAUSTED' &&
        out.results[0].retryable === false,
      JSON.stringify(out),
    );
    await db
      .from('automation_runs')
      .update({status: 'succeeded', error_code: null})
      .eq('task', 'purge')
      .eq('idempotency_key', `purge:${day}`);
    const done = await maintenance();
    ok(done.ok && done.results[0].status === 'already_done', JSON.stringify(done));
  });
} finally {
  globalThis.fetch = realFetch;
  if (created.length) {
    await db.from('automation_runs').delete().in('post_id', created);
    await db.from('fortune_posts').delete().in('id', created);
  }
  if (purgeBefore) {
    const {id, ...row} = purgeBefore;
    await db.from('automation_runs').update(row).eq('id', id);
  }
}
console.log(`${results.length - failures} passed / ${failures} failed`);
const outIndex = process.argv.indexOf('--out');
if (outIndex > 0) {
  const {writeFileSync} = await import('node:fs');
  writeFileSync(
    process.argv[outIndex + 1],
    JSON.stringify(
      {ranAt: new Date().toISOString(), target: 'local Supabase stack (loopback), fake Threads', results},
      null,
      2,
    ) + '\n',
  );
}
process.exitCode = failures ? 1 : 0;
