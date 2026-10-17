import test from 'node:test';
import assert from 'node:assert/strict';
import {parseExportRequest, PRIVACY_VERSION} from '../src/account.ts';

test('export requests accept only known resources and sane pages', () => {
  assert.deepEqual(
    parseExportRequest(new URLSearchParams('resource=readings&offset=100&asOf=2026-10-01T00:00:00Z')),
    {
      resource: 'readings',
      offset: 100,
      asOf: '2026-10-01T00:00:00Z',
    },
  );
  assert.equal(parseExportRequest(new URLSearchParams()).resource, 'access');
  assert.equal(parseExportRequest(new URLSearchParams('resource=secrets')), 'invalid_resource');
  assert.equal(parseExportRequest(new URLSearchParams('resource=__proto__')), 'invalid_resource');
  for (const page of [
    'offset=-1',
    'offset=1.5',
    'offset=99999999',
    'asOf=yesterday',
    'asOf=2999-01-01T00:00:00Z',
  ]) {
    assert.equal(parseExportRequest(new URLSearchParams(page)), 'invalid_page', page);
  }
});

test('the consent version matches the format the database accepts', () => {
  // supabase/migrations: user_access.consent_version CHECK and fj_set_privacy validation.
  assert.match(PRIVACY_VERSION, /^[0-9]{4}-[0-9]{2}-v[0-9]+$/);
});
