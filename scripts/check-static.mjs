// Repository contracts that need no database or network. This does NOT execute SQL, typecheck or build.
import {createHash} from 'node:crypto';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const read = (file) => readFileSync(path.join(root, file), 'utf8');
const sha256 = (file) =>
  createHash('sha256')
    .update(readFileSync(path.join(root, file)))
    .digest('hex');
const failures = [];
const check = (ok, message) => {
  if (!ok) failures.push(message);
};

// ----- Packaging -----
const pkg = JSON.parse(read('package.json'));
const plugin = JSON.parse(read('.codex-plugin/plugin.json'));
check(plugin.version === pkg.version, 'package.json and .codex-plugin/plugin.json versions differ');
check(plugin.skills === './skills/', 'customer plugin must only ship ./skills/');
check(!JSON.stringify(plugin).includes('fortune-ops'), 'operator skill leaked into the customer plugin');
check(!existsSync(path.join(root, '.env.local')), 'do not keep .env.local in the project root');
const envExample = read('.env.example');
for (const flag of [
  'PRODUCT_ANALYTICS_ENABLED',
  'OPERATIONS_ENABLED',
  'THREADS_INSIGHTS_ENABLED',
  'THREADS_PUBLISH_ENABLED',
]) {
  check(envExample.includes(`${flag}=false`), `.env.example must default ${flag}=false`);
}

// ----- Migrations -----
const migrationDir = 'supabase/migrations';
const migrations = readdirSync(path.join(root, migrationDir))
  .filter((name) => name.endsWith('.sql'))
  .sort();
check(migrations.length > 0, 'no migrations found');
for (const name of migrations) {
  check(
    /^\d{14}_[a-z0-9_]+\.sql$/.test(name),
    `migration name must be <14-digit timestamp>_<slug>.sql: ${name}`,
  );
  const sql = read(`${migrationDir}/${name}`);
  check(
    /^BEGIN;$/m.test(sql) && sql.trim().endsWith('COMMIT;'),
    `migration must be one transaction: ${name}`,
  );
  check(
    !/security\s+definer/i.test(sql.replace(/--.*$/gm, '')),
    `SECURITY DEFINER needs a dedicated review: ${name}`,
  );
  check(
    !/\b(birth_date|birth_time|birth_place|journal_text|prompt_text|question_text|google_access_token|sheet_id)\s+(text|jsonb|date|timestamp)/i.test(
      sql,
    ),
    `forbidden personal-data column in ${name}`,
  );
}
const timestamps = migrations.map((name) => name.slice(0, 14));
check(new Set(timestamps).size === timestamps.length, 'duplicate migration timestamp');

const {applied} = JSON.parse(read('supabase/applied-migrations.json'));
for (const [name, hash] of Object.entries(applied)) {
  const file = `${migrationDir}/${name}`;
  check(existsSync(path.join(root, file)), `remotely applied migration is missing: ${name}`);
  if (existsSync(path.join(root, file)))
    check(sha256(file) === hash, `remotely applied migration was edited: ${name}`);
}
const newestApplied = Object.keys(applied).sort().at(-1);
if (newestApplied) {
  for (const name of migrations) {
    check(name in applied || name > newestApplied, `new migration sorts before applied history: ${name}`);
  }
}

// ----- Boundaries between the customer MCP and the operator API -----
const sourceFiles = (dir) =>
  readdirSync(path.join(root, dir), {withFileTypes: true, recursive: true})
    .filter((entry) => entry.isFile() && /\.tsx?$/.test(entry.name))
    .map((entry) => path.relative(root, path.join(entry.parentPath, entry.name)).replaceAll('\\', '/'));
const mcpSources = ['app/api/mcp/route.ts', ...sourceFiles('src/mcp')];
for (const file of mcpSources) {
  const text = read(file);
  check(
    // Imports, not comments: the MCP must not import operator modules or the Threads client.
    !/from\s+['"][^'"]*(src\/ops\/|integrations\/threads)|OPS_HMAC_KEY/.test(text),
    `operator code reachable from the MCP: ${file}`,
  );
}
const toolNames = [...read('src/mcp/tools.ts').matchAll(/^\s+name: '([a-z_]+)',$/gm)].map(
  (match) => match[1],
);
check(toolNames.length === 7, `expected 7 customer MCP tools, found ${toolNames.length}`);
check(
  toolNames.every((name) => !/publish|ops|sql|billing|grant/.test(name)),
  'operator-like tool name in the customer MCP',
);
check(
  /explicitUserRequest:\s*z\.literal\(true\)/.test(read('src/mcp/schemas.ts')),
  'optional analytics tools must require explicitUserRequest',
);
const opsRoute = read('app/api/ops/route.ts');
check(opsRoute.includes('verifyOps('), 'ops route must verify the HMAC signature');
check(/\.strict\(\)/.test(read('src/ops/commands.ts')), 'ops commands must be strict schemas');

// ----- Billing stays fail-closed until a real signed adapter exists -----
const webhook = read('app/api/billing/webhook/route.ts');
check(
  webhook.includes('501') && !webhook.includes('.rpc('),
  'billing webhook must stay 501 with no DB writes',
);
// Paid checkout stays off until a provider adapter is approved: no other billing route may exist.
check(
  readdirSync(path.join(root, 'app/api/billing')).join() === 'webhook',
  'no billing route besides the 501 webhook (checkout is disabled until a provider is approved)',
);
check(
  JSON.parse(read('.mcp.json')).mcpServers?.['fortune-journal']?.type === 'http',
  '.mcp.json must declare the remote server with type "http"',
);
check(envExample.includes('WEB_SESSION_HMAC_KEY='), '.env.example must list WEB_SESSION_HMAC_KEY');

if (failures.length) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exit(1);
}
console.log(
  `PASS: static contracts (${migrations.length} migration(s), ${Object.keys(applied).length} applied remotely, ${toolNames.length} MCP tools).`,
);
