import test from 'node:test';
import assert from 'node:assert/strict';
import {opsCommand, publicErrorCode} from '../src/ops/commands.ts';

const requestId = '106a4935-79ed-4e58-9804-841a85095caa';
const draft = {
  requestId,
  action: 'draft_post',
  body: 'A short public post',
  topic: 'general',
  method: 'tarot',
  tone: 'question',
  language: 'en',
  ctaKey: 'reflect',
  promptVersion: 'p1',
};

test('operator commands are strict: unknown actions and fields are refused', () => {
  assert.equal(opsCommand.safeParse(draft).success, true);
  assert.equal(opsCommand.safeParse({...draft, userId: requestId}).success, false, 'extra field accepted');
  assert.equal(opsCommand.safeParse({requestId, action: 'run_sql', sql: 'select 1'}).success, false);
  assert.equal(opsCommand.safeParse({...draft, requestId: 'not-a-uuid'}).success, false);
});

test('draft bodies are limited to 500 code points (Threads), not UTF-16 units', () => {
  assert.equal(opsCommand.safeParse({...draft, body: '🌙'.repeat(500)}).success, true);
  assert.equal(opsCommand.safeParse({...draft, body: 'x'.repeat(501)}).success, false);
  assert.equal(opsCommand.safeParse({...draft, body: ''}).success, false);
});

test('defaults and cost fields are validated', () => {
  const collect = opsCommand.parse({requestId, action: 'collect_post_metrics', postId: requestId});
  assert.equal(collect.kind, 'manual');
  const run = {
    requestId,
    action: 'record_external_run',
    task: 'weekly_analysis',
    startedAt: '2026-10-14T00:00:00Z',
    finishedAt: '2026-10-14T00:01:00Z',
    success: true,
  };
  assert.equal(opsCommand.safeParse(run).success, true);
  assert.equal(opsCommand.safeParse({...run, estimatedCost: -1, currency: 'USD'}).success, false);
  assert.equal(opsCommand.safeParse({...run, currency: 'usd'}).success, false);
});

test('only allowlisted error codes reach the operator', () => {
  assert.equal(publicErrorCode(new Error('IDEMPOTENCY_CONFLICT')), 'IDEMPOTENCY_CONFLICT');
  assert.equal(
    publicErrorCode(new Error('duplicate key value violates unique constraint "x"')),
    'OPERATION_FAILED',
  );
  assert.equal(publicErrorCode('THREADS_RATE_LIMITED'), 'OPERATION_FAILED');
});

test('resolve_publish needs an external id exactly when the post was found live', () => {
  const base = {requestId, action: 'resolve_publish', postId: requestId};
  assert.equal(opsCommand.safeParse({...base, outcome: 'not_published'}).success, true);
  assert.equal(opsCommand.safeParse({...base, outcome: 'published', externalPostId: '1789'}).success, true);
  assert.equal(opsCommand.safeParse({...base, outcome: 'published'}).success, false);
  assert.equal(
    opsCommand.safeParse({...base, outcome: 'not_published', externalPostId: '1789'}).success,
    false,
  );
  assert.equal(opsCommand.safeParse({...base, outcome: 'published', externalPostId: '../x'}).success, false);
  assert.equal(opsCommand.safeParse({...base, outcome: 'retry'}).success, false);
  assert.equal(publicErrorCode(new Error('POST_NOT_UNKNOWN')), 'POST_NOT_UNKNOWN');
});
