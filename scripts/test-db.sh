#!/usr/bin/env bash
set -euo pipefail
# No remote URL accepted. Tests can ONLY create and destroy their own disposable container.
command -v docker >/dev/null || { echo 'BLOCKED: Docker/PostgreSQL runtime unavailable; SQL/RLS tests were not run.' >&2; exit 2; }
# Git Bash on Windows rewrites /repo-style arguments into host paths; container paths must stay literal.
export MSYS_NO_PATHCONV=1
# `pwd -W` yields C:/... on Git Bash so docker.exe resolves host paths; plain pwd elsewhere.
root="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"
container="fj-db-test-$$"
out="$(mktemp -d)"
cleanup(){ docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$out"; }
trap cleanup EXIT
# Reviewed digest of postgres:17 (2026-10-15). Update deliberately, never float.
image="${FJ_TEST_PG_IMAGE:-postgres@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3}"
docker run -d --name "$container" -e POSTGRES_PASSWORD=local_test_only "$image" >/dev/null
# Copy instead of bind-mounting: host path translation differs between Linux CI and Docker Desktop.
docker exec "$container" mkdir -p /repo/supabase
docker cp "$root/supabase/migrations" "$container:/repo/supabase/migrations" >/dev/null
docker cp "$root/supabase/tests" "$container:/repo/supabase/tests" >/dev/null
ready=0
for _ in $(seq 1 40); do if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then ready=1;break;fi;sleep 1;done
[[ "$ready" == 1 ]] || { echo 'Test database did not start' >&2;exit 1; }
for mode in fresh upgrade; do
 db="fj_$mode"
 docker exec "$container" createdb -U postgres "$db"
 sql(){ docker exec -i "$container" psql -U postgres -d "$db" -v ON_ERROR_STOP=1 "$@"; }
 sql -f /repo/supabase/tests/local_auth_stub.sql
 migrations=()
 for file in "$root"/supabase/migrations/[0-9]*_*.sql;do migrations+=("$(basename "$file")");done
 [[ "${#migrations[@]}" -ge 6 ]] || { echo 'BLOCKED: run npm run db:prepare first; only the historical migration exists.' >&2; exit 2; }
 sql -f "/repo/supabase/migrations/${migrations[0]}"
 if [[ "$mode" == upgrade ]];then sql -f /repo/supabase/tests/v01_upgrade_seed.sql;fi
 for file in "${migrations[@]:1}";do sql -f "/repo/supabase/migrations/$file";done
 for test in rls_security v02_security v02_transactions v02_billing v02_retention_kpis v02_negative_edge v02_forward_fix_06;do sql -f "/repo/supabase/tests/$test.sql";done
 # Concurrent different requests cannot exceed the Free weekly quota of three.
 sql <<'SQL'
INSERT INTO auth.users(id) VALUES('33333333-3333-4333-8333-333333333333'),('44444444-4444-4444-8444-444444444444');
INSERT INTO public.user_access(user_id,trial_started_at,trial_ends_at) VALUES('33333333-3333-4333-8333-333333333333',now()-interval '20 days',now()-interval '6 days');
SQL
 pids=()
 for n in $(seq 1 10);do
  req="$(printf '00000000-0000-4000-8000-%012d' "$n")"
  sql -qAt -c "SET ROLE service_role; SELECT public.fj_record_calculation('33333333-3333-4333-8333-333333333333','$req',repeat('c',64),'calculate_numerology','test-v1',current_date);" >"$out/diff-$n" & pids+=("$!")
 done
 for pid in "${pids[@]}";do wait "$pid";done
 # Concurrent identical retries must consume only one unit.
 pids=()
 for n in $(seq 1 10);do
  sql -qAt -c "SET ROLE service_role; SELECT public.fj_record_calculation('44444444-4444-4444-8444-444444444444','dddddddd-dddd-4ddd-8ddd-dddddddddddd',repeat('d',64),'calculate_numerology','test-v1',current_date);" >"$out/same-$n" & pids+=("$!")
 done
 for pid in "${pids[@]}";do wait "$pid";done
 # Every caller gets a definite answer: exactly 3 OK + 7 limit for distinct requests,
 # 1 fresh + 9 replays of the same reading for identical retries.
 ok=$(cat "$out"/diff-* | grep -c '"ok": true' || true); limited=$(cat "$out"/diff-* | grep -c 'USAGE_LIMIT_REACHED' || true)
 fresh=$(cat "$out"/same-* | grep -c '"replayed": false' || true); replays=$(cat "$out"/same-* | grep -c '"replayed": true' || true)
 ids=$(cat "$out"/same-* | grep -o '"readingId": "[^"]*"' | sort -u | wc -l)
 [[ "$ok" == 3 && "$limited" == 7 ]] || { echo "concurrent distinct requests: ok=$ok limited=$limited" >&2; exit 1; }
 [[ "$fresh" == 1 && "$replays" == 9 && "$ids" -eq 1 ]] || { echo "concurrent retries: fresh=$fresh replays=$replays ids=$ids" >&2; exit 1; }
 rm -f "$out"/diff-* "$out"/same-*
 sql <<'SQL'
DO $$ BEGIN
 IF (SELECT sum(used_count) FROM public.usage_counters WHERE user_id='33333333-3333-4333-8333-333333333333')<>3 THEN RAISE EXCEPTION 'concurrent quota failed';END IF;
 IF (SELECT count(*) FROM public.user_readings WHERE user_id='33333333-3333-4333-8333-333333333333')<>3 THEN RAISE EXCEPTION 'ledger count wrong';END IF;
 IF (SELECT sum(used_count) FROM public.usage_counters WHERE user_id='44444444-4444-4444-8444-444444444444')<>1 THEN RAISE EXCEPTION 'concurrent idempotency failed';END IF;
END; $$;
SQL
 if [[ "$mode" == upgrade ]];then
 sql <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.billing_events WHERE provider='legacy' AND event_id='event_legacy') THEN RAISE EXCEPTION 'legacy data lost';END IF;
 IF EXISTS(SELECT 1 FROM public.subscriptions WHERE provider='legacy' AND verified_at IS NOT NULL) THEN RAISE EXCEPTION 'fabricated billing verification';END IF;
END; $$;
SQL
 fi
 echo "PASS: $mode PostgreSQL migration/RLS/transaction/concurrency tests (Auth stub only)"
done
