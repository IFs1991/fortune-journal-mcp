// LOCAL-ONLY end-to-end test: local Supabase CLI stack (GoTrue + PostgREST) + this app on localhost.
// Exercises Google-only auth negatives, Data API RLS (anon / A / B), OAuth 2.1 + PKCE consent via the app's
// own routes, the MCP endpoint with real OAuth access tokens, quota/trial rules, refresh, grant revocation,
// deny, and account deletion. Refuses any non-loopback target. Prints no tokens or keys.
// Usage: supabase start; build+start the app with APP_ORIGIN=http://localhost:3000 and the local keys; then
//   node --experimental-strip-types scripts/e2e-local.mjs [--out verification/e2e_local.json]
import {spawnSync} from 'node:child_process';
import {createHash, createHmac, randomBytes, randomUUID} from 'node:crypto';
import {writeFileSync} from 'node:fs';
import {createClient} from '@supabase/supabase-js';
import {createServerClient} from '@supabase/ssr';
import {signOps, webSessionBinding} from '../src/domain/security.ts';
import {MCP_TOKEN_AUDIENCE} from '../src/domain/oauth-claims.ts';

const loopback = (u) => ['127.0.0.1', 'localhost', '[::1]'].includes(new URL(u).hostname);
const status = JSON.parse(
  spawnSync('supabase', ['status', '-o', 'json'], {encoding: 'utf8', input: ''}).stdout || '{}',
);
const API = status.API_URL,
  APP = process.env.APP_ORIGIN ?? 'http://localhost:3000';
if (!API || !loopback(API) || !loopback(APP))
  throw new Error('Refusing: e2e-local only runs against a loopback Supabase stack and app.');
const PUB = status.PUBLISHABLE_KEY,
  SECRET = status.SECRET_KEY;
const admin = createClient(API, SECRET, {auth: {persistSession: false, autoRefreshToken: false}});
const anon = () => createClient(API, PUB, {auth: {persistSession: false, autoRefreshToken: false}});
const results = [];
let failures = 0;
async function step(name, fn) {
  try {
    await fn();
    results.push({name, result: 'PASS'});
    console.log('PASS', name);
  } catch (e) {
    failures++;
    results.push({name, result: 'FAIL', error: String(e?.message ?? e).slice(0, 300)});
    console.log('FAIL', name, '-', String(e?.message ?? e).slice(0, 300));
  }
}
/** Usage units consumed = ledger rows (supabase/migrations: one user_readings row per unit). */
const usage = async (userId, filter = {}) => {
  let query = admin.from('user_readings').select('id', {count: 'exact', head: true}).eq('user_id', userId);
  for (const [column, value] of Object.entries(filter)) query = query.eq(column, value);
  const {count, error} = await query;
  if (error) throw error;
  return count;
};
const ok = (cond, msg) => {
  if (!cond) throw new Error(msg);
};
const decode = (t) => JSON.parse(Buffer.from(t.split('.')[1], 'base64url').toString());

async function newUser(label) {
  const email = `fj-e2e-${label}-${Date.now()}-${randomBytes(3).toString('hex')}@example.test`;
  const {data, error} = await admin.auth.admin.createUser({email, email_confirm: true});
  if (error) throw error;
  const {data: link, error: le} = await admin.auth.admin.generateLink({type: 'magiclink', email});
  if (le) throw le;
  const {data: v, error: ve} = await anon().auth.verifyOtp({
    type: 'magiclink',
    token_hash: link.properties.hashed_token,
  });
  if (ve) throw ve;
  return {id: data.user.id, email, session: v.session};
}
const BINDING_COOKIE = new URL(APP).protocol === 'https:' ? '__Host-fj-web-session' : 'fj-web-session';
/** The HttpOnly cookie /auth/callback sets after a real Google sign-in (Google cannot run locally). */
function bindingCookie(session) {
  if (!process.env.WEB_SESSION_HMAC_KEY)
    throw new Error('WEB_SESSION_HMAC_KEY not provided to the E2E process; source the same env as the app');
  const claims = decode(session.access_token);
  return `${BINDING_COOKIE}=${webSessionBinding(process.env.WEB_SESSION_HMAC_KEY, claims.sub, claims.session_id)}`;
}
/**
 * Real @supabase/ssr cookie encoding, produced by the library itself into an in-memory jar, plus the app's
 * web-session binding unless `bind` is false (bind may also be another session to model a stolen binding).
 */
async function cookieHeader(session, bind = true) {
  const jar = new Map();
  const ssr = createServerClient(API, PUB, {
    cookies: {
      getAll: () => [...jar].map(([name, value]) => ({name, value})),
      setAll: (items) => items.forEach(({name, value}) => (value ? jar.set(name, value) : jar.delete(name))),
    },
  });
  const {error} = await ssr.auth.setSession({
    access_token: session.access_token,
    refresh_token: session.refresh_token,
  });
  if (error) throw error;
  const cookies = [...jar].map(([n, v]) => `${n}=${v}`);
  if (bind) cookies.push(bindingCookie(bind === true ? session : bind));
  return cookies.join('; ');
}
const userClient = (s) =>
  createClient(API, PUB, {
    global: {headers: {Authorization: `Bearer ${s.access_token}`}},
    auth: {persistSession: false, autoRefreshToken: false},
  });

async function mcp(token, method, params = {}, extraHeaders = {}) {
  const res = await fetch(`${APP}/api/mcp`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      accept: 'application/json, text/event-stream',
      'mcp-protocol-version': '2025-06-18',
      ...(token ? {authorization: `Bearer ${token}`} : {}),
      ...extraHeaders,
    },
    body: JSON.stringify({jsonrpc: '2.0', id: randomUUID(), method, params}),
  });
  const text = await res.text();
  let body = null;
  if (res.headers.get('content-type')?.includes('text/event-stream')) {
    const line = text
      .split('\n')
      .filter((l) => l.startsWith('data:'))
      .at(-1);
    body = line ? JSON.parse(line.slice(5)) : null;
  } else if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }
  return {status: res.status, headers: res.headers, body};
}
async function tool(token, name, args = {}) {
  const r = await mcp(token, 'tools/call', {name, arguments: args});
  ok(r.status === 200, `tools/call ${name} HTTP ${r.status}`);
  const result = r.body?.result;
  ok(result, `tools/call ${name} no result: ${JSON.stringify(r.body).slice(0, 200)}`);
  return result.isError ? {error: result.content?.[0]?.text} : result.structuredContent;
}

