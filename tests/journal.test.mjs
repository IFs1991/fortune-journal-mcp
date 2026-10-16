import test from 'node:test';
import assert from 'node:assert/strict';
import {
  JOURNAL_SHEETS,
  JOURNAL_SCHEMA_VERSION,
  JOURNAL_WRITE_RULES,
  escapeSheetText,
} from '../src/domain/journal.ts';
const headers = (name) => JOURNAL_SHEETS.find((s) => s.name === name).headers;
test('fortune records keep creation time, target period, method and result version apart from life records', () => {
  for (const h of [
    'created_at_utc',
    'target_date',
    'target_period',
    'method',
    'algorithm_version',
    'reading_original',
    'service_reading_id',
  ])
    assert.ok(headers('Fortune Log').includes(h), h);
  for (const h of ['what_happened', 'my_actions'])
    assert.ok(!headers('Fortune Log').includes(h), `life data mixed into Fortune Log: ${h}`);
  assert.ok(headers('Life Log').includes('what_happened'));
});
test('schema changes are additive: v1.1 column order is preserved for existing workbooks', () => {
  assert.deepEqual(headers('Fortune Log').slice(0, 11), [
    'record_id',
    'created_at_utc',
    'target_date',
    'method',
    'algorithm_version',
    'reading_original',
    'reading_interpretation',
    'notes',
    'request_id',
    'service_reading_id',
    'topic_optional',
  ]);
  assert.equal(JOURNAL_SCHEMA_VERSION, '1.2');
});
test('write rules cover formula injection, duplicates, refusal and no false save claims', () => {
  const text = JOURNAL_WRITE_RULES.join(' ').toLowerCase();
  for (const k of ['raw', 'apostrophe', 'record_id', 'declin', 'never say', 'untrusted'])
    assert.ok(text.includes(k), k);
});
test('formula escaping also covers tab/CR prefixes and leaves plain text alone', () => {
  for (const v of ['\t=1+1', '\r=1', '=HYPERLINK("x")'])
    assert.ok(escapeSheetText(v).startsWith("'"), JSON.stringify(v));
  assert.equal(escapeSheetText('Life is good'), 'Life is good');
});
