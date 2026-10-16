#!/usr/bin/env bash
# Builds a disposable PostgreSQL 17 database from supabase/migrations/ only and writes the generated views of
# the resulting schema:
#   supabase/schema.sql            pg_dump --schema-only of public (DDL + grants)
#   docs/generated/DB_CATALOG.md   tables / views / RPCs / triggers / indexes / FKs from the system catalogs
# --check regenerates into a temp dir and fails if the committed files differ (used by CI).
set -euo pipefail
command -v docker >/dev/null || { echo 'BLOCKED: Docker unavailable; schema snapshot not generated.' >&2; exit 2; }
export MSYS_NO_PATHCONV=1
root="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"
mode="${1:-write}"
container="fj-db-schema-$$"
tmp="$(mktemp -d)"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

image="${FJ_TEST_PG_IMAGE:-postgres@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3}"
docker run -d --name "$container" -e POSTGRES_PASSWORD=local_test_only "$image" >/dev/null
docker exec "$container" mkdir -p /repo/supabase /repo/scripts
docker cp "$root/supabase/migrations" "$container:/repo/supabase/migrations" >/dev/null
docker cp "$root/supabase/tests" "$container:/repo/supabase/tests" >/dev/null
docker cp "$root/scripts/db-catalog.sql" "$container:/repo/scripts/db-catalog.sql" >/dev/null
for _ in $(seq 1 40); do docker exec "$container" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 1
psql_() { docker exec -i "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
psql_ -f /repo/supabase/tests/support/local_auth_stub.sql
for file in "$root"/supabase/migrations/*.sql; do psql_ -f "/repo/supabase/migrations/$(basename "$file")"; done

# Strip pg_dump lines that change between runs or client versions (version banner, \restrict tokens).
docker exec "$container" pg_dump -U postgres -d postgres --schema-only --schema=public --no-owner \
  | grep -v -E '^-- Dumped (from|by)|^\\(un)?restrict ' | tr -d '\r' >"$tmp/schema.sql"
psql_ -f /repo/scripts/db-catalog.sql | tr -d '\r' >"$tmp/DB_CATALOG.md"

if [[ "$mode" == --check ]]; then
  status=0
  diff -u "$root/supabase/schema.sql" "$tmp/schema.sql" >&2 || status=1
  diff -u "$root/docs/generated/DB_CATALOG.md" "$tmp/DB_CATALOG.md" >&2 || status=1
  if [[ "$status" != 0 ]]; then
    echo 'FAIL: supabase/schema.sql or docs/generated/DB_CATALOG.md is stale. Run npm run db:schema and commit.' >&2
    exit 1
  fi
  echo 'PASS: committed schema snapshot and catalog match the migrations.'
else
  mkdir -p "$root/docs/generated"
  cp "$tmp/schema.sql" "$root/supabase/schema.sql"
  cp "$tmp/DB_CATALOG.md" "$root/docs/generated/DB_CATALOG.md"
  echo 'Wrote supabase/schema.sql and docs/generated/DB_CATALOG.md'
fi
