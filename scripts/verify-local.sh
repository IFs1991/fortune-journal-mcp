#!/usr/bin/env bash
# Everything that can be verified on this machine, in one command, without GitHub Actions or any remote service.
# Each step is PASS / FAIL / BLOCKED (exit 2 from a step = a missing prerequisite such as Docker or the Supabase CLI).
# Logs: verification/local/<step>.log, summary: verification/local/summary.json (command, exit code, times, commit).
#
#   bash scripts/verify-local.sh [--npm-ci]          # or: npm run verify:local
#
# Uses only loopback targets: a disposable postgres:17 container, this project's local Supabase CLI stack
# (project_id fortune-journal-local, network fj_local_net; started or reset here, never another project's) and the
# app on http://localhost:3000. Throwaway secrets are generated per run into a private temp file and never printed.
set -uo pipefail
export MSYS_NO_PATHCONV=1 NEXT_TELEMETRY_DISABLED=1
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
out="$root/verification/local"
mkdir -p "$out"
tmp="$(mktemp -d)"
app_pid=''
cleanup() {
  [[ -n "$app_pid" ]] && kill "$app_pid" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
dirty="$(git status --porcelain 2>/dev/null | grep -v '^?? verification/local/' | head -1)"
steps_json=()
failed=0
blocked=0

# run <name> <command...>: one step, its own log, a PASS/FAIL/BLOCKED line.
run() {
  local name="$1"
  shift
  local log="$out/$name.log" started ended code verdict
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    echo "# step: $name"
    echo "# command: $*"
    echo "# commit: $commit${dirty:+ (working tree has uncommitted changes)}"
    echo "# node: $(node -v)  started: $started"
  } >"$log"
  "$@" >>"$log" 2>&1
  code=$?
  ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$code" in
    0) verdict=PASS ;;
    2) verdict=BLOCKED; blocked=$((blocked + 1)) ;;
    *) verdict=FAIL; failed=$((failed + 1)) ;;
  esac
  printf '%-8s %-28s %s\n' "$verdict" "$name" "verification/local/$name.log"
  steps_json+=("{\"step\":\"$name\",\"result\":\"$verdict\",\"exitCode\":$code,\"startedAt\":\"$started\",\"endedAt\":\"$ended\",\"command\":$(printf '%s' "$*" | node -e 'process.stdin.on("data",d=>process.stdout.write(JSON.stringify(String(d))))')}")
}
blocked_step() {
  local name="$1" reason="$2"
  echo "BLOCKED: $reason" >"$out/$name.log"
  printf '%-8s %-28s %s\n' BLOCKED "$name" "$reason"
  blocked=$((blocked + 1))
  steps_json+=("{\"step\":\"$name\",\"result\":\"BLOCKED\",\"exitCode\":2,\"reason\":\"$reason\"}")
}

echo "Fortune Journal local verification — commit $commit, $(node -v), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
[[ "${1:-}" == --npm-ci ]] && run npm_ci npm ci --no-audit --no-fund
run format npm run format:check
run static npm run check:static
run unit npm test
run typecheck npm run typecheck
run audit npm audit --audit-level=high
run db_pg17 bash scripts/test-db.sh
run schema_drift bash scripts/db-schema.sh --check

# ----- Local Supabase stack (real Supabase Postgres image + GoTrue OAuth 2.1 + PostgREST) -----
supabase_ready=0
if ! command -v supabase >/dev/null; then
  blocked_step supabase_stack 'Supabase CLI unavailable'
elif ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
  blocked_step supabase_stack 'Docker daemon unavailable'
else
  status_json() { supabase status -o json </dev/null 2>/dev/null; }
  if ! status_json | grep -q '"API_URL"'; then
    run supabase_start supabase start --network-id fj_local_net
  fi
  if status_json | grep -q '"API_URL": *"http://127.0.0.1'; then
    supabase_ready=1
    # Applies the current baseline (this project's local stack only).
    run supabase_reset supabase db reset --local --network-id fj_local_net
    run supabase_sql bash scripts/test-supabase-local.sh
    run supabase_lint supabase db lint --local --fail-on warning
    run supabase_advisors supabase db advisors --local --type all --level warn --fail-on warn
    run ops_state_machines npm run test:ops:local
  else
    blocked_step supabase_stack 'local Supabase stack did not start or is not on loopback'
  fi
