import test from 'node:test';
import assert from 'node:assert/strict';
import {
  validateMcpAccessClaims,
  decodeJwtPayload,
  precheckMcpAccessClaims,
} from '../src/domain/oauth-claims.ts';
const issuer = 'https://project.supabase.co/auth/v1',
  user = '106a4935-79ed-4e58-9804-841a85095caa',
  now = 1_800_000_000;
const good = {
  iss: issuer,
  aud: 'authenticated',
  sub: user,
  role: 'authenticated',
  client_id: 'client-123',
  exp: now + 60,
};
test('accepts a Supabase OAuth access token bound to the verified user and an OAuth client', () => {
  assert.deepEqual(validateMcpAccessClaims(good, {issuer, userId: user, nowSeconds: now}), {
    clientId: 'client-123',
    expiresAt: now + 60,
  });
  assert.deepEqual(
    validateMcpAccessClaims({...good, aud: ['authenticated', 'x']}, {issuer, userId: user, nowSeconds: now})
      ?.clientId,
    'client-123',
  );
});
test('rejects browser-session tokens without client_id, foreign issuers, wrong subject, role, audience, expiry', () => {
  const opts = {issuer, userId: user, nowSeconds: now};
  for (const bad of [
    {...good, client_id: undefined},
    {...good, client_id: ''},
    {...good, iss: 'https://other.supabase.co/auth/v1'},
    {...good, sub: '206a4935-79ed-4e58-9804-841a85095caa'},
    {...good, role: 'service_role'},
    {...good, role: 'anon'},
    {...good, aud: 'other'},
    {...good, exp: now},
    {...good, exp: '9999999999'},
    {...good, exp: undefined},
  ])
    assert.equal(validateMcpAccessClaims(bad, opts), null, JSON.stringify(bad));
});
test('trailing slash in configured issuer does not loosen the check', () => {
  assert.equal(
    validateMcpAccessClaims(good, {issuer: issuer + '/', userId: user, nowSeconds: now})?.clientId,
    'client-123',
  );
  assert.equal(
    validateMcpAccessClaims({...good, iss: issuer + '/x'}, {issuer, userId: user, nowSeconds: now}),
    null,
  );
});
test('JWT payload decoding is strict about shape', () => {
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  assert.deepEqual(decodeJwtPayload(`h.${enc(good)}.s`), good);
  for (const t of ['', 'a.b', 'a.b.c.d', `h.${Buffer.from('[1]').toString('base64url')}.s`, 'h.!!!.s'])
    assert.equal(decodeJwtPayload(t), null);
});
test('pre-check rejects expired, foreign-issuer and non-OAuth tokens before any network call, and never accepts on its own', () => {
  const opts = {issuer, nowSeconds: now};
  assert.equal(precheckMcpAccessClaims(good, opts), true);
  assert.equal(precheckMcpAccessClaims({...good, aud: ['authenticated', 'x']}, opts), true);
  for (const bad of [
    {...good, exp: now},
    {...good, exp: now - 1},
    {...good, exp: undefined},
    {...good, iss: 'https://other.supabase.co/auth/v1'},
    {...good, client_id: undefined},
    {...good, client_id: ''},
    {...good, role: 'service_role'},
    {...good, aud: 'other'},
    {...good, sub: 'not-a-uuid'},
    {...good, sub: undefined},
  ])
    assert.equal(precheckMcpAccessClaims(bad, opts), false, JSON.stringify(bad));
  // Anything the pre-check passes must still be bound to the Supabase-verified user afterwards.
  assert.equal(
    validateMcpAccessClaims(good, {issuer, userId: '206a4935-79ed-4e58-9804-841a85095caa', nowSeconds: now}),
    null,
  );
});
