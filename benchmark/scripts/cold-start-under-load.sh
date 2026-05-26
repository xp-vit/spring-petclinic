#!/usr/bin/env bash
# Cold-start-under-load: a light probe (10 req/s) hits the app port while we
# start the container; we record ms from container start to first 200.
#
# Usage: ./benchmark/scripts/cold-start-under-load.sh [variant]
#   variant = both (default) | jvm | native
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$BENCHMARK_DIR/results/${RESULTS_SUBDIR:-local}"

VARIANT="${1:-both}"
APP_PORT=8080
PG_NAME="petclinic-postgres"
PROBE_INTERVAL_S="0.1"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

ensure_postgres() {
  if ! docker inspect -f '{{.State.Running}}' "$PG_NAME" 2>/dev/null | grep -q true; then
    log "Postgres not running; starting..."
    docker rm -f "$PG_NAME" 2>/dev/null || true
    docker run -d --name "$PG_NAME" --network host \
      -e POSTGRES_DB=petclinic -e POSTGRES_USER=petclinic -e POSTGRES_PASSWORD=petclinic \
      postgres:18.3 >/dev/null
    for i in $(seq 1 30); do
      if docker exec "$PG_NAME" pg_isready -U petclinic >/dev/null 2>&1; then
        log "Postgres ready (${i}s)"; break
      fi
      sleep 1
    done
  fi
  docker exec "$PG_NAME" psql -U petclinic -c \
    "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 || true
}

run_variant() {
  local variant="$1"
  local image="petclinic:${variant}"
  local cname="petclinic-${variant}-cold"
  local probe_log="$RESULTS_DIR/${variant}-cold-probe.log"

  log "=== Cold-start-under-load: $variant ==="
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "ERROR: image $image not found"
    return 3
  fi

  ensure_postgres
  docker rm -f "$cname" >/dev/null 2>&1 || true

  : > "$probe_log"
  # Probe: redirect *all* fds to log file / /dev/null so we don't hold the
  # parent's stdout (which would block a piped invocation from exiting).
  nohup bash -c '
    while true; do
      ts=$(date +%s.%3N)
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
        "http://localhost:'"${APP_PORT}"'/actuator/health" 2>/dev/null)
      [[ -z "$code" ]] && code="000"
      echo "$ts $code" >> "'"$probe_log"'"
      sleep '"$PROBE_INTERVAL_S"'
    done
  ' </dev/null >/dev/null 2>&1 &
  local probe_pid=$!
  disown "$probe_pid" 2>/dev/null || true

  cleanup() {
    kill "$probe_pid" 2>/dev/null || true
    docker rm -f "$cname" >/dev/null 2>&1 || true
  }
  trap cleanup RETURN

  sleep 2  # let probe log some baseline failures

  local start_ts; start_ts=$(date +%s.%3N)
  if ! docker run -d --name "$cname" --network host \
      --memory 512m --cpus 1 \
      -e SPRING_PROFILES_ACTIVE=postgres \
      -e POSTGRES_URL=jdbc:postgresql://localhost:5432/petclinic \
      -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
      "$image" >/dev/null; then
    log "ERROR: docker run failed for $variant"
    return 4
  fi

  local first_200_ts="" elapsed_ms
  for _ in $(seq 1 900); do  # 900 * 0.2s = 180s
    first_200_ts=$(awk -v st="$start_ts" '$1>=st && $2=="200" {print $1; exit}' "$probe_log" 2>/dev/null || true)
    [[ -n "$first_200_ts" ]] && break
    sleep 0.2
  done

  if [[ -n "$first_200_ts" ]]; then
    elapsed_ms=$(awk "BEGIN{printf \"%d\", ($first_200_ts - $start_ts) * 1000}")
    echo "$elapsed_ms" > "$RESULTS_DIR/${variant}-cold-start-ms.txt"
    log "$variant cold-start-under-load: ${elapsed_ms}ms"
  else
    echo "TIMEOUT" > "$RESULTS_DIR/${variant}-cold-start-ms.txt"
    log "$variant: no 200 within 180s"
  fi
}

mkdir -p "$RESULTS_DIR"

case "$VARIANT" in
  both) variants="jvm native";;
  all)  variants="jvm native native-pgo";;
  *)    variants="$VARIANT";;
esac

first=1
for v in $variants; do
  [[ $first -eq 0 ]] && sleep 3
  run_variant "$v"
  first=0
done

log "Done. Cold-start results in $RESULTS_DIR/*-cold-start-ms.txt"
