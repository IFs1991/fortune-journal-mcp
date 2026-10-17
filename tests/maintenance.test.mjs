import test from 'node:test';
import assert from 'node:assert/strict';
import {failedRun, refusedRun, summarize} from '../src/ops/maintenance.ts';
import {RunFailure} from '../src/ops/runs.ts';

test('a run that is out of attempts is a permanent failure, never "already done"', () => {
  assert.deepEqual(refusedRun('purge', {status: 'failed', exhausted: true}), {
    step: 'purge',
    status: 'failed',
    errorCode: 'PURGE_RETRIES_EXHAUSTED',
    retryable: false,
  });
  // Older replies without the flag: a refused 'failed' run can only be exhausted.
  assert.equal(refusedRun('purge', {status: 'failed'}).status, 'failed');
  assert.equal(refusedRun('post_snapshot', {status: 'running', exhausted: true}, 'p').status, 'failed');
  assert.deepEqual(refusedRun('purge', {status: 'succeeded'}), {step: 'purge', status: 'already_done'});
  assert.deepEqual(refusedRun('purge', {status: 'running'}), {step: 'purge', status: 'in_progress'});
});

test('thrown attempts: retryable while attempts remain and the cause is transient', () => {
  assert.equal(failedRun('purge', new RunFailure('PURGE_FAILED', 1)).retryable, true);
  assert.equal(failedRun('purge', new RunFailure('PURGE_FAILED', 3)).retryable, false);
  assert.equal(
    failedRun('account_snapshot', new RunFailure('THREADS_PERMISSION_DENIED', 1)).retryable,
    false,
  );
  assert.equal(failedRun('snapshot_lookup', new Error('SNAPSHOT_LOOKUP_FAILED')).retryable, true);
  // Library/network text never reaches the result or the logs.
  assert.equal(
    failedRun('purge', new Error('connect ECONNREFUSED 10.0.0.1:5432')).errorCode,
    'OPERATION_FAILED',
  );
});

test('summary counts failures so the cron route can answer 500', () => {
  const ok = summarize([{step: 'purge', status: 'already_done'}]);
  assert.deepEqual(ok, {ok: true, failures: 0, permanentFailures: 0, errorCodes: []});
  const bad = summarize([
    {step: 'purge', status: 'succeeded'},
    refusedRun('post_snapshot', {status: 'failed', exhausted: true}, 'p1'),
    failedRun('account_snapshot', new RunFailure('THREADS_RATE_LIMITED', 1)),
  ]);
  assert.equal(bad.ok, false);
  assert.equal(bad.failures, 2);
  assert.equal(bad.permanentFailures, 1);
  assert.deepEqual(bad.errorCodes, ['POST_SNAPSHOT_RETRIES_EXHAUSTED', 'THREADS_RATE_LIMITED']);
});
