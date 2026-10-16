import {readFileSync, readdirSync, writeFileSync, existsSync, unlinkSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import path from 'node:path';
const root = process.cwd(),
  folder = path.join(root, 'supabase/migrations');
const manifest = JSON.parse(readFileSync(path.join(root, 'supabase/migration-manifest.json'), 'utf8'));
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
if (digest(readFileSync(path.join(folder, manifest.initial.file))) !== manifest.initial.sha256)
  throw new Error('Historical migration changed. Refusing to proceed.');
const check = process.argv.includes('--check'),
  cli = process.env.SUPABASE_CLI ?? 'supabase';
if (!check) {
  for (const args of [['--version'], ['migration', 'new', '--help']]) {
    const result = spawnSync(cli, args, {cwd: root, encoding: 'utf8'});
    if (result.status !== 0)
      throw new Error(
        'Supabase CLI unavailable. Install the official CLI, inspect --help, then rerun. No SQL has been applied.',
      );
  }
}
const mapping = [];
for (const item of manifest.templates) {
  const source = readFileSync(path.join(root, 'supabase/migration-templates', item.file));
  if (digest(source) !== item.sha256)
    throw new Error(`Template hash changed: ${item.file}; review before regenerating.`);
  let files = readdirSync(folder).filter((n) => n.endsWith(`_${item.slug}.sql`));
  if (files.length > 1) throw new Error('Duplicate generated migration');
  if (files.length === 0) {
    if (check) throw new Error(`Unprepared template ${item.file}. Run npm run db:prepare before db push.`);
    for (let attempt = 0; attempt < 3; attempt++) {
      const before = readdirSync(folder),
        last =
          before
            .filter((n) => /^\d{14}_/.test(n))
            .sort()
            .at(-1)
            ?.slice(0, 14) ?? '';
      const result = spawnSync(cli, ['migration', 'new', item.slug], {cwd: root, encoding: 'utf8'});
      if (result.status !== 0) throw new Error('Supabase migration new failed; inspect CLI output locally.');
      files = readdirSync(folder).filter((n) => !before.includes(n) && n.endsWith(`_${item.slug}.sql`));
      if (files.length !== 1) throw new Error('CLI did not create exactly one expected file.');
      if (files[0].slice(0, 14) > last) break;
      if (readFileSync(path.join(folder, files[0]), 'utf8').trim())
        throw new Error('Will not delete nonempty CLI output.');
      unlinkSync(path.join(folder, files[0]));
      files = [];
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1100);
    }
    if (files.length !== 1) throw new Error('Could not obtain a unique CLI timestamp; rerun later.');
    writeFileSync(path.join(folder, files[0]), source);
  } else if (digest(readFileSync(path.join(folder, files[0]))) !== item.sha256)
    throw new Error(`Existing migration differs: ${files[0]}. Never overwrite it; create a forward fix.`);
  mapping.push({template: item.file, migration: files[0], sha256: item.sha256});
}
// Forward fixes are CLI-generated migrations reviewed after the templates; they must never change once recorded.
for (const fix of manifest.forwardFixes ?? []) {
  const file = path.join(folder, fix.file);
  if (!existsSync(file)) throw new Error(`Forward fix missing: ${fix.file}`);
  if (digest(readFileSync(file)) !== fix.sha256)
    throw new Error(`Forward fix changed: ${fix.file}. Create a new migration instead.`);
}
const known = new Set([
  manifest.initial.file,
  ...mapping.map((m) => m.migration),
  ...(manifest.forwardFixes ?? []).map((f) => f.file),
]);
const unknown = readdirSync(folder).filter((n) => n.endsWith('.sql') && !known.has(n));
if (unknown.length) throw new Error(`Unreviewed migration(s) not in manifest: ${unknown.join(', ')}`);
const times = readdirSync(folder)
  .filter((n) => /^\d{14}_.*\.sql$/.test(n))
  .map((n) => n.slice(0, 14));
if (new Set(times).size !== times.length) throw new Error('Duplicate migration timestamp');
if (!check)
  writeFileSync(path.join(root, 'supabase/template-lock.json'), JSON.stringify(mapping, null, 2) + '\n');
console.log(
  `Prepared ${mapping.length} additive migrations via official CLI. No remote database was changed.`,
);
