import test from 'node:test';
import assert from 'node:assert/strict';
import {
  sha256,
  requestFingerprint,
  signOps,
  verifyOps,
  issueReferral,
  readReferral,
  readBoundedText,
  requireSecret,
} from '../src/domain/security.ts';
const key = 'a'.repeat(64),
  ts = '1791936000',
  id = '106a4935-79ed-4e58-9804-841a85095caa';
test('HMAC fingerprints bind the account, operation, feature and exact normalized input', () => {
  const a = requestFingerprint(key, 'user1', id, 'calculate_numerology', ['v1', '1991-09-12', '2026-10-14']);
  assert.equal(a.length, 64);
  assert.equal(
    a,
    requestFingerprint(key, 'user1', id, 'calculate_numerology', ['v1', '1991-09-12', '2026-10-14']),
  );
  assert.notEqual(
    a,
    requestFingerprint(key, 'user2', id, 'calculate_numerology', ['v1', '1991-09-12', '2026-10-14']),
  );
  assert.notEqual(a, sha256('1991-09-12'));
});
test('ops signature binds body, path, method and timestamp', () => {
  const body = '{"action":"report"}',
    sig = signOps(key, 'POST', '/api/ops', ts, body);
  assert.equal(verifyOps(key, 'POST', '/api/ops', ts, sig, body, Number(ts)), true);
  for (const [method, path, data] of [
    ['GET', '/api/ops', body],
    ['POST', '/api/account/delete', body],
    ['POST', '/api/ops', '{}'],
  ])
    assert.equal(verifyOps(key, method, path, ts, sig, data, Number(ts)), false);
  assert.equal(verifyOps(key, 'POST', '/api/ops', ts, sig, body, Number(ts) + 301), false);
});
test('missing and placeholder keys fail closed', () => {
  assert.throws(() => requireSecret('REPLACE_WITH_A_SECRET'.repeat(3)));
  assert.equal(verifyOps(undefined, 'POST', '/api/ops', ts, 'a'.repeat(64), '{}', Number(ts)), false);
});
test('referrals contain only a public post ID and expiration, reject tampering and expiry', () => {
  const token = issueReferral(key, id, Number(ts));
  assert.deepEqual(readReferral(key, token, Number(ts)), {postId: id});
  assert.equal(readReferral(key, token + 'a', Number(ts)), null);
  assert.equal(readReferral(key, token, Number(ts) + 7 * 86400 + 1), null);
});
test('bounded streaming body limit does not trust Content-Length', async () => {
  const request = new Request('https://example.test', {
    method: 'POST',
    headers: {'content-length': '1'},
    body: 'x'.repeat(1000),
  });
  await assert.rejects(() => readBoundedText(request, 10), /BODY_TOO_LARGE/);
  assert.equal(
    await readBoundedText(new Request('https://example.test', {method: 'POST', body: 'ok'}), 10),
    'ok',
  );
});
