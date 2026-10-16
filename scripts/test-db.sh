#!/usr/bin/env bash
# Disposable PostgreSQL 17 (digest-pinned) + a minimal Auth stub: apply every migration, run every SQL suite,
# check concurrency with real parallel sessions, then dump/restore and re-run the catalog contract.
# Accepts no database URL: it can only create and destroy its own container.
set -euo pipefail
command -v docker >/dev/null || { echo 'BLOCKED: Docker unavailable; SQL tests were not run.' >&2; exit 2; }
# Git Bash on Windows rewrites /repo-style arguments into host paths; container paths must stay literal.
export MSYS_NO_PATHCONV=1
# `pwd -W` yields C:/... on Git Bash so docker.exe resolves host paths; plain pwd elsewhere.
root="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"
container="fj-db-test-$$"
out="$(mktemp -d)"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$out"; }
trap cleanup EXIT

# Reviewed digest of postgres:17 (2026-10-15). Update deliberately, never float.
image="${FJ_TEST_PG_IMAGE:-postgres@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3}"
docker run -d --name "$container" -e POSTGRES_PASSWORD=local_test_only "$image" >/dev/null
# Copy instead of bind-mounting: host path translation differs between Linux CI and Docker Desktop.
docker exec "$container" mkdir -p /repo/supabase
docker cp "$root/supabase/migrations" "$container:/repo/supabase/migrations" >/dev/null
docker cp "$root/supabase/tests" "$container:/repo/supabase/tests" >/dev/null
ready=0
for _ in $(seq 1 40); do
  if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || { echo 'Test database did not start' >&2; exit 1; }

db=fj_test
docker exec "$container" createdb -U postgres "$db"
sql() { docker exec -i "$container" psql -U postgres -d "$db" -v ON_ERROR_STOP=1 -q "$@"; }
sql -f /repo/supabase/tests/support/local_auth_stub.sql
for file in "$root"/supabase/migrations/*.sql; do sql -f "/repo/supabase/migrations/$(basename "$file")"; done
for file in "$root"/supabase/tests/*.sql; do
  sql -f "/repo/supabase/tests/$(basename "$file")"
  echo "PASS: $(basename "$file" .sql)"
done

# ===== Concurrency (real parallel sessions) =====
sql <<'SQL'
INSERT INTO auth.users (id) VALUES ('33333333-3333-4333-8333-333333333333'), ('44444444-4444-4444-8444-444444444444'),
  ('55555555-5555-4555-8555-555555555555');
INSERT INTO public.user_access (user_id, trial_started_at, trial_ends_at)
VALUES ('33333333-3333-4333-8333-333333333333', now() - interval '20 days', now() - interval '6 days');
SQL
call() { sql -At -c "SET ROLE service_role; SELECT public.fj_record_calculation($1);" >"$2" & pids+=("$!"); }
pids=()
# 10 different requests from a Free user: exactly 3 succeed, 7 hit the weekly limit.
for n in $(seq 1 10); do
  call "'33333333-3333-4333-8333-333333333333','$(printf '00000000-0000-4000-8000-%012d' "$n")',repeat('c',64),'calculate_numerology','test-v1',current_date" "$out/diff-$n"
done
# 10 identical retries: one fresh reading, nine replays of it.
for n in $(seq 1 10); do
  call "'44444444-4444-4444-8444-444444444444','dddddddd-dddd-4ddd-8ddd-dddddddddddd',repeat('d',64),'calculate_numerology','test-v1',current_date" "$out/same-$n"
done
# 10 identical tarot retries sent with two different request dates: still one reading.
for n in $(seq 1 10); do
  call "'55555555-5555-4555-8555-555555555555','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',repeat('e',64),'draw_tarot','test-v1',current_date+$((n % 2))" "$out/tarot-$n"
done
for pid in "${pids[@]}"; do wait "$pid"; done
count() { cat "$out"/$1-* | grep -c "$2" || true; }
ids() { cat "$out"/$1-* | grep -o '"readingId": "[^"]*"' | sort -u | wc -l; }
[[ "$(count diff '"ok": true')" == 3 && "$(count diff USAGE_LIMIT_REACHED)" == 7 ]] \
  || { echo "concurrent distinct requests: $(count diff '"ok": true') ok" >&2; exit 1; }
[[ "$(count same '"replayed": false')" == 1 && "$(count same '"replayed": true')" == 9 && "$(ids same)" -eq 1 ]] \
  || { echo 'concurrent identical retries diverged' >&2; exit 1; }
[[ "$(count tarot '"replayed": false')" == 1 && "$(count tarot '"replayed": true')" == 9 && "$(ids tarot)" -eq 1 ]] \
  || { echo 'concurrent tarot retries diverged' >&2; exit 1; }
sql <<'SQL'
DO $$ BEGIN
  IF (SELECT count(*) FROM public.user_readings WHERE user_id = '33333333-3333-4333-8333-333333333333') <> 3 THEN RAISE EXCEPTION 'free limit exceeded'; END IF;
  IF (SELECT count(*) FROM public.user_readings WHERE user_id = '44444444-4444-4444-8444-444444444444') <> 1 THEN RAISE EXCEPTION 'retry consumed twice'; END IF;
  IF (SELECT count(*) FROM public.user_readings WHERE user_id = '55555555-5555-4555-8555-555555555555') <> 1 THEN RAISE EXCEPTION 'tarot retry consumed twice'; END IF;
END $$;
SQL
echo 'PASS: concurrency (10 distinct -> 3 + 7 limited, 10 identical -> 1 + 9 replays, cross-date tarot -> 1 reading)'

# ===== Dump / restore: the populated schema restores and keeps its contract =====
docker exec "$container" pg_dump -U postgres -Fc -d "$db" -f /tmp/fj.dump
docker exec "$container" createdb -U postgres fj_restored
docker exec "$container" pg_restore -U postgres -d fj_restored --exit-on-error /tmp/fj.dump
restored() { docker exec -i "$container" psql -U postgres -d fj_restored -v ON_ERROR_STOP=1 -q -At "$@"; }
restored -f /repo/supabase/tests/catalog.sql
[[ "$(restored -c 'SELECT count(*) FROM public.user_readings')" == "$(sql -At -c 'SELECT count(*) FROM public.user_readings')" ]] \
  || { echo 'restored row count differs' >&2; exit 1; }
echo 'PASS: pg_dump/pg_restore round trip (catalog contract and rows preserved)'
