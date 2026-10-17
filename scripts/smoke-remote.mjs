// Read-only smoke test of a deployed origin (Staging first). Sends only unauthenticated GET/POST requests that
// change nothing: health, protected-resource metadata, the 401 discovery challenge, Origin refusal, the 501
// webhook, the Supabase authorization-server metadata and the checked-in .mcp.json URL. No token, cookie or
// secret is used or printed. Running it against a remote target still needs the owner's OK (it is traffic).
//   node scripts/smoke-remote.mjs https://staging.example.com [--supabase https://<ref>.supabase.co] [--mcp-json .mcp.json]
import {readFileSync} from 'node:fs';

const origin = process.argv[2];
const arg = (name) =>
  process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : undefined;
if (!origin || !/^(https:\/\/[^/]+|http:\/\/localhost:\d+)$/.test(origin))
  throw new Error(
    'Usage: node scripts/smoke-remote.mjs <https origin> [--supabase <url>] [--mcp-json <file>]',
  );
const results = [];
async function check(name, fn) {
  try {
    const detail = await fn();
    results.push({name, ok: true});
    console.log('PASS', name, detail ?? '');
  } catch (error) {
    results.push({name, ok: false});
    console.log('FAIL', name, '-', String(error?.message ?? error).slice(0, 200));
  }
}
const ok = (cond, msg) => {
  if (!cond) throw new Error(msg);
};
const rpc = (headers = {}) =>
  fetch(`${origin}/api/mcp`, {
    method: 'POST',
    redirect: 'manual',
    headers: {'content-type': 'application/json', accept: 'application/json, text/event-stream', ...headers},
    body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'tools/list'}),
  });

let prm;
await check('health', async () => {
  const r = await fetch(`${origin}/api/health`, {redirect: 'manual'});
  ok(r.status === 200, `HTTP ${r.status} (Deployment Protection still on?)`);
  const body = await r.json();
  ok(body.status === 'up' && body.billing === 'not_connected', JSON.stringify(body));
  return `version ${body.version}`;
});
await check('protected resource metadata (RFC 9728)', async () => {
  prm = await (await fetch(`${origin}/.well-known/oauth-protected-resource/api/mcp`)).json();
  ok(prm.resource === `${origin}/api/mcp`, `resource=${prm.resource}`);
  ok(
    /^https:\/\/[a-z0-9]+\.supabase\.co\/auth\/v1$/.test(prm.authorization_servers?.[0] ?? '') ||
      origin.startsWith('http://localhost'),
    `authorization_servers=${JSON.stringify(prm.authorization_servers)}`,
  );
});
await check('MCP without a token: 401 + resource_metadata challenge', async () => {
  const r = await rpc();
  ok(r.status === 401, `HTTP ${r.status}`);
  const challenge = r.headers.get('www-authenticate') ?? '';
  ok(challenge.includes(`resource_metadata="${origin}/.well-known/oauth-protected-resource"`), challenge);
});
await check('MCP with a foreign Origin: 403 before authentication', async () => {
  const r = await rpc({origin: 'https://evil.example'});
  ok(r.status === 403, `HTTP ${r.status}`);
});
await check('MCP with a garbage bearer: 401', async () => {
  ok((await rpc({authorization: 'Bearer x.y.z'})).status === 401, 'not 401');
});
await check('billing webhook stays 501', async () => {
  const r = await fetch(`${origin}/api/billing/webhook`, {method: 'POST', redirect: 'manual'});
  ok(r.status === 501, `HTTP ${r.status}`);
});
await check('authorization server metadata', async () => {
  const issuer = arg('--supabase')
    ? `${arg('--supabase').replace(/\/$/, '')}/auth/v1`
    : prm?.authorization_servers?.[0];
  ok(issuer, 'no issuer known');
  const base = new URL(issuer);
  // RFC 8414 path insertion first (what MCP clients try first), then the path-appended form Supabase also serves.
  const urls = [
    `${base.origin}/.well-known/oauth-authorization-server${base.pathname}`,
    `${issuer}/.well-known/oauth-authorization-server`,
  ];
  let meta;
  let served;
  for (const url of urls) {
    const r = await fetch(url);
    if (r.ok) {
      meta = await r.json();
      served = url === urls[0] ? 'RFC 8414 path insertion' : 'path-appended only';
      break;
    }
  }
  ok(meta, 'no authorization server metadata at either well-known URL');
  ok(meta.issuer === issuer && meta.authorization_endpoint && meta.token_endpoint, 'incomplete metadata');
  ok((meta.code_challenge_methods_supported ?? []).includes('S256'), 'PKCE S256 not advertised');
  return `(${served}; ${meta.registration_endpoint ? 'DCR enabled' : 'DCR disabled'})`;
});
await check('.mcp.json points at this origin over HTTP transport', async () => {
  const config = JSON.parse(readFileSync(arg('--mcp-json') ?? '.mcp.json', 'utf8'));
  const server = config.mcpServers?.['fortune-journal'];
  ok(server?.type === 'http' && server?.url === `${origin}/api/mcp`, `found ${JSON.stringify(server)}`);
});

const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed / ${failed} failed`);
process.exitCode = failed ? 1 : 0;
