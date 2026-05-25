#!/usr/bin/env bash
# Finish-on-ec2: runs cold-start-under-load (for both variants) and peak-RPS
# phase on an EC2 instance whose main JVM+native runs already completed.
# Then uploads results to S3.
#
# Args: ECR_URL AWS_REGION S3_BUCKET
set -euo pipefail

ECR_URL="${1:?ECR_URL required}"
AWS_REGION="${2:?AWS_REGION required}"
S3_BUCKET="${3:?S3_BUCKET required}"

RESULTS_DIR="/tmp/benchmark-results"
APP_MEMORY="512m"
APP_CPUS="1"
APP_PORT=8080
PG_NAME="petclinic-postgres"
START_RPS="${START_RPS:-100}"
END_RPS="${END_RPS:-2000}"
PEAK_DURATION="${PEAK_DURATION:-5m}"
PEAK_MAX_VUS="${PEAK_MAX_VUS:-500}"

mkdir -p "$RESULTS_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

ensure_postgres() {
  if ! docker inspect -f '{{.State.Running}}' "$PG_NAME" 2>/dev/null | grep -q true; then
    log "Postgres not running; starting..."
    docker rm -f "$PG_NAME" 2>/dev/null || true
    docker run -d --name "$PG_NAME" --network host \
      -e POSTGRES_DB=petclinic -e POSTGRES_USER=petclinic -e POSTGRES_PASSWORD=petclinic \
      postgres:18.3 >/dev/null
    for i in $(seq 1 30); do
      docker exec "$PG_NAME" pg_isready -U petclinic >/dev/null 2>&1 && { log "Postgres ready (${i}s)"; break; }
      sleep 1
    done
  fi
}

reset_db() {
  docker exec "$PG_NAME" psql -U petclinic -c \
    "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 || true
}

# --- Cold-start-under-load ---
cold_start() {
  local variant="$1"
  local image="${ECR_URL}:${variant}"
  local cname="petclinic-${variant}-cold"
  local probe_log="$RESULTS_DIR/${variant}-cold-probe.log"

  log "Cold-start-under-load: $variant"
  reset_db
  docker rm -f "$cname" >/dev/null 2>&1 || true
  : > "$probe_log"

  ( set +e
    while true; do
      ts=$(date +%s.%3N)
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
        "http://localhost:${APP_PORT}/actuator/health" 2>/dev/null)
      [[ -z "$code" ]] && code="000"
      echo "$ts $code" >> "$probe_log"
      sleep 0.1
    done ) </dev/null >/dev/null 2>&1 &
  local probe_pid=$!

  sleep 2
  local start_ts; start_ts=$(date +%s.%3N)
  docker run -d --name "$cname" --network host \
    --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE=postgres \
    -e POSTGRES_URL=jdbc:postgresql://localhost:5432/petclinic \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    "$image" >/dev/null

  local first_200_ts=""
  for _ in $(seq 1 900); do
    first_200_ts=$(awk -v st="$start_ts" '$1>=st && $2=="200" {print $1; exit}' "$probe_log" 2>/dev/null || true)
    [[ -n "$first_200_ts" ]] && break
    sleep 0.2
  done

  if [[ -n "$first_200_ts" ]]; then
    local cold_ms; cold_ms=$(awk "BEGIN{printf \"%d\", ($first_200_ts - $start_ts) * 1000}")
    echo "$cold_ms" > "$RESULTS_DIR/${variant}-cold-start-ms.txt"
    log "$variant cold-start-under-load: ${cold_ms}ms"
  else
    echo "TIMEOUT" > "$RESULTS_DIR/${variant}-cold-start-ms.txt"
    log "$variant: cold-start TIMEOUT"
  fi

  kill "$probe_pid" 2>/dev/null || true
  docker rm -f "$cname" >/dev/null 2>&1 || true
}

# --- Peak-RPS sweep ---
peak_rps() {
  local variant="$1"
  local image="${ECR_URL}:${variant}"
  local cname="petclinic-${variant}-peak"

  log "Peak-RPS: $variant (${START_RPS}->${END_RPS} req/s over ${PEAK_DURATION})"
  reset_db
  docker rm -f "$cname" >/dev/null 2>&1 || true

  docker run -d --name "$cname" --network host \
    --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE=postgres \
    -e POSTGRES_URL=jdbc:postgresql://localhost:5432/petclinic \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    "$image" >/dev/null

  log "Waiting for $variant healthy..."
  for i in $(seq 1 180); do
    curl -sf "http://localhost:${APP_PORT}/actuator/health" >/dev/null 2>&1 && { log "$variant healthy (${i}s)"; break; }
    sleep 1
  done
  # JIT warm-up: give JVM 30s under light load before the sweep
  if [[ "$variant" == "jvm" ]]; then
    log "JIT warm-up for 30s..."
    for _ in $(seq 1 300); do
      curl -s -o /dev/null "http://localhost:${APP_PORT}/vets" -H "Accept: application/json" || true
      sleep 0.1
    done
  fi

  log "Running k6 peak-RPS sweep..."
  DURATION="$PEAK_DURATION" START_RPS="$START_RPS" END_RPS="$END_RPS" MAX_VUS="$PEAK_MAX_VUS" \
    k6 run \
    --out "csv=$RESULTS_DIR/${variant}-peak-rps.csv" \
    --summary-export "$RESULTS_DIR/${variant}-peak-rps-summary.json" \
    -e BASE_URL="http://localhost:${APP_PORT}" \
    -e START_RPS="$START_RPS" -e END_RPS="$END_RPS" \
    -e DURATION="$PEAK_DURATION" -e MAX_VUS="$PEAK_MAX_VUS" \
    /tmp/k6/peak-rps.js 2>&1 | tee "$RESULTS_DIR/${variant}-peak-rps-output.txt"

  docker stop "$cname" >/dev/null 2>&1 || true
  docker rm "$cname" >/dev/null 2>&1 || true
}

# --- Main ---
ensure_postgres

# Cold-start (was missing in earlier failed run)
cold_start jvm
sleep 5
cold_start native

# Peak-RPS
sleep 5
peak_rps jvm
sleep 10
peak_rps native

docker stop "$PG_NAME" >/dev/null 2>&1 || true
docker rm "$PG_NAME" >/dev/null 2>&1 || true

log "Uploading to S3..."
aws s3 sync "$RESULTS_DIR" "s3://${S3_BUCKET}/results/" --region "$AWS_REGION"
echo "done" | aws s3 cp - "s3://${S3_BUCKET}/DONE" --region "$AWS_REGION"

log "=== finish-on-ec2 complete ==="
