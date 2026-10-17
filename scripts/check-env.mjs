// Read-only check of one deployment environment's variables (Vercel Production or Preview), WITHOUT printing any
// value. Input is a dotenv file the owner pulled outside the repository, e.g.
//   vercel env pull --environment=preview /secure/tmp/fj-preview.env     (owner, read-only for the project)
//   node scripts/check-env.mjs /secure/tmp/fj-preview.env --target preview
// Prints one PASS/FAIL line per rule with variable NAMES only; exit 1 on any FAIL. Delete the pulled file afterwards.
import {readFileSync} from 'node:fs';

const file = process.argv[2];
const target = process.argv[process.argv.indexOf('--target') + 1];
if (!file || !['production', 'preview'].includes(target))
  throw new Error('Usage: node scripts/check-env.mjs <env file> --target production|preview');

const env = {};
for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
  const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
  if (match) env[match[1]] = match[2].replace(/^"(.*)"$/s, '$1').replace(/^'(.*)'$/s, '$1');
}

const results = [];
const check = (ok, rule) => results.push({ok: !!ok, rule});
const SECRETS = [
  'REQUEST_HMAC_KEY',
  'TAROT_HMAC_KEY',
  'OPS_HMAC_KEY',
  'ATTRIBUTION_HMAC_KEY',
  'CRON_SECRET',
  'WEB_SESSION_HMAC_KEY',
];
const placeholder = (value) => !value || /REPLACE|YOUR[_-]|example|changeme|placeholder/i.test(value);

check(/^https:\/\/[a-z0-9.-]+$/.test(env.APP_ORIGIN ?? ''), 'APP_ORIGIN is an https origin without path');
check(
  /^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(env.NEXT_PUBLIC_SUPABASE_URL ?? ''),
  'NEXT_PUBLIC_SUPABASE_URL is a hosted project URL (https://<20-char ref>.supabase.co)',
);
check(
  /^sb_publishable_/.test(env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? ''),
  'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY is a publishable key (sb_publishable_…)',
);
check(/^sb_secret_/.test(env.SUPABASE_SECRET_KEY ?? ''), 'SUPABASE_SECRET_KEY is a secret key (sb_secret_…)');
for (const name of SECRETS)
  check(!placeholder(env[name]) && env[name].length >= 32, `${name} set, >= 32 chars, not a placeholder`);
const values = SECRETS.map((name) => env[name]).filter(Boolean);
check(new Set(values).size === values.length, 'independent secrets are all different');
check(!values.includes(env.SUPABASE_SECRET_KEY), 'no app secret reuses SUPABASE_SECRET_KEY');
check(/^v\d+$/.test(env.TAROT_KEY_VERSION ?? ''), 'TAROT_KEY_VERSION like v1');
let clientNames = null;
try {
  clientNames = JSON.parse(env.MCP_CLIENT_NAMES_JSON ?? '{}');
} catch {
  /* reported below */
}
check(
  clientNames &&
    typeof clientNames === 'object' &&
    !Array.isArray(clientNames) &&
    Object.values(clientNames).every((v) => v === 'chatgpt' || v === 'claude'),
  'MCP_CLIENT_NAMES_JSON is an object of client_id -> chatgpt|claude',
);
check(
  (env.MCP_ALLOWED_ORIGINS ?? '')
    .split(',')
    .filter(Boolean)
    .every((o) => /^https:\/\/[a-z0-9.-]+(:\d+)?$/.test(o.trim())),
  'MCP_ALLOWED_ORIGINS empty or exact https origins',
);
// First public phase: everything optional stays off (docs/OPERATIONS.md §3.4).
for (const flag of [
  'PRODUCT_ANALYTICS_ENABLED',
  'OPERATIONS_ENABLED',
  'THREADS_INSIGHTS_ENABLED',
  'THREADS_PUBLISH_ENABLED',
])
  check(
    (env[flag] ?? 'false') === 'false',
    `${flag} is false for the first deployment (change only with owner approval)`,
  );
check(!env.THREADS_ACCESS_TOKEN, 'THREADS_ACCESS_TOKEN empty until Meta permissions are verified');
check(
  (env.MCP_TIMING_LOG ?? 'false') === 'false' || target === 'preview',
  'MCP_TIMING_LOG off in production',
);
if (target === 'production')
  check(
    !/vercel\.app$/.test(env.APP_ORIGIN ?? ''),
    'production APP_ORIGIN is the custom domain, not *.vercel.app',
  );

for (const {ok, rule} of results) console.log(`${ok ? 'PASS' : 'FAIL'}  ${rule}`);
const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed / ${failed} failed (${target}; values not shown)`);
process.exitCode = failed ? 1 : 0;
