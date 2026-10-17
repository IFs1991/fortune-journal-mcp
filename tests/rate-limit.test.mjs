import test from 'node:test';
import assert from 'node:assert/strict';
import {FixedWindowLimiter, clientAddress, limitMcp} from '../src/lib/rate-limit.ts';

test('fixed window: allows the limit, then reports seconds to wait, then resets', () => {
  const limiter = new FixedWindowLimiter(3, 60_000);
  const t = 1_000_000;
  assert.deepEqual(
    [1, 2, 3].map(() => limiter.take('a', t)),
    [0, 0, 0],
  );
  assert.equal(limiter.take('a', t + 1_000), 59);
  assert.equal(limiter.take('b', t + 1_000), 0, 'keys are independent');
  assert.equal(limiter.take('a', t + 60_000), 0, 'window reset');
});

test('memory stays bounded under many distinct keys', () => {
  const limiter = new FixedWindowLimiter(1, 60_000, 100);
  for (let i = 0; i < 10_000; i++) limiter.take(`k${i}`, 0);
  assert.ok(limiter.buckets.size <= 100);
});

test('client address prefers the platform header and is length-bounded', () => {
  const req = (headers) => new Request('https://app.example/api/mcp', {headers});
  assert.equal(clientAddress(req({'x-real-ip': '203.0.113.9', 'x-forwarded-for': '1.1.1.1'})), '203.0.113.9');
  assert.equal(clientAddress(req({'x-forwarded-for': '198.51.100.1, 10.0.0.1'})), '198.51.100.1');
  assert.equal(clientAddress(req({})), 'unknown');
  assert.equal(clientAddress(req({'x-real-ip': 'x'.repeat(500)})).length, 64);
});

test('MCP: one bearer is limited to 120 requests per minute with 429 + Retry-After', () => {
  const req = () =>
    new Request('https://app.example/api/mcp', {
      method: 'POST',
      headers: {authorization: 'Bearer rate-limit-test-token', 'x-real-ip': '203.0.113.77'},
    });
  for (let i = 0; i < 120; i++) assert.equal(limitMcp(req()), null);
  const limited = limitMcp(req());
  assert.equal(limited?.status, 429);
  assert.ok(Number(limited.headers.get('retry-after')) >= 1);
});
