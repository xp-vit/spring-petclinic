#!/usr/bin/env bash
# Runs ON the EC2 instance. Args: ECR_URL AWS_REGION S3_BUCKET
# Mirrors run-local.sh metrics: startup, cold-start-under-load, image size,
# CPU+RSS sampling, GC log (JVM), k6 mixed workload.
set -euo pipefail

ECR_URL="${1:?Usage: run-on-ec2.sh ECR_URL AWS_REGION S3_BUCKET}"
AWS_REGION="${2:?Usage: run-on-ec2.sh ECR_URL AWS_REGION S3_BUCKET}"
S3_BUCKET="${3:?Usage: run-on-ec2.sh ECR_URL AWS_REGION S3_BUCKET}"

RESULTS_DIR="/tmp/benchmark-results"
APP_MEMORY="512m"
APP_CPUS="1"
APP_PORT=8080
PG_NAME="petclinic-postgres"
DURATION="${DURATION:-10m}"
VUS_TOTAL="${VUS_TOTAL:-50}"

mkdir -p "$RESULTS_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- ECR + pull ---
log "ECR auth..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_URL"
log "Pulling images..."
docker pull "${ECR_URL}:jvm"
docker pull "${ECR_URL}:native"

# --- Postgres ---
log "Starting Postgres..."
docker rm -f "$PG_NAME" 2>/dev/null || true
docker run -d --name "$PG_NAME" --network host \
  -e POSTGRES_DB=petclinic -e POSTGRES_USER=petclinic -e POSTGRES_PASSWORD=petclinic \
  postgres:18.3 >/dev/null
for i in $(seq 1 30); do
  docker exec "$PG_NAME" pg_isready -U petclinic >/dev/null 2>&1 && { log "Postgres ready (${i}s)"; break; }
  sleep 1
done

reset_db() {
  docker exec "$PG_NAME" psql -U petclinic -c \
    "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 || true
}

