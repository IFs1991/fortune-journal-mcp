import test from 'node:test';
import assert from 'node:assert/strict';
import {registerTools, SERVER_INSTRUCTIONS} from '../src/mcp/tools.ts';
import * as schemas from '../src/mcp/schemas.ts';

// Captures what the SDK would receive, without starting a server or touching the network.
const registered = new Map();
registerTools({registerTool: (name, config, callback) => registered.set(name, {config, callback})});
const call = (name, args = {}, ctx = authed) => registered.get(name).callback(args, ctx);
const authed = {
  http: {authInfo: {clientId: 'client-1', extra: {userId: '106a4935-79ed-4e58-9804-841a85095caa'}}},
};
const code = (result) => (result.isError ? result.content[0].text : null);

test('exactly the 7 customer tools are registered, none of them operator-like', () => {
  assert.deepEqual([...registered.keys()].sort(), [
    'calculate_numerology',
    'draw_tarot',
    'get_access_status',
    'get_account_profile',
    'get_journal_schema',
    'report_journal_action',
    'submit_reading_feedback',
  ]);
});

test('every tool declares OAuth, input and output schemas, and honest annotations', () => {
  for (const [name, {config}] of registered) {
    assert.equal(config._meta.securitySchemes[0].type, 'oauth2', name);
    assert.ok(config.inputSchema && config.outputSchema, name);
    assert.ok(config.title && config.description.length > 40, name);
    assert.equal(config.annotations.destructiveHint, false, name);
    assert.equal(config.annotations.openWorldHint, false, name);
  }
  const readOnly = [...registered]
    .filter(([, {config}]) => config.annotations.readOnlyHint)
    .map(([name]) => name);
  assert.deepEqual(readOnly.sort(), ['get_access_status', 'get_journal_schema']);
});

test('optional analytics tools require an explicit user request', () => {
  for (const name of ['submit_reading_feedback', 'report_journal_action']) {
    const input = registered.get(name).config.inputSchema;
    assert.equal(
      input.safeParse({readingId: crypto.randomUUID(), requestId: crypto.randomUUID()}).success,
      false,
      name,
    );
  }
});

test('no verified user means AUTHENTICATION_REQUIRED for every tool, before any work', async () => {
  for (const name of registered.keys()) {
    assert.equal(code(await call(name, {}, {})), 'AUTHENTICATION_REQUIRED', name);
    assert.equal(
      code(await call(name, {}, {http: {authInfo: {extra: {userId: 'not-a-uuid'}}}})),
      'AUTHENTICATION_REQUIRED',
      name,
    );
  }
});

test('get_journal_schema needs no database and matches its output schema', async () => {
  const result = await call('get_journal_schema');
  assert.equal(code(result), null);
  assert.deepEqual(schemas.journalSchemaOutput.parse(result.structuredContent), result.structuredContent);
  assert.equal(result.structuredContent.ownership, 'user_google_drive');
  assert.equal(JSON.parse(result.content[0].text).schemaVersion, result.structuredContent.schemaVersion);
});

test('input problems are reported before the database is touched', async () => {
  assert.equal(code(await call('calculate_numerology', {birthDate: '2025-02-29'})), 'INVALID_DATE');
  assert.equal(
    code(await call('calculate_numerology', {birthDate: '1991-09-12', asOf: '2026-13-01'})),
    'INVALID_DATE',
  );
  const saved = process.env.TAROT_HMAC_KEY;
  delete process.env.TAROT_HMAC_KEY;
  assert.equal(code(await call('draw_tarot', {count: 1})), 'SERVICE_NOT_CONFIGURED');
  process.env.TAROT_HMAC_KEY = 'REPLACE_WITH_DIFFERENT_64_HEX_CHARACTERS';
  assert.equal(
    code(await call('draw_tarot', {count: 1})),
    'SERVICE_NOT_CONFIGURED',
    'placeholder key accepted',
  );
  if (saved === undefined) delete process.env.TAROT_HMAC_KEY;
  else process.env.TAROT_HMAC_KEY = saved;
});

test('optional analytics tools refuse while the global switch is off', async () => {
  const saved = process.env.PRODUCT_ANALYTICS_ENABLED;
  process.env.PRODUCT_ANALYTICS_ENABLED = 'false';
  const feedback = {
    readingId: crypto.randomUUID(),
    usefulness: 4,
    matchAssessment: 'mixed',
    explicitUserRequest: true,
  };
  assert.equal(code(await call('submit_reading_feedback', feedback)), 'OPTIONAL_ANALYTICS_DISABLED');
  const report = {requestId: crypto.randomUUID(), action: 'journal_save_reported', explicitUserRequest: true};
  assert.equal(code(await call('report_journal_action', report)), 'OPTIONAL_ANALYTICS_DISABLED');
  process.env.PRODUCT_ANALYTICS_ENABLED = saved;
});

test('backend failures fail closed with each tool’s documented code', async () => {
  // No Supabase environment in unit tests: the DB client cannot be created.
  const saved = process.env.NEXT_PUBLIC_SUPABASE_URL;
  delete process.env.NEXT_PUBLIC_SUPABASE_URL;
  process.env.REQUEST_HMAC_KEY ??= 'a'.repeat(64);
  assert.equal(code(await call('get_access_status')), 'ACCESS_TEMPORARILY_UNAVAILABLE');
  assert.equal(
    code(await call('calculate_numerology', {birthDate: '1991-09-12'})),
    'SERVICE_TEMPORARILY_UNAVAILABLE',
  );
  if (saved !== undefined) process.env.NEXT_PUBLIC_SUPABASE_URL = saved;
});

test('the fj_record_calculation reply is parsed, not trusted', () => {
  const receipt = {
    ok: true,
    readingId: crypto.randomUUID(),
    tier: 'trial',
    remainingAtCompletion: 99,
    replayed: false,
  };
  assert.equal(schemas.calculationOutcome.safeParse(receipt).success, true);
  assert.equal(
    schemas.calculationOutcome.safeParse({ok: false, reason: 'USAGE_LIMIT_REACHED'}).success,
    true,
  );
  for (const bad of [
    null,
    {},
    {...receipt, tier: 'gold'},
    {...receipt, remainingAtCompletion: -1},
    {ok: false, reason: 'ANYTHING'},
  ]) {
    assert.equal(schemas.calculationOutcome.safeParse(bad).success, false, JSON.stringify(bad));
  }
});

test('server instructions steer hosts away from redundant pre-calls and Google writes', () => {
  assert.match(SERVER_INSTRUCTIONS, /call calculate_numerology or draw_tarot directly/);
  assert.match(SERVER_INSTRUCTIONS, /never reads or writes Google/);
});
