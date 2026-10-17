#!/usr/bin/env bash
# Run every SQL suite against the LOCAL Supabase CLI stack (real Supabase Postgres image, roles, default
# privileges and auth schema). Each suite rolls back. Refuses any non-loopback database.
set -euo pipefail
export MSYS_NO_PATHCONV=1
command -v supabase >/dev/null || { echo 'BLOCKED: Supabase CLI unavailable.' >&2; exit 2; }
command -v psql >/dev/null || { echo 'BLOCKED: psql unavailable.' >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"
db_url="$(cd "$root" && supabase status -o json </dev/null 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",(d)=>(s+=d)).on("end",()=>{try{console.log(JSON.parse(s).DB_URL??"")}catch{console.log("")}})')"
case "$db_url" in
  postgresql://*@127.0.0.1:* | postgresql://*@localhost:*) ;;
  *) echo 'BLOCKED: local Supabase stack is not running (supabase start), or DB is not loopback. Refusing.' >&2; exit 2 ;;
esac
for file in "$root"/supabase/tests/*.sql; do
  name="$(basename "$file" .sql)"
  if ! psql "$db_url" -v ON_ERROR_STOP=1 -q -f "$file" >/dev/null 2>"${TMPDIR:-/tmp}/fj-$name.err"; then
    echo "FAIL: $name" >&2
    grep -E 'ERROR|CONTEXT' "${TMPDIR:-/tmp}/fj-$name.err" >&2 || true
    exit 1
  fi
  echo "PASS: $name (local Supabase stack)"
done
