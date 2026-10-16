import test from 'node:test';
import assert from 'node:assert/strict';
import {calculateNumerology, parseISODate, reduceNumber} from '../src/domain/numerology.ts';
import {drawTarot} from '../src/domain/tarot.ts';
import {resolveEntitlement, permission, periodStartUTC} from '../src/domain/entitlements.ts';
import {escapeSheetText} from '../src/domain/journal.ts';

test('ISO date parser refuses bad calendar dates and supports leap day', () => {
  assert.deepEqual(parseISODate('2000-02-29'), {year: 2000, month: 2, day: 29});
  for (const s of ['2025-02-29', '2024-13-01', '2024-02-30', '24-01-01', '1900-02-29'])
    assert.throws(() => parseISODate(s));
});
test('number reduction and time-dependent personal cycle deterministic', () => {
  assert.equal(reduceNumber(29), 11);
  assert.equal(reduceNumber(29, false), 2);
  const a = calculateNumerology('1991-09-12', '2026-10-14');
  assert.equal(a.lifePath, 5);
  assert.equal(a.personalYear, 4);
  assert.equal(a.personalMonth, 5);
  assert.deepEqual(a, calculateNumerology('1991-09-12', '2026-10-14'));
});
test('tarot uses no duplicates and is reproducible for the same draw id', () => {
  const secret = 'a'.repeat(32),
    drawId = '106a4935-79ed-4e58-9804-841a85095caa';
  const a = drawTarot('user-1', secret, 3, drawId);
  assert.equal(new Set(a.cards.map((x) => x.index)).size, 3);
  assert.deepEqual(a, drawTarot('user-1', secret, 3, drawId));
  assert.notDeepEqual(a, drawTarot('user-2', secret, 3, drawId));
});
test('quota, trial, expiry and suspension never trust client plans', () => {
  const now = new Date('2026-10-14T00:00:00Z');
  const access = {trial_ends_at: '2026-10-15T00:00:00Z', suspended_at: null};
  assert.equal(resolveEntitlement(access, [], now), 'trial');
  assert.equal(
    resolveEntitlement(
      {...access, suspended_at: '2026-10-13T00:00:00Z'},
      [{status: 'active', current_period_end: '2027-01-01T00:00:00Z'}],
      now,
    ),
    'suspended',
  );
  assert.equal(resolveEntitlement({...access, trial_ends_at: '2026-10-13T00:00:00Z'}, [], now), 'free');
  assert.equal(permission('free', 'draw_tarot').enabled, false);
  assert.equal(permission('free', 'calculate_numerology').maxUses, 3);
  assert.equal(periodStartUTC(now, 'iso_week'), '2026-10-12');
  assert.equal(periodStartUTC(now, 'day'), '2026-10-14');
});
test('spreadsheet formulas are escaped', () => {
  for (const value of ['=IMPORTXML()', '+SUM(A1:A2)', '-1+2', '@CALL()', ' =1+1'])
    assert.equal(escapeSheetText(value), "'" + value);
  assert.equal(escapeSheetText('Hello'), 'Hello');
});
