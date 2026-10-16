import test from 'node:test';
import assert from 'node:assert/strict';
import {calculateNumerology, parseISODate, reduceNumber} from '../src/domain/numerology.ts';
import {drawTarot} from '../src/domain/tarot.ts';

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
test('tarot draws are pinned: changing the algorithm silently would break replays and journals', () => {
  const cards = drawTarot(
    '106a4935-79ed-4e58-9804-841a85095caa',
    'a'.repeat(64),
    3,
    '206a4935-79ed-4e58-9804-841a85095cab',
  ).cards;
  assert.deepEqual(cards, [
    {index: 5, name: 'The Hierophant', orientation: 'reversed'},
    {index: 14, name: 'Temperance', orientation: 'reversed'},
    {index: 3, name: 'The Empress', orientation: 'upright'},
  ]);
});
test('tarot refuses invalid counts, short keys and malformed draw ids', () => {
  const drawId = '106a4935-79ed-4e58-9804-841a85095caa';
  assert.throws(() => drawTarot('u', 'a'.repeat(32), 2, drawId), /INVALID_COUNT/);
  assert.throws(() => drawTarot('u', 'short', 1, drawId), /MISSING_SECRET/);
  assert.throws(() => drawTarot('u', 'a'.repeat(32), 1, '../x'), /INVALID_DRAW_ID/);
});