fi

# ----- App + E2E (analytics/ops OFF, then ON) -----
if [[ "$supabase_ready" == 1 ]]; then
  supabase status -o json </dev/null 2>/dev/null | node -e '
    const s = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const r = () => require("crypto").randomBytes(32).toString("hex");
    const env = {APP_ORIGIN: "http://localhost:3000", NEXT_PUBLIC_SUPABASE_URL: s.API_URL,
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: s.PUBLISHABLE_KEY, SUPABASE_SECRET_KEY: s.SECRET_KEY,
      REQUEST_HMAC_KEY: r(), TAROT_HMAC_KEY: r(), TAROT_KEY_VERSION: "v1", OPS_HMAC_KEY: r(),
      ATTRIBUTION_HMAC_KEY: r(), CRON_SECRET: r(), WEB_SESSION_HMAC_KEY: r(), MCP_CLIENT_NAMES_JSON: "{}"};
    process.stdout.write(Object.entries(env).map(([k, v]) => `${k}=${v}`).join("\n") + "\n");' >"$tmp/fj.env"
  chmod 600 "$tmp/fj.env"
  with_env() { (set -a && . "$tmp/fj.env" && set +a && "$@"); }
  run build with_env npm run build
  start_app() {
    (set -a && . "$tmp/fj.env" && set +a && export PRODUCT_ANALYTICS_ENABLED="$1" OPERATIONS_ENABLED="$1" &&
      exec node node_modules/next/dist/bin/next start -p 3000) >"$tmp/app-$1.log" 2>&1 &
    app_pid=$!
    for _ in $(seq 1 40); do curl -sf -o /dev/null http://localhost:3000/api/health && return 0; sleep 1; done
    return 1
  }
  stop_app() {
    kill "$app_pid" 2>/dev/null
    wait "$app_pid" 2>/dev/null
    app_pid=''
  }
  e2e() {
    (set -a && . "$tmp/fj.env" && set +a && export PRODUCT_ANALYTICS_ENABLED="$1" OPERATIONS_ENABLED="$1" &&
      node --experimental-strip-types scripts/e2e-local.mjs --out "$out/e2e_analytics_$2.json")
  }
  if curl -sf -o /dev/null http://localhost:3000/api/health; then
    blocked_step e2e 'port 3000 is already in use; stop the other app first'
  else
    for mode in false true; do
      label=$([[ "$mode" == true ]] && echo on || echo off)
      if start_app "$mode"; then
        run "e2e_analytics_$label" e2e "$mode" "$label"
      else
        blocked_step "e2e_analytics_$label" 'app did not become healthy on :3000'
      fi
      stop_app
      # 120 browser actions/min per address (src/lib/rate-limit.ts): the next mode starts a new instance anyway.
    done
  fi
else
  run build npm run build
  blocked_step e2e 'needs the local Supabase stack'
fi

{
  echo '{'
  echo "  \"commit\": \"$commit\","
  echo "  \"workingTreeClean\": $([[ -z "$dirty" ]] && echo true || echo false),"
  echo "  \"node\": \"$(node -v)\","
  echo "  \"ranAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"failed\": $failed, \"blocked\": $blocked,"
  echo '  "steps": ['
  printf '    %s' "${steps_json[0]}"
  for s in "${steps_json[@]:1}"; do printf ',\n    %s' "$s"; done
  printf '\n  ]\n}\n'
} >"$out/summary.json"
echo "Summary: $failed failed, $blocked blocked — verification/local/summary.json"
[[ "$failed" == 0 ]] || exit 1
[[ "$blocked" == 0 ]] || exit 2
