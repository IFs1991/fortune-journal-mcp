// LOCAL-ONLY probe: does Supabase Auth's OAuth 2.1 server bind access tokens to the RFC 8707 `resource`
// the client requests (as the MCP authorization spec expects)? Runs one DCR + PKCE + consent flow through this
// app with `resource=<APP_ORIGIN>/api/mcp` and reports only the token's aud/iss/client_id claims, never the token.
// Usage: supabase start; start the app on localhost:3000 (same env as e2e-local); node scripts/probe-resource-audience.mjs
import {spawnSync} from 'node:child_process';
import {createHash, randomBytes, randomUUID} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';
import {createServerClient} from '@supabase/ssr';

const status = JSON.parse(
  spawnSync('supabase', ['status', '-o', 'json'], {encoding: 'utf8', input: ''}).stdout || '{}',
);
const API = status.API_URL;
const APP = process.env.APP_ORIGIN ?? 'http://localhost:3000';
const loopback = (url) => ['127.0.0.1', 'localhost', '[::1]'].includes(new URL(url).hostname);
if (!API || !loopback(API) || !loopback(APP))
  throw new Error('Refusing: loopback Supabase stack and app only.');
const options = {auth: {persistSession: false, autoRefreshToken: false}};
const admin = createClient(API, status.SECRET_KEY, options);
const RESOURCE = `${APP}/api/mcp`;
const REDIRECT = 'http://localhost:9999/callback';

const email = `fj-probe-aud-${Date.now()}@example.test`;
const {data: created, error: createError} = await admin.auth.admin.createUser({email, email_confirm: true});
if (createError) throw createError;
try {
  const {data: link} = await admin.auth.admin.generateLink({type: 'magiclink', email});
  const {data: verified} = await createClient(API, status.PUBLISHABLE_KEY, options).auth.verifyOtp({
    type: 'magiclink',
    token_hash: link.properties.hashed_token,
  });
  const jar = new Map();
  const ssr = createServerClient(API, status.PUBLISHABLE_KEY, {
    cookies: {
      getAll: () => [...jar].map(([name, value]) => ({name, value})),
      setAll: (items) => items.forEach(({name, value}) => (value ? jar.set(name, value) : jar.delete(name))),
    },
  });
  await ssr.auth.setSession(verified.session);
  const cookie = [...jar].map(([name, value]) => `${name}=${value}`).join('; ');

  const registration = await fetch(`${API}/auth/v1/oauth/clients/register`, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({
      client_name: 'FJ Audience Probe',
      redirect_uris: [REDIRECT],
      token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code'],
      response_types: ['code'],
    }),
  });
  const clientId = (await registration.json()).client_id;
  const verifier = randomBytes(32).toString('base64url');
  const authorize = new URL(`${API}/auth/v1/oauth/authorize`);
  const params = {
    response_type: 'code',
    client_id: clientId,
    redirect_uri: REDIRECT,
    code_challenge: createHash('sha256').update(verifier).digest('base64url'),
    code_challenge_method: 'S256',
    scope: 'openid',
    state: randomUUID(),
    resource: RESOURCE,
  };
  for (const [key, value] of Object.entries(params)) authorize.searchParams.set(key, value);
  const consent = await fetch(authorize, {redirect: 'manual'});
  const authorizationId = new URL(consent.headers.get('location')).searchParams.get('authorization_id');
  const decision = await fetch(`${APP}/api/oauth/decision`, {
    method: 'POST',
    redirect: 'manual',
    headers: {'content-type': 'application/x-www-form-urlencoded', cookie, origin: APP},
    body: new URLSearchParams({authorization_id: authorizationId, decision: 'approve'}),
  });
  const code = new URL(decision.headers.get('location')).searchParams.get('code');
  const tokenResponse = await fetch(`${API}/auth/v1/oauth/token`, {
    method: 'POST',
    headers: {'content-type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: REDIRECT,
      client_id: clientId,
      code_verifier: verifier,
      resource: RESOURCE,
    }),
  });
  const token = await tokenResponse.json();
  const claims = JSON.parse(Buffer.from(token.access_token.split('.')[1], 'base64url').toString());
  const metadata = await (await fetch(`${API}/auth/v1/.well-known/oauth-authorization-server`)).json();
  console.log(
    JSON.stringify(
      {
        ranAt: new Date().toISOString(),
        requestedResource: RESOURCE,
        tokenStatus: tokenResponse.status,
        aud: claims.aud,
        audienceBoundToResource: [claims.aud].flat().includes(RESOURCE),
        issIsProject: claims.iss === `${API}/auth/v1`,
        hasClientId: typeof claims.client_id === 'string',
        asMetadata: {
          resource_indicators_supported: metadata.resource_indicators_supported ?? null,
          client_id_metadata_document_supported: metadata.client_id_metadata_document_supported ?? null,
          registration_endpoint: !!metadata.registration_endpoint,
        },
      },
      null,
      2,
    ),
  );
} finally {
  await admin.auth.admin.deleteUser(created.user.id).catch(() => {});
}
