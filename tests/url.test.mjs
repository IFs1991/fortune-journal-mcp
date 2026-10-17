import test from 'node:test';
import assert from 'node:assert/strict';
import {safeNextPath, sameOriginNavigation, sameOriginPost} from '../src/lib/urls.ts';

const APP = 'https://app.example';

test('safe consent route survives login; the result is always same-origin', () => {
  const target = '/oauth/consent?authorization_id=abc123';
  assert.equal(safeNextPath(target), target);
  assert.equal(safeNextPath('/login'), '/login');
  assert.equal(safeNextPath(null), '/login');
});

test('open-redirect vectors (control chars, backslashes, encodings, schemes) never leave the origin', () => {
  const vectors = [
    '//evil.example',
    '/\\evil.example',
    '\\\\evil.example',
    'https://evil.example',
    '/%2F%2Fevil.example',
    '/%2f/evil.example',
    '/%252F%252Fevil.example',
    '/%5Cevil.example',
    '/%5cevil.example',
    '/%255Cevil.example',
    '/\t/evil.example',
    '/\n/evil.example',
    '/\r/evil.example',
    '/%09/evil.example',
    '/%0a/evil.example',
    '/%00/evil.example',
    '/\u0000/evil.example',
    '/ /evil.example',
    '/ /evil.example',
    '/　/evil.example',
    '/foo\r\nLocation:evil',
    'javascript:alert(1)',
    '/javascript:alert(1)',
    '/oauth/consent?authorization_id=abc123&next=//evil.example',
    '/oauth/consent?authorization_id=abc123#//evil.example',
    '/oauth/consent?authorization_id=abc123&authorization_id=def456',
    '/oauth/consent?authorization_id=../../x',
    '/oauth/consent/../../%2F%2Fevil.example',
    '/@evil.example',
    '/x'.repeat(600),
  ];
  for (const value of vectors) {
    const out = safeNextPath(value);
    assert.ok(out === '/login' || out.startsWith('/oauth/consent?authorization_id='), JSON.stringify(value));
    // Whatever comes out, browsers and URL parsers resolve it to our origin.
    assert.equal(new URL(out, APP).origin, APP, JSON.stringify(value));
    assert.doesNotMatch(out, /[\s\\]|%(?![0-9A-F]{2})/i, JSON.stringify(value));
  }
  assert.equal(safeNextPath('/\t/evil.example'), '/login');
  assert.equal(safeNextPath('/%5Cevil.example'), '/login');
});

const post = (headers, method = 'POST') => new Request(`${APP}/api/x`, {method, headers});
const form = {'content-type': 'application/x-www-form-urlencoded'};

test('cookie-authenticated POST requires exact Origin, same-origin fetch metadata and a form body', () => {
  assert.equal(sameOriginPost(post({origin: APP, ...form}), APP), true);
  assert.equal(sameOriginPost(post({origin: APP, 'sec-fetch-site': 'same-origin', ...form}), APP), true);
  for (const headers of [
    {origin: 'https://attacker.example', ...form},
    {origin: 'null', ...form},
    {origin: `${APP}.evil.example`, ...form},
    {...form}, // no Origin: fail closed
    {origin: APP, 'sec-fetch-site': 'cross-site', ...form},
    {origin: APP, 'sec-fetch-site': 'same-site', ...form},
    {origin: APP, 'content-type': 'application/json'},
    {origin: APP, 'content-type': 'text/plain'},
    {origin: APP},
  ])
    assert.equal(sameOriginPost(post(headers), APP), false, JSON.stringify(headers));
  assert.equal(sameOriginPost(post({origin: APP, ...form}, 'PUT'), APP), false);
});

test('cookie-authenticated GET (export) refuses cross-site requests', () => {
  const get = (headers) => new Request(`${APP}/api/account/export`, {headers});
  assert.equal(sameOriginNavigation(get({}), APP), true);
  assert.equal(sameOriginNavigation(get({'sec-fetch-site': 'same-origin'}), APP), true);
  assert.equal(sameOriginNavigation(get({'sec-fetch-site': 'none'}), APP), true);
  assert.equal(sameOriginNavigation(get({'sec-fetch-site': 'cross-site'}), APP), false);
  assert.equal(sameOriginNavigation(get({'sec-fetch-site': 'same-site'}), APP), false);
  assert.equal(sameOriginNavigation(get({origin: 'https://attacker.example'}), APP), false);
});
