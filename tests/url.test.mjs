import test from 'node:test';
import assert from 'node:assert/strict';
import {safeNextPath, sameOriginNavigation, sameOriginPost} from '../src/lib/urls.ts';

const APP = 'https://app.example';

test('reject open redirects and preserve safe consent route', () => {
  const target = '/oauth/consent?authorization_id=abc123';
  assert.equal(safeNextPath(target), target);
  for (const x of [
    '//evil.example',
    '/\\evil.example',
    'https://evil.example',
    '/%2F%2Fevil.example',
    '/foo\r\nLocation:evil',
    'javascript:alert(1)',
  ])
    assert.equal(safeNextPath(x), '/login');
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
