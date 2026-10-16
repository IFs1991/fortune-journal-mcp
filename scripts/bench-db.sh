#!/usr/bin/env bash
# Disposable-PostgreSQL microbenchmark of the per-call DB work behind the MCP tools (local only, no URL accepted).
# Usage: bench-db.sh <repo> <status-sql> <out-file>
#   <status-sql> is the SELECT used for get_access_status in that version, with UID as the user placeholder,
#   e.g. "SELECT public.fj_access_status(UID)". <repo> may be an exported older tree (git archive) to compare.
set -euo pipefail
export MSYS_NO_PATHCONV=1
repo="$1"; status_sql="$2"; out="$3"
image="postgres@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3"
c="fj-bench-db-$$"
cleanup(){ docker rm -f "$c" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$c" -e POSTGRES_PASSWORD=bench "$image" -c shared_buffers=128MB >/dev/null
docker exec "$c" mkdir -p /repo/supabase
docker cp "$repo/supabase/migrations" "$c:/repo/supabase/migrations" >/dev/null
docker cp "$repo/supabase/tests" "$c:/repo/supabase/tests" >/dev/null
for _ in $(seq 1 40); do docker exec "$c" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 2
sql(){ docker exec -i "$c" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
sql -f /repo/supabase/tests/support/local_auth_stub.sql
for f in $(docker exec "$c" sh -c 'ls /repo/supabase/migrations/*.sql | sort'); do sql -f "$f"; done
sql <<'SQL'
INSERT INTO auth.users(id) SELECT ('00000000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid FROM generate_series(1,100) g;
INSERT INTO public.subscriptions(user_id,provider,provider_customer_id,provider_subscription_id,status,current_period_end,verified_at)
 SELECT ('00000000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'bench','c'||g,'s'||g,'active',now()+interval '30 days',now() FROM generate_series(1,100) g;
-- Users 51..100 are "heavy": 150 readings already today (near the 200/day Premium limit).
DO $$ DECLARE u int; i int; BEGIN
 FOR u IN 51..100 LOOP FOR i IN 1..150 LOOP
  PERFORM public.fj_record_calculation(('00000000-0000-4000-8000-'||lpad(u::text,12,'0'))::uuid,gen_random_uuid(),repeat('a',64),'calculate_numerology','v1',current_date);
 END LOOP; END LOOP;
 -- One fixed request per light user for the replay scenario.
 FOR u IN 1..50 LOOP
  PERFORM public.fj_record_calculation(('00000000-0000-4000-8000-'||lpad(u::text,12,'0'))::uuid,('11111111-0000-4000-8000-'||lpad(u::text,12,'0'))::uuid,repeat('b',64),'draw_tarot','v1',current_date);
 END LOOP;
END $$;
VACUUM ANALYZE;
SQL
uid="('00000000-0000-4000-8000-'||lpad(:u::text,12,'0'))::uuid"
declare -A scripts=(
 [fresh_light]="\\set u random(1, 50)
SELECT public.fj_record_calculation($uid, gen_random_uuid(), repeat('a',64), 'calculate_numerology', 'v1', current_date);"
 [fresh_heavy]="\\set u random(51, 100)
SELECT public.fj_record_calculation($uid, gen_random_uuid(), repeat('a',64), 'calculate_numerology', 'v1', current_date);"
 [replay]="\\set u random(1, 50)
SELECT public.fj_record_calculation($uid, ('11111111-0000-4000-8000-'||lpad(:u::text,12,'0'))::uuid, repeat('b',64), 'draw_tarot', 'v1', current_date);"
 [access_status]="\\set u random(1, 100)
${status_sql//UID/$uid};"
)
: > "$out"
for name in access_status replay fresh_light fresh_heavy; do
 n=2000; [[ $name == fresh_heavy ]] && n=1000   # heavy users have 50 x 50 = 2500 units of headroom
 printf '%s\n' "${scripts[$name]}" | docker exec -i "$c" sh -c "cat > /tmp/$name.sql"
 docker exec "$c" sh -c "cd /tmp && rm -f pgbench_log.* && pgbench -U postgres -n -c 1 -t $n -f /tmp/$name.sql -l postgres >/dev/null 2>&1 && cat pgbench_log.*" \
  | awk '{print $3}' | sort -n | awk -v name="$name" '{a[NR]=$1; s+=$1} END {p50=a[int(NR*0.5+0.999)]; p95=a[int(NR*0.95+0.999)]; printf "%s n=%d p50_ms=%.3f p95_ms=%.3f mean_ms=%.3f\n", name, NR, p50/1000, p95/1000, s/NR/1000}' | tee -a "$out"
done
sql -c "SELECT count(*) AS readings FROM public.user_readings" -At | sed 's/^/readings=/' | tee -a "$out"