# --- Stats sampler (CPU + RSS @ 1Hz) ---
start_stats_sampler() {
  local name="$1" out="$2"
  echo "ts,cpu_pct,mem_bytes" > "$out"
  (
    while docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; do
      local line ts cpu memraw mem
      line=$(docker stats "$name" --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null || true)
      if [[ -n "$line" ]]; then
        ts=$(date +%s.%3N)
        cpu="${line%%|*}"; cpu="${cpu//%/}"
        memraw="${line##*|}"; memraw="${memraw%% /*}"
        mem=$(python3 -c "
s='$memraw'.strip()
m={'B':1,'KiB':1024,'MiB':1024**2,'GiB':1024**3,'KB':1000,'MB':1000**2,'GB':1000**3}
for k,v in m.items():
  if s.endswith(k): print(int(float(s[:-len(k)])*v)); break
else: print(0)
" 2>/dev/null || echo 0)
        echo "$ts,$cpu,$mem" >> "$out"
      fi
      sleep 1
    done
  ) &
  echo $!
}

# --- Run one variant ---
run_variant() {
  local variant="$1" image="$2"
  local cname="petclinic-${variant}"

  log "=== $variant ==="

  # Image size
  docker image inspect "$image" --format '{{.Size}}' \
    > "$RESULTS_DIR/${variant}-image-size-bytes.txt"

  reset_db

  local gc_dir="$RESULTS_DIR/${variant}-gc"
  rm -rf "$gc_dir"; mkdir -p "$gc_dir"
  local extra_mounts=()
  [[ "$variant" == "jvm" ]] && extra_mounts+=("-v" "$gc_dir:/var/log/petclinic")

  docker rm -f "$cname" 2>/dev/null || true

  local start_ts ready_ts startup_ms
  start_ts=$(date +%s%N)
  docker run -d --name "$cname" --network host \
    --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE=postgres \
    -e POSTGRES_URL=jdbc:postgresql://localhost:5432/petclinic \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    "${extra_mounts[@]}" "$image" >/dev/null

  for i in $(seq 1 180); do
    if curl -sf "http://localhost:${APP_PORT}/actuator/health" >/dev/null 2>&1; then
      ready_ts=$(date +%s%N)
      startup_ms=$(( (ready_ts - start_ts) / 1000000 ))
      echo "$startup_ms" > "$RESULTS_DIR/${variant}-startup-ms.txt"
      log "$variant startup: ${startup_ms}ms"
      break
    fi
    sleep 1
  done
  [[ -z "${ready_ts:-}" ]] && { log "ERROR: $variant unhealthy"; docker logs "$cname" --tail 80; return 5; }

  local stats_pid; stats_pid=$(start_stats_sampler "$cname" "$RESULTS_DIR/${variant}-stats.csv")

  log "k6 ($DURATION, $VUS_TOTAL VUs)..."
  DURATION="$DURATION" VUS_TOTAL="$VUS_TOTAL" \
    k6 run \
    --out "csv=$RESULTS_DIR/${variant}-k6-results.csv" \
    --summary-export "$RESULTS_DIR/${variant}-k6-summary.json" \
    -e BASE_URL="http://localhost:${APP_PORT}" \
    -e DURATION="$DURATION" -e VUS_TOTAL="$VUS_TOTAL" \
    /tmp/k6/mixed-workload.js 2>&1 | tee "$RESULTS_DIR/${variant}-k6-output.txt"

  kill "$stats_pid" 2>/dev/null || true
  wait "$stats_pid" 2>/dev/null || true

  docker stats "$cname" --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' \
    > "$RESULTS_DIR/${variant}-stats-after.txt" || true

  docker stop "$cname" >/dev/null
  docker rm "$cname" >/dev/null
  log "=== $variant done ==="
}

# --- Cold-start-under-load (separate quick test, ~20s each) ---
cold_start_under_load() {
  local variant="$1" image="$2"
  local cname="petclinic-${variant}-cold"
  log "Cold-start-under-load: $variant"
  reset_db
  docker rm -f "$cname" 2>/dev/null || true

  local probe_log="$RESULTS_DIR/${variant}-cold-probe.log"
  : > "$probe_log"
  ( while true; do
      ts=$(date +%s.%3N)
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
        "http://localhost:${APP_PORT}/actuator/health" 2>/dev/null)
      [[ -z "$code" ]] && code="000"
      echo "$ts $code" >> "$probe_log"
      sleep 0.1
    done ) &
  local probe_pid=$!
  sleep 2

  local start_ts; start_ts=$(date +%s.%3N)
  docker run -d --name "$cname" --network host \
    --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE=postgres \
    -e POSTGRES_URL=jdbc:postgresql://localhost:5432/petclinic \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    "$image" >/dev/null

  local first_200_ts="" deadline
  deadline=$(awk "BEGIN{print $start_ts + 180}")
  while :; do
    first_200_ts=$(awk -v st="$start_ts" '$1>=st && $2=="200" {print $1; exit}' "$probe_log" || true)
    [[ -n "$first_200_ts" ]] && break
    now=$(date +%s.%3N)
    awk "BEGIN{exit !($now>$deadline)}" && break
    sleep 0.2
  done

  if [[ -n "$first_200_ts" ]]; then
    local cold_ms; cold_ms=$(awk "BEGIN{printf \"%d\", ($first_200_ts - $start_ts) * 1000}")
    echo "$cold_ms" > "$RESULTS_DIR/${variant}-cold-start-ms.txt"
    log "$variant cold-start-under-load: ${cold_ms}ms"
  else
    echo "TIMEOUT" > "$RESULTS_DIR/${variant}-cold-start-ms.txt"
  fi

  kill "$probe_pid" 2>/dev/null || true
  docker rm -f "$cname" >/dev/null
}

# --- Main ---
run_variant jvm "${ECR_URL}:jvm"
sleep 10
run_variant native "${ECR_URL}:native"

# Cold-start tests
sleep 5
cold_start_under_load jvm "${ECR_URL}:jvm"
sleep 5
cold_start_under_load native "${ECR_URL}:native"

# Stop Postgres
docker stop "$PG_NAME" >/dev/null
docker rm "$PG_NAME" >/dev/null

# Upload
log "Uploading to S3..."
aws s3 sync "$RESULTS_DIR" "s3://${S3_BUCKET}/results/" --region "$AWS_REGION"
echo "done" | aws s3 cp - "s3://${S3_BUCKET}/DONE" --region "$AWS_REGION"

log "=== All benchmarks complete ==="
