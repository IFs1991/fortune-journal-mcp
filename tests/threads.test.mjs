import test from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizePostMetrics,
  normalizeAccountMetrics,
  countOrNull,
  dueAges,
  importedPost,
} from '../src/domain/threads.ts';
const now = new Date('2026-10-14T00:00:00Z');
test('missing metrics remain null, a reported zero remains zero', () => {
  const m = normalizePostMetrics({data: [{name: 'likes', period: 'lifetime', values: [{value: 0}]}]});
  assert.equal(m.likes, 0);
  assert.equal(m.views, null);
});
test('metrics reported for an incompatible period are not accepted as lifetime values', () => {
  const m = normalizePostMetrics({data: [{name: 'views', period: 'day', values: [{value: 100}]}]});
  assert.equal(m.views, null);
});
test('counters reject negatives, strings, unsafe integers, and NaN', () => {
  for (const v of [-1, '12', NaN, Infinity, 2 ** 53, 0.5]) assert.equal(countOrNull(v), null);
  assert.equal(countOrNull(0), 0);
});
test('followers are stocks; daily and range metrics preserve separate boundaries', () => {
  const payload = {
    data: [
      {name: 'followers_count', total_value: {value: 42}},
      {name: 'views', period: 'day', values: [{value: 4, end_time: '2026-10-14T00:00:00Z'}]},
      {name: 'likes', total_value: {value: 3}},
    ],
  };
  const rows = normalizeAccountMetrics(payload, new Date('2026-10-13T00:00:00Z'), now);
  assert.equal(rows[0].period_start, null);
  assert.equal(rows[0].period_kind, 'point_in_time');
  assert.equal(rows[1].period_kind, 'day');
  assert.equal(rows[2].period_kind, 'range');
});
test('historical counters cannot be labeled as due 24h/72h snapshots', () => {
  assert.deepEqual(dueAges('2026-10-13T00:00:00Z', now, []), [24]);
  assert.deepEqual(dueAges('2026-10-13T00:00:00Z', now, [24]), []);
  assert.deepEqual(dueAges('2026-10-10T00:00:00Z', now, []), []);
  assert.deepEqual(dueAges('2026-10-06T23:00:00Z', now, []), [168]);
});
test('import preserves original timestamp; skips missing text and replies', () => {
  assert.equal(
    importedPost({id: '1', text: 'old post', timestamp: '2025-01-01T00:00:00Z'}).published_at,
    '2025-01-01T00:00:00.000Z',
  );
  assert.equal(importedPost({id: '1', text: '', timestamp: '2025-01-01T00:00:00Z'}), null);
  assert.equal(
    importedPost({id: '1', text: 'reply', timestamp: '2025-01-01T00:00:00Z', is_reply: true}),
    null,
  );
});

// ----- Threads client (fetch is faked; nothing reaches Meta) -----
import {ThreadsClient} from '../src/integrations/threads.ts';
const config = {accountId: '123', accessToken: 'test-token-not-live', apiVersion: 'v1.0'};
test('insights credentials are headers, not URL query strings', async () => {
  const calls = [];
  const fake = async (url, options) => {
    calls.push([String(url), options]);
    return Response.json({data: [{name: 'likes', period: 'lifetime', values: [{value: 3}]}]});
  };
  const out = await new ThreadsClient(config, fake).postMetrics('456');
  assert.equal(out.likes, 3);
  assert(!calls[0][0].includes('test-token'));
  assert.equal(calls[0][1].headers.Authorization, 'Bearer test-token-not-live');
});
test('followers fetch omits time filters and period metrics explicitly include them', async () => {
  const urls = [];
  const fake = async (url) => {
    urls.push(new URL(url));
    return Response.json({data: []});
  };
  await new ThreadsClient(config, fake).accountMetrics(
    new Date('2026-10-13T00:00:00Z'),
    new Date('2026-10-14T00:00:00Z'),
  );
  assert.equal(urls[0].searchParams.has('since'), false);
  assert.equal(urls[1].searchParams.has('since'), true);
});
test('remote publish is never automatically retried on transport uncertainty', async () => {
  let attempts = 0;
  const fake = async () => {
    attempts++;
    throw new Error('lost response');
  };
  await assert.rejects(() => new ThreadsClient(config, fake).publishContainer('1'), /THREADS_NETWORK_ERROR/);
  assert.equal(attempts, 1);
});
test('returned next URL cannot redirect the client to another host', async () => {
  let seen;
  const fake = async (url) => {
    seen = String(url);
    return Response.json({
      data: [],
      paging: {next: 'http://127.0.0.1/secrets', cursors: {after: 'cursor-value'}},
    });
  };
  const result = await new ThreadsClient(config, fake).listPosts();
  assert.equal(result.nextCursor, 'cursor-value');
  assert(seen.startsWith('https://graph.threads.net/'));
});
test('429 and permissions are distinct safe error codes', async () => {
  await assert.rejects(
    () => new ThreadsClient(config, async () => new Response('', {status: 429})).postMetrics('1'),
    /THREADS_RATE_LIMITED/,
  );
  await assert.rejects(
    () => new ThreadsClient(config, async () => new Response('', {status: 403})).postMetrics('1'),
    /THREADS_PERMISSION_DENIED/,
  );
});
test('malformed IDs and overlong text cannot become remote paths or posts', async () => {
  const api = new ThreadsClient(config, async () => {
    throw new Error('must not reach fetch');
  });
  await assert.rejects(() => api.postMetrics('../secrets'), /INVALID_POST_ID/);
  await assert.rejects(() => api.createTextContainer('x'.repeat(501)), /INVALID_POST_LENGTH/);
});
