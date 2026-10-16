import test from 'node:test';
import assert from 'node:assert/strict';
import {safeNextPath, sameOriginPost} from '../src/lib/urls.ts';

test('reject open redirects and preserve safe consent route', () => {
  const target = '/oauth/consent?authorization_id=abc123';
  assert.equal(safeNextPath(target), target);
  for (const x of [
    '//evil.example',
    '/\\evil.example',
    'https://evil.example',
    '/%2F%2Fevil.example',
    '/foo\r\nLocation:evil',
    'javascript:alert(1)',
  ])
    assert.equal(safeNextPath(x), '/login');
});
test('mutating browser endpoint requires matching Origin header', () => {
  assert.equal(
    sameOriginPost(
      new Request('https://example.com/api', {method: 'POST', headers: {origin: 'https://example.com'}}),
      'https://example.com',
    ),
    true,
  );
  assert.equal(
    sameOriginPost(
      new Request('https://example.com/api', {method: 'POST', headers: {origin: 'https://attacker.com'}}),
      'https://example.com',
    ),
    false,
  );
  assert.equal(
    sameOriginPost(new Request('https://example.com/api', {method: 'POST'}), 'https://example.com'),
    false,
  );
});
