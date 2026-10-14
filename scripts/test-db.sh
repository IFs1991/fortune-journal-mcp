#!/usr/bin/env bash
set -euo pipefail
# No remote URL accepted. Tests can ONLY create and destroy their own disposable container.
command -v docker >/dev/null || { echo 'BLOCKED: Docker/PostgreSQL runtime unavailable; SQL/RLS tests were not run.' >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && pwd)"
container="fj-db-test-$$"
cleanup(){ docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Pin a reviewed image digest in CI before release. Major 17 keeps this draft usable across patches.
docker run -d --name "$container" -e POSTGRES_PASSWORD=local_test_only --mount "type=bind,src=$root,dst=/repo,readonly" postgres:17 >/dev/null
ready=0
for _ in $(seq 1 40); do if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then ready=1;break;fi;sleep 1;done
[[ "$ready" == 1 ]] || { echo 'Test database did not start' >&2;exit 1; }
for mode in fresh upgrade; do
 db="fj_$mode"
 docker exec "$container" createdb -U postgres "$db"
 sql(){ docker exec -i "$container" psql -U postgres -d "$db" -v ON_ERROR_STOP=1 "$@"; }
 sql -f /repo/supabase/tests/local_auth_stub.sql
 sql -f /repo/supabase/migrations/20261014000100_initial_schema.sql
 if [[ "$mode" == upgrade ]];then sql -f /repo/supabase/tests/v01_upgrade_seed.sql;fi
 for file in "$root"/supabase/migration-templates/*.sql;do sql -f "/repo/supabase/migration-templates/$(basename "$file")";done
 for test in rls_security v02_security v02_transactions v02_billing v02_retention_kpis;do sql -f "/repo/supabase/tests/$test.sql";done
 # Concurrent different requests cannot exceed the Free weekly quota of three.
 sql <<'SQL'
INSERT INTO auth.users(id) VALUES('33333333-3333-4333-8333-333333333333'),('44444444-4444-4444-8444-444444444444');
INSERT INTO public.user_access(user_id,trial_started_at,trial_ends_at) VALUES('33333333-3333-4333-8333-333333333333',now()-interval '20 days',now()-interval '6 days');
SQL
 pids=()
 for n in $(seq 1 10);do
  req="$(printf '00000000-0000-4000-8000-%012d' "$n")"
  sql -c "SET ROLE service_role; SELECT public.fj_record_calculation('33333333-3333-4333-8333-333333333333','$req',repeat('c',64),'calculate_numerology','test-v1',current_date);" >/dev/null & pids+=("$!")
 done
 for pid in "${pids[@]}";do wait "$pid";done
 # Concurrent identical retries must consume only one unit.
 pids=()
 for _ in $(seq 1 10);do
  sql -c "SET ROLE service_role; SELECT public.fj_record_calculation('44444444-4444-4444-8444-444444444444','dddddddd-dddd-4ddd-8ddd-dddddddddddd',repeat('d',64),'calculate_numerology','test-v1',current_date);" >/dev/null & pids+=("$!")
 done
 for pid in "${pids[@]}";do wait "$pid";done
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
