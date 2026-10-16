import {readFile} from 'node:fs/promises';
import {signOps} from '../src/domain/security.ts';
// Use node --env-file=.env.local --experimental-strip-types scripts/ops.mjs command.json
// This is an explicit operator command, never included in a customer's MCP configuration.
const input = process.argv[2];
if (!input) throw new Error('Usage: scripts/ops.mjs command.json');
const origin = process.env.APP_ORIGIN;
if (!origin || (!/^https:\/\/[^/]+$/.test(origin) && !/^http:\/\/localhost:\d+$/.test(origin)))
  throw new Error('Invalid APP_ORIGIN');
const body = await readFile(input, 'utf8');
if (Buffer.byteLength(body) > 65536) throw new Error('Command too large');
JSON.parse(body);
const path = '/api/ops',
  timestamp = String(Math.floor(Date.now() / 1000));
const signature = signOps(process.env.OPS_HMAC_KEY ?? '', 'POST', path, timestamp, body);
const response = await fetch(`${origin}${path}`, {
  method: 'POST',
  headers: {'Content-Type': 'application/json', 'x-fj-timestamp': timestamp, 'x-fj-signature': signature},
  body,
  redirect: 'error',
  signal: AbortSignal.timeout(65000),
});
console.log(await response.text());
if (!response.ok) process.exitCode = 1;