const pkce = () => {
  const verifier = randomBytes(32).toString('base64url');
  return {verifier, challenge: createHash('sha256').update(verifier).digest('base64url')};
};
const REDIRECT = 'http://localhost:9999/callback';
async function registerClient(name) {
  const r = await fetch(`${API}/auth/v1/oauth/clients/register`, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({
      client_name: name,
      redirect_uris: [REDIRECT],
      token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
    }),
  });
  const body = await r.json();
  ok(r.ok && body.client_id, `client registration failed ${r.status}`);
  return body.client_id;
}
async function startAuthorization(clientId, challenge, state) {
  const u = new URL(`${API}/auth/v1/oauth/authorize`);
  for (const [k, v] of Object.entries({
    response_type: 'code',
    client_id: clientId,
    redirect_uri: REDIRECT,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    scope: 'openid',
    state,
  }))
    u.searchParams.set(k, v);
  const r = await fetch(u, {redirect: 'manual'});
  const loc = r.headers.get('location');
  ok(r.status >= 300 && r.status < 400 && loc, `authorize did not redirect (${r.status})`);
  const consent = new URL(loc);
  ok(
    consent.origin === APP && consent.pathname === '/oauth/consent',
    'authorize must redirect to the app consent page',
  );
  return consent.searchParams.get('authorization_id');
}
async function decide(cookie, authorizationId, decision, origin = APP) {
  const headers = {'content-type': 'application/x-www-form-urlencoded', cookie};
  if (origin) headers.origin = origin;
  return fetch(`${APP}/api/oauth/decision`, {
    method: 'POST',
    redirect: 'manual',
    headers,
    body: new URLSearchParams({authorization_id: authorizationId, decision}),
  });
}
async function token(params) {
  const r = await fetch(`${API}/auth/v1/oauth/token`, {
    method: 'POST',
    headers: {'content-type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams(params),
  });
  return {status: r.status, body: await r.json().catch(() => null)};
}
async function connect(user, clientName) {
  const clientId = await registerClient(clientName);
  const {verifier, challenge} = pkce();
  const state = randomUUID();
  const authorizationId = await startAuthorization(clientId, challenge, state);
  const res = await decide(await cookieHeader(user.session), authorizationId, 'approve');
  ok(res.status === 303, `approve status ${res.status}`);
  const cb = new URL(res.headers.get('location'));
  ok(
    cb.origin + cb.pathname === REDIRECT && cb.searchParams.get('state') === state,
    'callback/state mismatch',
  );
  const t = await token({
    grant_type: 'authorization_code',
    code: cb.searchParams.get('code'),
    redirect_uri: REDIRECT,
    client_id: clientId,
    code_verifier: verifier,
  });
  ok(t.status === 200 && t.body?.access_token, `token exchange ${t.status}`);
  return {clientId, ...t.body};
}

const ANALYTICS = process.env.PRODUCT_ANALYTICS_ENABLED === 'true';
async function preferences(user, fields) {
  return fetch(`${APP}/api/account/preferences`, {
    method: 'POST',
    redirect: 'manual',
    headers: {
      cookie: await cookieHeader(user.session),
      origin: APP,
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams(fields),
  });
}
const created = [];
try {
  await step('Google-only: email signup, password and OTP sign-in are refused', async () => {
    const c = anon(),
      email = `fj-e2e-x-${Date.now()}@example.test`;
    ok(
      (await c.auth.signUp({email, password: randomBytes(12).toString('hex')})).error,
      'email signup allowed',
    );
    ok(
      (await c.auth.signInWithPassword({email, password: 'x'.repeat(12)})).error,
      'password sign-in allowed',
    );
    ok((await c.auth.signInWithOtp({email, options: {shouldCreateUser: true}})).error, 'email OTP allowed');
    ok((await c.auth.signInAnonymously()).error, 'anonymous sign-in allowed');
  });
  const A = await newUser('a'),
    B = await newUser('b');
  created.push(A.id, B.id);

  await step('Data API: anon key reads nothing and calls no RPC', async () => {
    const c = anon();
    for (const t of [
      'user_access',
      'subscriptions',
      'billing_events',
      'fortune_posts',
      'automation_runs',
      'user_readings',
      'funnel_events',
      'reading_feedback',
      'fj_current_mrr',
      'fj_cash_events',
      'fj_post_24h',
    ]) {
      const {data, error} = await c.from(t).select('*').limit(1);
      ok(error || !data?.length, `anon read ${t}`);
    }
    ok(
      (
        await c.rpc('fj_record_calculation', {
          p_user_id: A.id,
          p_request_id: randomUUID(),
          p_fingerprint: 'a'.repeat(64),
          p_feature: 'calculate_numerology',
          p_algorithm: 'x',
          p_target_date: '2026-10-15',
        })
      ).error,
      'anon RPC',
    );
  });

  let accessA, trialDraw;
  await step('OAuth: DCR client + PKCE + consent page shows client and callback', async () => {
    const clientId = await registerClient('FJ E2E Client');
    const {verifier, challenge} = pkce();
    const state = randomUUID();
    const authorizationId = await startAuthorization(clientId, challenge, state);
    const anonPage = await fetch(`${APP}/oauth/consent?authorization_id=${authorizationId}`, {
      redirect: 'manual',
    });
    ok(
      anonPage.status >= 300 &&
        anonPage.status < 400 &&
        new URL(anonPage.headers.get('location'), APP).pathname === '/login',
      'unauthenticated consent must go to login',
    );
    const cookieA = await cookieHeader(A.session);
    const page = await (
      await fetch(`${APP}/oauth/consent?authorization_id=${authorizationId}`, {headers: {cookie: cookieA}})
    ).text();
    ok(
      page.includes('FJ E2E Client') && page.includes('localhost:9999'),
      'consent page lacks client name/callback host',
    );
    ok(page.includes('unverified'), 'self-declared DCR client name not flagged as unverified');
    ok((await decide(cookieA, authorizationId, 'approve', null)).status === 403, 'missing Origin accepted');
    ok(
      (await decide(cookieA, authorizationId, 'approve', 'https://evil.example')).status === 403,
      'foreign Origin accepted',
    );
    ok((await decide('', authorizationId, 'approve')).status === 401, 'no session accepted');
    const res = await decide(cookieA, authorizationId, 'approve');
    ok(res.status === 303, `approve ${res.status}`);
    const cb = new URL(res.headers.get('location'));
    ok(cb.searchParams.get('state') === state && cb.searchParams.get('code'), 'no code/state');
    const code = cb.searchParams.get('code');
    ok(
      (
        await token({
          grant_type: 'authorization_code',
          code,
          redirect_uri: REDIRECT,
          client_id: clientId,
          code_verifier: pkce().verifier,
        })
      ).status >= 400,
      'wrong PKCE verifier accepted',
    );
    const t = await token({
      grant_type: 'authorization_code',
      code,
      redirect_uri: REDIRECT,
      client_id: clientId,
      code_verifier: verifier,
    });
    // The failed attempt above may legitimately burn the code (OAuth 2.1 single use); then redo cleanly.
    accessA = t.status === 200 ? {clientId, ...t.body} : await connect(A, 'FJ E2E Client 2');
    if (t.status === 200)
      ok(
        (
          await token({
            grant_type: 'authorization_code',
            code,
            redirect_uri: REDIRECT,
            client_id: clientId,
            code_verifier: verifier,
          })
        ).status >= 400,
        'authorization code replay accepted',
      );
    const claims = decode(accessA.access_token);
    ok(
      claims.client_id === accessA.clientId && claims.sub === A.id && claims.iss === `${API}/auth/v1`,
      'access token not bound to client/user/issuer',
    );
    // Custom Access Token Hook: OAuth-client tokens are issued for this MCP resource only.
    ok(claims.aud === MCP_TOKEN_AUDIENCE, `OAuth token aud=${JSON.stringify(claims.aud)}`);
    ok(
      JSON.stringify([decode(A.session.access_token).aud].flat()) === '["authenticated"]',
      'browser session token got the MCP audience',
    );
  });

  await step('MCP: browser session JWT (no client_id) and garbage are 401 with discovery', async () => {
    const r = await mcp(A.session.access_token, 'tools/list');
    ok(r.status === 401, `session token got ${r.status}`);
    ok(
      (r.headers.get('www-authenticate') ?? '').includes(
        `resource_metadata="${APP}/.well-known/oauth-protected-resource"`,
      ),
      'no RFC 9728 challenge',
    );
    ok((await mcp('x.y.z', 'tools/list')).status === 401, 'garbage token accepted');
    const prm = await (await fetch(`${APP}/.well-known/oauth-protected-resource/api/mcp`)).json();
    ok(
      prm.resource === `${APP}/api/mcp` && prm.authorization_servers?.[0] === `${API}/auth/v1`,
      'protected resource metadata wrong',
    );
  });

  await step(
    'MCP: expired and tampered OAuth tokens are 401 (local claim pre-check never authenticates on its own)',
    async () => {
      const [h, p, sig] = accessA.access_token.split('.');
      const claims = decode(accessA.access_token);
      const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
      // Payload edited (later exp) but signature kept: passes the claim pre-check, must fail Supabase Auth.
      ok(
        (await mcp(`${h}.${enc({...claims, exp: claims.exp + 3600})}.${sig}`, 'tools/list')).status === 401,
        'tampered token accepted',
      );
      // Correctly signed but expired (local HS256 stack only): rejected before any Auth call.
      const header = JSON.parse(Buffer.from(h, 'base64url').toString());
      if (header.alg === 'HS256' && status.JWT_SECRET) {
        const body = `${enc(header)}.${enc({...claims, exp: Math.floor(Date.now() / 1000) - 60})}`;
        const expired = `${body}.${createHmac('sha256', status.JWT_SECRET).update(body).digest('base64url')}`;
        ok((await mcp(expired, 'tools/list')).status === 401, 'expired token accepted');
      } else console.log('NOTE expired-token signing skipped: stack does not use the local HS256 secret');
      ok((await mcp(accessA.access_token, 'tools/list')).status === 200, 'original token broken');
    },
  );

  await step(
    'MCP: tools/list exposes exactly the 7 customer tools with OAuth security metadata',
    async () => {
      const r = await mcp(accessA.access_token, 'tools/list');
      ok(r.status === 200, `tools/list ${r.status}`);
      const names = r.body.result.tools.map((t) => t.name).sort();
      ok(
        JSON.stringify(names) ===
          JSON.stringify([
            'calculate_numerology',
            'draw_tarot',
            'get_access_status',
            'get_account_profile',
            'get_journal_schema',
            'report_journal_action',
            'submit_reading_feedback',
          ]),
        `tools: ${names}`,
      );
      ok(
        r.body.result.tools.every((t) => t._meta?.securitySchemes?.[0]?.type === 'oauth2'),
        'securitySchemes missing',
      );
      ok(
        r.body.result.tools.every((t) => t.outputSchema?.type === 'object'),
        'outputSchema missing on a tool',
      );
      // 2026-07-28 era: stateless, per-request _meta envelope instead of an initialize handshake.
      const envelope = {
        'io.modelcontextprotocol/protocolVersion': '2026-07-28',
        'io.modelcontextprotocol/clientInfo': {name: 'fj-e2e', version: '1.0.0'},
        'io.modelcontextprotocol/clientCapabilities': {},
      };
      const modern = await fetch(`${APP}/api/mcp`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          accept: 'application/json, text/event-stream',
          'mcp-protocol-version': '2026-07-28',
          'mcp-method': 'tools/call',
          'mcp-name': 'get_journal_schema',
          authorization: `Bearer ${accessA.access_token}`,
        },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'tools/call',
          params: {name: 'get_journal_schema', arguments: {}, _meta: envelope},
        }),
      });
      const modernText = await modern.text();
      ok(
        modern.status === 200 && modernText.includes('user_google_drive'),
        `modern-era tools/call ${modern.status}: ${modernText.slice(0, 160)}`,
      );
      const init = await mcp(accessA.access_token, 'initialize', {
        protocolVersion: '2025-06-18',
        capabilities: {},
        clientInfo: {name: 'fj-e2e', version: '1.0.0'},
      });
      ok(
        init.status === 200 &&
          init.body?.result?.capabilities?.tools &&
          init.body.result.instructions?.includes('Google Sheets'),
        `initialize ${init.status}`,
      );
      ok(!names.some((n) => /publish|ops|sql|billing|grant/i.test(n)), 'operator tool leaked');
    },
  );

  await step(
    'Trial starts at first calculation (not at sign-in/consent); retry is idempotent; conflict rejected',
    async () => {
      ok(
        (await tool(accessA.access_token, 'get_access_status')).tier === 'free',
        'tier before first calculation must be free (no trial started)',
      );
      const requestId = randomUUID();
      const a = await tool(accessA.access_token, 'calculate_numerology', {
        birthDate: '1991-09-12',
        asOf: '2026-10-15',
        requestId,
      });
      ok(a.tier === 'trial' && a.replayed === false && a.lifePath === 5, `first calc ${JSON.stringify(a)}`);
      const b = await tool(accessA.access_token, 'calculate_numerology', {
        birthDate: '1991-09-12',
        asOf: '2026-10-15',
        requestId,
      });
      ok(
        b.replayed === true &&
          b.readingId === a.readingId &&
          b.remainingAtCompletion === a.remainingAtCompletion,
        'retry not replayed',
      );
      ok(
        (
          await tool(accessA.access_token, 'calculate_numerology', {
            birthDate: '1990-01-01',
            asOf: '2026-10-15',
            requestId,
          })
        ).error === 'IDEMPOTENCY_CONFLICT',
        'conflict not rejected',
      );
      ok((await usage(A.id)) === 1, 'retry consumed quota twice');
      const {data: ledger} = await admin.from('user_readings').select('*').eq('user_id', A.id);
      ok(
        ledger.length === 1 && !JSON.stringify(ledger).includes('1991-09-12'),
        'birth date persisted or ledger wrong',
      );
      const drawId = randomUUID();
      trialDraw = {drawId};
      const t1 = await tool(accessA.access_token, 'draw_tarot', {count: 3, drawId});
      trialDraw.cards = t1.cards;
      const t2 = await tool(accessA.access_token, 'draw_tarot', {count: 3, drawId});
      ok(
        t1.cards?.length === 3 &&
          JSON.stringify(t1.cards) === JSON.stringify(t2.cards) &&
          t2.replayed === true,
        'tarot draw not reproducible/idempotent',
      );
    },
  );

  await step('Tarot retry on a later day replays the original draw instead of charging again', async () => {
    const drawId = randomUUID();
    const first = await tool(accessA.access_token, 'draw_tarot', {count: 1, drawId});
    ok(first.replayed === false, 'first draw');
    const yesterday = new Date(Date.now() - 864e5).toISOString().slice(0, 10);
    const {error} = await admin
      .from('user_readings')
      .update({target_date: yesterday})
      .eq('id', first.readingId);
    ok(!error, 'fixture update');
    const before = await usage(A.id);
    const again = await tool(accessA.access_token, 'draw_tarot', {count: 1, drawId});
    const after = await usage(A.id);
    ok(
      again.replayed === true && JSON.stringify(again.cards) === JSON.stringify(first.cards),
      'cross-day retry not replayed',
    );
    ok(before === after, 'cross-day retry consumed quota');
  });

  await step(
    'Free tier after trial: tarot denied, numerology 3/ISO-week then USAGE_LIMIT_REACHED',
    async () => {
      const {error} = await admin
        .from('user_access')
        .update({
          trial_started_at: new Date(Date.now() - 20 * 864e5).toISOString(),
          trial_ends_at: new Date(Date.now() - 6 * 864e5).toISOString(),
        })
        .eq('user_id', A.id);
      ok(!error, 'fixture update');
      // Trial-time readings stay in the ledger but count only against the trial tier.
      ok((await tool(accessA.access_token, 'get_access_status')).tier === 'free', 'expired trial not free');
      ok(
        (await tool(accessA.access_token, 'draw_tarot', {count: 1})).error === 'FEATURE_NOT_INCLUDED',
        'free user drew tarot',
      );
      // An identical retry of a draw made during the trial replays it (same cards, no usage) instead of failing.
      const replay = await tool(accessA.access_token, 'draw_tarot', {count: 3, drawId: trialDraw.drawId});
      ok(
        replay.replayed === true &&
          replay.tier === 'free' &&
          JSON.stringify(replay.cards) === JSON.stringify(trialDraw.cards),
        `post-trial retry ${JSON.stringify(replay)}`,
      );
      ok(
        (await tool(accessA.access_token, 'draw_tarot', {count: 1, drawId: trialDraw.drawId})).error ===
          'IDEMPOTENCY_CONFLICT',
        'post-trial retry with a different count accepted',
      );
      ok((await usage(A.id, {tier_at_use: 'free'})) === 0, 'post-trial replay consumed usage');
      const remaining = [];
      for (let i = 0; i < 3; i++)
        remaining.push(
          (
            await tool(accessA.access_token, 'calculate_numerology', {
              birthDate: '1991-09-12',
              asOf: '2026-10-15',
            })
          ).remainingAtCompletion,
        );
      ok(JSON.stringify(remaining) === '[2,1,0]', `remaining ${remaining}`);
      ok(
        (
          await tool(accessA.access_token, 'calculate_numerology', {
            birthDate: '1991-09-12',
            asOf: '2026-10-15',
          })
        ).error === 'USAGE_LIMIT_REACHED',
        '4th free calc allowed',
      );
    },
  );

  await step(
    'Optional analytics tools refuse when globally disabled; schema tool never claims a Google save',
    async () => {
      if (!ANALYTICS) {
        ok(
          (
            await tool(accessA.access_token, 'submit_reading_feedback', {
              readingId: randomUUID(),
              usefulness: 5,
              matchAssessment: 'matched',
              explicitUserRequest: true,
            })
          ).error === 'OPTIONAL_ANALYTICS_DISABLED',
          'feedback accepted while disabled',
        );
        ok(
          (
            await tool(accessA.access_token, 'report_journal_action', {
              requestId: randomUUID(),
              action: 'journal_save_reported',
              explicitUserRequest: true,
            })
          ).error === 'OPTIONAL_ANALYTICS_DISABLED',
          'report accepted while disabled',
        );
        ok(
          (await preferences(A, {analytics: 'yes'})).status === 503,
          'analytics opt-in accepted while globally disabled',
        );
      }
      const s = await tool(accessA.access_token, 'get_journal_schema');
      ok(
        s.ownership === 'user_google_drive' &&
          s.sheets.length === 4 &&
          s.writeRules.some((r) => r.includes('RAW')),
        'journal schema/write rules',
      );
      const p = await tool(accessA.access_token, 'get_account_profile');
      ok(p.id === A.id && !JSON.stringify(p).includes('@'), 'profile leaks email');
    },
  );

  if (ANALYTICS)
    await step(
      'Analytics mode: separate consents, topic only with interest consent, feedback/report, withdrawal deletes optional data',
      async () => {
        // B signed up seconds ago: a near-signup opt-in enters the signup cohort with self-reported source (migration 06 path).
        const conn = await connect(B, 'FJ E2E Analytics');
        ok((await tool(conn.access_token, 'get_account_profile')).id === B.id, 'profile before consent');
        await new Promise((r) => setTimeout(r, 1000));
        ok(
          !(await admin.from('funnel_events').select('id').eq('user_id', B.id)).data.length,
          'connection telemetry recorded without consent',
        );
        ok((await preferences(B, {analytics: 'yes', source: 'threads'})).status === 303, 'opt-in failed');
        ok((await tool(conn.access_token, 'get_account_profile')).id === B.id, 'profile after consent');
        let connected = [];
        for (let i = 0; i < 20 && !connected.length; i++) {
          await new Promise((r) => setTimeout(r, 250));
          ({data: connected} = await admin
            .from('funnel_events')
            .select('id')
            .eq('user_id', B.id)
            .eq('event_name', 'mcp_connected'));
        }
        ok(connected.length === 1, 'deferred mcp_connected event not recorded after the response');
        await tool(conn.access_token, 'get_account_profile');
        await new Promise((r) => setTimeout(r, 1000));
        ok(
          (
            await admin
              .from('funnel_events')
              .select('id')
              .eq('user_id', B.id)
              .eq('event_name', 'mcp_connected')
          ).data.length === 1,
          'repeat connection duplicated the event',
        );
        const {data: acc} = await admin
          .from('user_access')
          .select('analytics_consent_at,interest_consent_at')
          .eq('user_id', B.id)
          .single();
        ok(
          acc.analytics_consent_at && !acc.interest_consent_at,
          'interest consent inferred from analytics consent',
        );
        const {data: reg} = await admin
          .from('funnel_events')
          .select('source_channel,source_evidence')
          .eq('user_id', B.id)
          .eq('event_name', 'registration');
        ok(
          reg?.length === 1 &&
            reg[0].source_channel === 'threads' &&
            reg[0].source_evidence === 'self_reported',
          'registration cohort/attribution wrong',
        );
        const r1 = await tool(conn.access_token, 'calculate_numerology', {
          birthDate: '1991-09-12',
          asOf: '2026-10-15',
          topic: 'love',
        });
        const {data: t1} = await admin.from('user_readings').select('topic').eq('id', r1.readingId).single();
        ok(t1.topic === null, 'topic stored without interest consent');
        ok(
          (await preferences(B, {analytics: 'yes', interests: 'yes'})).status === 303,
          'interest opt-in failed',
        );
        const r2 = await tool(conn.access_token, 'calculate_numerology', {
          birthDate: '1991-09-12',
          asOf: '2026-10-15',
          topic: 'work',
        });
        const {data: t2} = await admin.from('user_readings').select('topic').eq('id', r2.readingId).single();
        ok(t2.topic === 'work', 'topic not stored with interest consent');
        const {data: ev} = await admin
          .from('funnel_events')
          .select('event_name,source_channel')
          .eq('user_id', B.id)
          .eq('event_name', 'reading_completed');
        ok(
          ev.length === 2 && ev.every((e) => e.source_channel === 'unknown'),
          'unregistered client labelled as a channel',
        );
        ok(
          (
            await tool(conn.access_token, 'submit_reading_feedback', {
              readingId: r2.readingId,
              usefulness: 4,
              matchAssessment: 'mixed',
              explicitUserRequest: true,
            })
          ).saved === true,
          'feedback not saved',
        );
        const {data: other} = await admin
          .from('user_readings')
          .select('id')
          .eq('user_id', A.id)
          .limit(1)
          .single();
        ok(
          (
            await tool(conn.access_token, 'submit_reading_feedback', {
              readingId: other.id,
              usefulness: 4,
              matchAssessment: 'mixed',
              explicitUserRequest: true,
            })
          ).error === 'FEEDBACK_NOT_ACCEPTED',
          'feedback on another user reading accepted',
        );
        const rep = await tool(conn.access_token, 'report_journal_action', {
          requestId: randomUUID(),
          action: 'journal_save_reported',
          readingId: r2.readingId,
          explicitUserRequest: true,
        });
        ok(
          rep.recorded === true && rep.verification === 'self_reported_not_independently_verified',
          'report not recorded as self-reported',
        );
        ok((await preferences(B, {})).status === 303, 'withdrawal failed');
        const left = await Promise.all(
          ['funnel_events', 'reading_feedback'].map((t) => admin.from(t).select('id').eq('user_id', B.id)),
        );
        ok(
          left.every((x) => x.data.length === 0),
          'optional events/feedback survived withdrawal',
        );
        const {data: kept} = await admin.from('user_readings').select('topic').eq('user_id', B.id);
        ok(
          kept.length === 2 && kept.every((k) => k.topic === null),
          'operational ledger lost or topics kept',
        );
      },
    );

  await step('Data API: signed-in users can read or change nothing directly (app-only access)', async () => {
    const a = userClient(A.session);
    for (const t of [
      'user_access',
      'subscriptions',
      'user_readings',
      'reading_feedback',
      'funnel_events',
      'billing_events',
    ]) {
      const {data, error} = await a.from(t).select('*').limit(1);
      ok(error || !data?.length, `signed-in user read ${t} through the Data API`);
    }
    ok(
      (
        await a
          .from('user_access')
          .update({trial_ends_at: '2099-01-01T00:00:00Z'})
          .eq('user_id', A.id)
          .select()
      ).error,
      'A extended own trial',
    );
    ok((await a.from('user_readings').delete().eq('user_id', A.id).select()).error, 'A reset own usage');
    ok(
      (
        await a.from('subscriptions').insert({
          user_id: A.id,
          provider: 'self',
          provider_customer_id: 'c',
          provider_subscription_id: 's',
          status: 'active',
        })
      ).error,
      'A self-granted subscription',
    );
    ok(
      (
        await a.rpc('fj_record_calculation', {
          p_user_id: A.id,
          p_request_id: randomUUID(),
          p_fingerprint: 'a'.repeat(64),
          p_feature: 'calculate_numerology',
          p_algorithm: 'x',
          p_target_date: '2026-10-15',
        })
      ).error,
      'A called quota RPC',
    );
    ok(
      (
        await a.rpc('fj_set_privacy', {
          p_user_id: B.id,
          p_analytics: true,
          p_interests: true,
          p_version: '2026-10-v2',
        })
      ).error,
      'A changed B consent',
    );
    ok((await a.rpc('fj_access_status', {p_user_id: B.id})).error, 'A read B access status');
  });

  await step(
    'Web/MCP boundary: an MCP OAuth token (forged cookie, bearer, stolen binding) cannot use account APIs',
    async () => {
      const E = await newUser('e');
      created.push(E.id);
      const conn = await connect(E, 'FJ E2E Boundary');
      const oauthSession = {access_token: conn.access_token, refresh_token: conn.refresh_token};
      const forged = await cookieHeader(oauthSession, false);
      const forgedBound = await cookieHeader(oauthSession, oauthSession); // binding for the OAuth session id
      const realUnbound = await cookieHeader(E.session, false);
      const realOtherBinding = await cookieHeader(E.session, B.session);
      const form = {origin: APP, 'content-type': 'application/x-www-form-urlencoded'};
      const exportAs = (headers) =>
        fetch(`${APP}/api/account/export?resource=access`, {headers, redirect: 'manual'});
      for (const [label, headers] of [
        ['forged cookie', {cookie: forged}],
        ['forged cookie + binding', {cookie: forgedBound}],
        ['bearer only', {authorization: `Bearer ${conn.access_token}`}],
        ['real cookie without binding', {cookie: realUnbound}],
        ["real cookie + another user's binding", {cookie: realOtherBinding}],
      ]) {
        const r = await exportAs(headers);
        ok(r.status === 401, `export with ${label}: ${r.status}`);
      }
      for (const cookie of [forged, forgedBound]) {
        const prefs = await fetch(`${APP}/api/account/preferences`, {
          method: 'POST',
          redirect: 'manual',
          headers: {...form, cookie},
          body: new URLSearchParams({analytics: 'no'}),
        });
        ok(prefs.status === 401, `preferences with OAuth token: ${prefs.status}`);
        const revoke = await fetch(`${APP}/api/oauth/revoke`, {
          method: 'POST',
          redirect: 'manual',
          headers: {...form, cookie},
          body: new URLSearchParams({client_id: conn.clientId}),
        });
        ok(revoke.status === 401, `revoke with OAuth token: ${revoke.status}`);
        const del = await fetch(`${APP}/api/account/delete`, {
          method: 'POST',
          redirect: 'manual',
          headers: {...form, cookie},
          body: new URLSearchParams({confirmation: 'DELETE_MY_ACCOUNT'}),
        });
        ok(del.status === 401, `delete with OAuth token: ${del.status}`);
        const page = await (await fetch(`${APP}/login`, {headers: {cookie}})).text();
        ok(
          !page.includes('Signed in with Google') && !page.includes(E.email),
          'login page trusted the OAuth token',
        );
      }
      const {data: still} = await admin.auth.admin.getUserById(E.id);
      ok(still?.user?.id === E.id, 'user was deleted through an OAuth token');
      ok((await mcp(conn.access_token, 'tools/list')).status === 200, 'connection broken by the attempts');

      // CSRF: the real, bound session is still refused for cross-site or non-form requests.
      const real = await cookieHeader(E.session);
      ok((await exportAs({cookie: real})).status === 200, 'own bound browser session cannot export');
      ok(
        (await exportAs({cookie: real, 'sec-fetch-site': 'cross-site'})).status === 403,
        'cross-site export allowed',
      );
      const json = await fetch(`${APP}/api/account/delete`, {
        method: 'POST',
        redirect: 'manual',
        headers: {cookie: real, origin: APP, 'content-type': 'text/plain'},
        body: 'confirmation=DELETE_MY_ACCOUNT',
      });
      ok(json.status === 403, `text/plain deletion ${json.status}`);
      const sameSite = await fetch(`${APP}/api/account/delete`, {
        method: 'POST',
        redirect: 'manual',
        headers: {...form, cookie: real, 'sec-fetch-site': 'same-site'},
        body: new URLSearchParams({confirmation: 'DELETE_MY_ACCOUNT'}),
      });
      ok(sameSite.status === 403, `same-site (sibling subdomain) deletion ${sameSite.status}`);
      // The user id always comes from the verified session, never from input.
      const other = await (
        await fetch(`${APP}/api/account/export?resource=access&user_id=${A.id}`, {headers: {cookie: real}})
      ).json();
      ok(
        other.rows.every((row) => row.user_id === E.id),
        "export returned another user's rows",
      );
    },
  );

  await step('Export: own data only, paged, no fingerprint; requires a session', async () => {
    ok((await fetch(`${APP}/api/account/export?resource=readings`)).status === 401, 'export without session');
    const cookieA = await cookieHeader(A.session);
    ok(
      (await fetch(`${APP}/api/account/export?resource=secrets`, {headers: {cookie: cookieA}})).status ===
        400,
      'unknown resource accepted',
    );
    const r = await fetch(`${APP}/api/account/export?resource=readings`, {headers: {cookie: cookieA}});
    const body = await r.json();
    ok(
      r.status === 200 && r.headers.get('cache-control') === 'no-store' && body.rows.length > 0,
      `export ${r.status}`,
    );
    ok(
      !JSON.stringify(body).includes('request_fingerprint') && !JSON.stringify(body).includes('1991-09-12'),
      'export leaks fingerprint or birth date',
    );
    const {data: all} = await admin.from('user_readings').select('id').eq('user_id', A.id);
    ok(
      body.rows.length === Math.min(all.length, 100) &&
        body.rows.every((x) => all.some((y) => y.id === x.id)),
      "export rows are not exactly A's rows",
    );
  });

  await step('OAuth: refresh token rotates and yields a working access token', async () => {
    const r = await token({
      grant_type: 'refresh_token',
      refresh_token: accessA.refresh_token,
      client_id: accessA.clientId,
    });
    ok(r.status === 200 && r.body.access_token, `refresh ${r.status}`);
    ok(decode(r.body.access_token).aud === MCP_TOKEN_AUDIENCE, 'refreshed token lost the MCP audience');
    ok((await mcp(r.body.access_token, 'tools/list')).status === 200, 'refreshed token rejected');
    accessA = {...accessA, ...r.body};
  });

  await step(
    'OAuth: user revokes the connection in the app; access and refresh tokens stop working',
    async () => {
      const cookieA = await cookieHeader(A.session);
      const page = await (await fetch(`${APP}/login`, {headers: {cookie: cookieA}})).text();
      ok(page.includes('FJ E2E Client'), 'connected apps not listed on account page');
      const evil = await fetch(`${APP}/api/oauth/revoke`, {
        method: 'POST',
        redirect: 'manual',
        headers: {
          cookie: cookieA,
          origin: 'https://evil.example',
          'content-type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({client_id: accessA.clientId}),
      });
      ok(evil.status === 403, 'cross-site revoke accepted');
      const res = await fetch(`${APP}/api/oauth/revoke`, {
        method: 'POST',
        redirect: 'manual',
        headers: {cookie: cookieA, origin: APP, 'content-type': 'application/x-www-form-urlencoded'},
        body: new URLSearchParams({client_id: accessA.clientId}),
      });
      ok(res.status === 303, `revoke ${res.status}`);
      ok(
        (await mcp(accessA.access_token, 'tools/list')).status === 401,
        'access token still valid after revoke',
      );
      ok(
        (
          await token({
            grant_type: 'refresh_token',
            refresh_token: accessA.refresh_token,
            client_id: accessA.clientId,
          })
        ).status >= 400,
        'refresh still valid after revoke',
      );
    },
  );

  await step(
    "OAuth: deny returns access_denied to the client; another user cannot act on A's request",
    async () => {
      const clientId = await registerClient('FJ E2E Deny');
      const {challenge} = pkce();
      const state = randomUUID();
      const authorizationId = await startAuthorization(clientId, challenge, state);
      const cookieA = await cookieHeader(A.session),
        cookieB = await cookieHeader(B.session);
      ok(
        (
          await fetch(`${APP}/oauth/consent?authorization_id=${authorizationId}`, {
            headers: {cookie: cookieA},
          })
        ).status === 200,
        'A consent page',
      );
      const hijack = await decide(cookieB, authorizationId, 'approve');
      ok(
        hijack.status !== 303 || !new URL(hijack.headers.get('location')).searchParams.get('code'),
        "B approved A's authorization",
      );
      const res = await decide(cookieA, authorizationId, 'deny');
      ok(res.status === 303, `deny ${res.status}`);
      const cb = new URL(res.headers.get('location'));
      ok(
        cb.searchParams.get('error') === 'access_denied' && !cb.searchParams.get('code'),
        'deny did not return access_denied',
      );
    },
  );

  await step(
    'Cron: bearer CRON_SECRET required; maintenance purges via the app (Threads insights off)',
    async () => {
      ok((await fetch(`${APP}/api/cron/maintenance`)).status === 401, 'cron without secret');
      ok(
        (
          await fetch(`${APP}/api/cron/maintenance`, {
            headers: {authorization: 'Bearer wrong-secret-wrong-secret-wrong-secret'},
          })
        ).status === 401,
        'cron with wrong secret',
      );
      if (!process.env.CRON_SECRET)
        throw new Error('CRON_SECRET not provided to the E2E process; source the same env as the app');
      const r = await fetch(`${APP}/api/cron/maintenance`, {
        headers: {authorization: `Bearer ${process.env.CRON_SECRET}`},
      });
      const body = await r.json();
      ok(
        r.status === 200 && body.insights === 'disabled' && body.results.every((x) => x.purged !== false),
        `maintenance ${r.status} ${JSON.stringify(body).slice(0, 120)}`,
      );
    },
  );

  await step(
    'Ops API: separate HMAC, disabled by default; signed report works only when enabled',
    async () => {
      const body = JSON.stringify({
        requestId: randomUUID(),
        action: 'report',
        from: new Date(Date.now() - 7 * 864e5).toISOString(),
        until: new Date().toISOString(),
      });
      const send = (b, sig, ts = String(Math.floor(Date.now() / 1000))) =>
        fetch(`${APP}/api/ops`, {
          method: 'POST',
          headers: {'content-type': 'application/json', 'x-fj-timestamp': ts, 'x-fj-signature': sig},
          body: b,
        });
      if (process.env.OPERATIONS_ENABLED !== 'true') {
        ok((await send(body, '0'.repeat(64))).status === 503, 'ops reachable while disabled');
        return;
      }
      const ts = String(Math.floor(Date.now() / 1000)),
        sig = signOps(process.env.OPS_HMAC_KEY, 'POST', '/api/ops', ts, body);
      ok((await send(body, '0'.repeat(64), ts)).status === 401, 'unsigned ops accepted');
      ok((await send(body.replace('report', 'report '), sig, ts)).status === 401, 'tampered body accepted');
      ok((await send(body, sig, String(Number(ts) - 600))).status === 401, 'stale timestamp accepted');
      const r = await send(body, sig, ts);
      const out = await r.json();
      ok(
        r.status === 200 &&
          Array.isArray(out.caveats) &&
          out.cohorts?.population === 'consented_near_signup_accounts_only',
        `signed report ${r.status} ${JSON.stringify(out).slice(0, 160)}`,
      );
    },
  );

  await step(
    'Concurrency and suspension: 10 parallel identical draws charge once; suspended account is refused everywhere',
    async () => {
      const D = await newUser('d');
      created.push(D.id);
      const conn = await connect(D, 'FJ E2E Concurrency');
      ok(
        (await tool(conn.access_token, 'calculate_numerology', {birthDate: '1991-09-12', asOf: '2026-10-15'}))
          .tier === 'trial',
        'trial not started',
      );
      const drawId = randomUUID();
      const draws = await Promise.all(
        Array.from({length: 10}, () => tool(conn.access_token, 'draw_tarot', {count: 3, drawId})),
      );
      ok(
        draws.every(
          (d) =>
            !d.error &&
            d.readingId === draws[0].readingId &&
            JSON.stringify(d.cards) === JSON.stringify(draws[0].cards),
        ),
        'parallel draws diverged',
      );
      ok(
        draws.filter((d) => d.replayed === false).length === 1,
        `fresh draws ${draws.filter((d) => d.replayed === false).length}`,
      );
      ok(
        (await usage(D.id, {feature_key: 'draw_tarot'})) === 1,
        'parallel identical draws consumed more than one unit',
      );
      ok((await tool(conn.access_token, 'get_access_status')).tier === 'trial', 'access status');
      ok(
        !(
          await admin.from('user_access').update({suspended_at: new Date().toISOString()}).eq('user_id', D.id)
        ).error,
        'fixture update',
      );
      ok(
        (await tool(conn.access_token, 'get_access_status')).tier === 'suspended',
        'suspension not reported',
      );
      ok(
        (await tool(conn.access_token, 'draw_tarot', {count: 3, drawId})).error === 'ACCOUNT_SUSPENDED',
        'suspended replay allowed',
      );
      ok(
        (await tool(conn.access_token, 'calculate_numerology', {birthDate: '1991-09-12', asOf: '2026-10-15'}))
          .error === 'ACCOUNT_SUSPENDED',
        'suspended calculation allowed',
      );
    },
  );

  await step(
    'Account deletion: confirmation + Origin required; afterwards OAuth tokens are rejected',
    async () => {
      const C = await newUser('c');
      created.push(C.id);
      const conn = await connect(C, 'FJ E2E Delete');
      ok((await mcp(conn.access_token, 'tools/list')).status === 200, 'C token not working before deletion');
      const cookieC = await cookieHeader(C.session);
      const post = (body, origin = APP) =>
        fetch(`${APP}/api/account/delete`, {
          method: 'POST',
          redirect: 'manual',
          headers: {cookie: cookieC, origin, 'content-type': 'application/x-www-form-urlencoded'},
          body: new URLSearchParams(body),
        });
      ok((await post({confirmation: 'nope'})).status === 400, 'deletion without confirmation');
      ok(
        (await post({confirmation: 'DELETE_MY_ACCOUNT'}, 'https://evil.example')).status === 403,
        'cross-site deletion',
      );
      ok((await post({confirmation: 'DELETE_MY_ACCOUNT'})).status === 303, 'deletion failed');
      ok((await mcp(conn.access_token, 'tools/list')).status === 401, 'deleted user token still accepted');
      const {data} = await admin.from('user_access').select('user_id').eq('user_id', C.id);
      ok((data ?? []).length === 0, 'user_access row survived deletion');
      created.splice(created.indexOf(C.id), 1);
    },
  );
} finally {
  for (const id of created) await admin.auth.admin.deleteUser(id).catch(() => {});
}
const summary = {
  ranAt: new Date().toISOString(),
  analyticsMode: ANALYTICS,
  operationsMode: process.env.OPERATIONS_ENABLED === 'true',
  target: {supabase: 'local CLI stack (loopback)', app: APP},
  passed: results.length - failures,
  failed: failures,
  results,
};
const outIndex = process.argv.indexOf('--out');
if (outIndex > 0) writeFileSync(process.argv[outIndex + 1], JSON.stringify(summary, null, 2) + '\n');
console.log(`${summary.passed} passed / ${failures} failed`);
process.exitCode = failures ? 1 : 0;
