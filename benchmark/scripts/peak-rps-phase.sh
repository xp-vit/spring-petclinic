#!/usr/bin/env bash
# Peak-RPS phase: runs a 5-min ramping-arrival-rate sweep against each variant
# to find the saturation point. Intended to run AFTER the main benchmark phase
# (run-local.sh / run-on-ec2.sh) on the same infrastructure.
#
# Local usage:
#   ./benchmark/scripts/peak-rps-phase.sh [variant]
#     variant = both (default) | jvm | native
#
# Remote (EC2) usage:
#   PEAK_RPS_REMOTE=1 ./benchmark/scripts/peak-rps-phase.sh both
#   (runs k6 directly via apt-installed k6 instead of docker)
#
# Env overrides:
#   START_RPS=100 END_RPS=2000 DURATION=5m
#   RESULTS_SUBDIR=local
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$BENCHMARK_DIR/results/${RESULTS_SUBDIR:-local}"

VARIANT="${1:-both}"
APP_PORT=8080
PG_NAME="petclinic-postgres"
START_RPS="${START_RPS:-100}"
END_RPS="${END_RPS:-2000}"
DURATION="${DURATION:-5m}"
MAX_VUS="${MAX_VUS:-500}"
APP_MEMORY="${APP_MEMORY:-512m}"
APP_CPUS="${APP_CPUS:-1}"
REMOTE="${PEAK_RPS_REMOTE:-0}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

ensure_postgres() {
  if ! docker inspect -f '{{.State.Running}}' "$PG_NAME" >/dev/null 2>&1; then
    log "Postgres not running; starting..."
    docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
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

# Resolve image tag. Local uses petclinic:<v>; on EC2 caller may pass ECR_URL.
image_for() {
  local v="$1"
  if [[ -n "${ECR_URL:-}" ]]; then
    echo "${ECR_URL}:${v}"
  else
    echo "petclinic:${v}"
  fi
}

run_variant() {
  local variant="$1"
  local image; image=$(image_for "$variant")
  local cname="petclinic-${variant}"

  log "=== Peak-RPS: $variant ==="
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "WARN: image $image not local; assuming docker pull will work"
  fi

  ensure_postgres

  docker rm -f "$cname" >/dev/null 2>&1 || true
  docker run -d --name "$cname" --network host \
    --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE=postgres \
    -e POSTGRES_URL=jdbc:postgresql://localhost:5432/petclinic \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    "$image" >/dev/null

  log "Waiting for $variant to become healthy..."
  for i in $(seq 1 180); do
    curl -sf "http://localhost:${APP_PORT}/actuator/health" >/dev/null 2>&1 && break
    sleep 1
  done

  log "Running peak-RPS sweep (${START_RPS} -> ${END_RPS} req/s over ${DURATION})..."
  if [[ "$REMOTE" == "1" ]]; then
    DURATION="$DURATION" START_RPS="$START_RPS" END_RPS="$END_RPS" MAX_VUS="$MAX_VUS" \
      k6 run \
      --out "csv=$RESULTS_DIR/${variant}-peak-rps.csv" \
      --summary-export "$RESULTS_DIR/${variant}-peak-rps-summary.json" \
      -e BASE_URL="http://localhost:${APP_PORT}" \
      -e START_RPS="$START_RPS" -e END_RPS="$END_RPS" \
      -e DURATION="$DURATION" -e MAX_VUS="$MAX_VUS" \
      "$BENCHMARK_DIR/k6/peak-rps.js" \
      2>&1 | tee "$RESULTS_DIR/${variant}-peak-rps-output.txt"
  else
    docker run --rm --network host \
      --user "$(id -u):$(id -g)" \
      -v "$BENCHMARK_DIR/k6:/scripts:ro" \
      -v "$RESULTS_DIR:/out" \
      -e BASE_URL="http://localhost:${APP_PORT}" \
      -e START_RPS="$START_RPS" -e END_RPS="$END_RPS" \
      -e DURATION="$DURATION" -e MAX_VUS="$MAX_VUS" \
      grafana/k6:latest run \
      --out "csv=/out/${variant}-peak-rps.csv" \
      --summary-export="/out/${variant}-peak-rps-summary.json" \
      /scripts/peak-rps.js \
      2>&1 | tee "$RESULTS_DIR/${variant}-peak-rps-output.txt"
  fi

  docker stop "$cname" >/dev/null 2>&1 || true
  docker rm "$cname" >/dev/null 2>&1 || true
}

mkdir -p "$RESULTS_DIR"

if [[ "$VARIANT" == "both" || "$VARIANT" == "jvm" ]]; then
  run_variant jvm
fi
if [[ "$VARIANT" == "both" || "$VARIANT" == "native" ]]; then
  sleep 5
  run_variant native
fi

log "Peak-RPS phase done. Results in $RESULTS_DIR/{jvm,native}-peak-rps*"
