#!/usr/bin/env bash
# Virtual-thread benchmark app-side: manages the co-located slow-HTTP stub and the app
# container on one EC2. Same petclinic:jvm ECR image for both thread modes; only
# SPRING_THREADS_VIRTUAL_ENABLED (and HikariCP sizing for the pool story) differ.
#
# Runs on the app EC2 via:  sudo -n /tmp/loom-app-on-ec2.sh ACTION ...
#
# Args: ACTION ECR_URL RDS_HOST AWS_REGION S3_BUCKET [MODE [HIKARI [TAG]]]
#   ACTION:
#     start-infra   -- ECR login, pull jvm image, start the async slow-stub (host python3)
#     start         -- start app container (MODE=platform|virtual, HIKARI pool, TAG label)
#     stop          -- stop app container + docker-stats sampler
#     stop-infra    -- stop the slow-stub
#     upload        -- sync /tmp/benchmark-results to s3://.../loom-results/
#   MODE   = platform | virtual   (spring.threads.virtual.enabled)
#   HIKARI = max pool size (default 10)
#   TAG    = output-file label, e.g. slow-platform / slowdb-h100 / cpu-virtual
set -euo pipefail

ACTION="${1:?ACTION required}"
ECR_URL="${2:?ECR_URL required}"
RDS_HOST="${3:?RDS_HOST required}"
AWS_REGION="${4:?AWS_REGION required}"
S3_BUCKET="${5:?S3_BUCKET required}"
MODE="${6:-platform}"
HIKARI="${7:-10}"
TAG="${8:-run}"

RESULTS_DIR="/tmp/benchmark-results"
APP_MEMORY="${APP_MEMORY:-3g}"
APP_CPUS="${APP_CPUS:-2}"
APP_PORT=8080
STUB_PORT="${STUB_PORT:-9090}"
IMAGE="${ECR_URL}:jvm"
STUB_SRC="/tmp/slow-stub.py"
STUB_PIDFILE="/tmp/slow-stub.pid"

mkdir -p "$RESULTS_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

flag_for() { [[ "$1" == "virtual" ]] && echo "true" || echo "false"; }

start_stats_sampler() {
  local cname="petclinic-loom"
  local out="$RESULTS_DIR/${TAG}-appstats.csv"
  echo "ts,cpu_pct,mem_bytes" > "$out"
  (
    set +e
    while docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q true; do
      line=$(docker stats "$cname" --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null || true)
      if [[ -n "$line" ]]; then
        ts=$(date +%s.%3N)
        cpu="${line%%|*}"; cpu="${cpu//%/}"
        memraw="${line##*|}"; memraw="${memraw%% /*}"
        mem=$(python3 -c "
s='$memraw'.strip()
u=[('GiB',1024**3),('MiB',1024**2),('KiB',1024),('GB',1000**3),('MB',1000**2),('KB',1000),('B',1)]
for k,v in u:
  if s.endswith(k): print(int(float(s[:-len(k)])*v)); break
else: print(0)
" 2>/dev/null || echo 0)
        echo "$ts,$cpu,$mem" >> "$out"
      fi
      sleep 1
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $! > "/tmp/stats-pid-loom"
}

stop_stats_sampler() {
  local pf="/tmp/stats-pid-loom"
  [[ -f "$pf" ]] && { kill "$(cat "$pf")" 2>/dev/null || true; rm -f "$pf"; }
}

case "$ACTION" in

  start-infra)
    log "ECR login + pulling jvm image..."
    aws ecr get-login-password --region "$AWS_REGION" | \
      docker login --username AWS --password-stdin "$ECR_URL" >/dev/null
    docker pull "$IMAGE" >/dev/null
    log "Starting async slow-stub on :$STUB_PORT (host python3)..."
    [[ -f "$STUB_PIDFILE" ]] && { kill "$(cat "$STUB_PIDFILE")" 2>/dev/null || true; rm -f "$STUB_PIDFILE"; }
    PORT="$STUB_PORT" nohup python3 "$STUB_SRC" </dev/null >/tmp/slow-stub.log 2>&1 &
    echo $! > "$STUB_PIDFILE"
    for i in $(seq 1 20); do
      curl -sf "http://localhost:${STUB_PORT}/health" >/dev/null 2>&1 && { log "stub ready (${i}s)"; break; }
      sleep 1
    done
    curl -sf "http://localhost:${STUB_PORT}/health" >/dev/null 2>&1 || { log "ERROR: stub not up"; cat /tmp/slow-stub.log; exit 4; }
    ;;

  start)
    local_vflag="$(flag_for "$MODE")"
    CNAME="petclinic-loom"
    log "=== Start MODE=$MODE (virtual=$local_vflag) HIKARI=$HIKARI TAG=$TAG ==="
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    start_ts=$(date +%s%N)
    # SQL init off: the Loom endpoints need only a live connection (SELECT 1) + the pool, not
    # PetClinic's schema/data. ddl-auto=none means missing tables don't fail startup.
    docker run -d --name "$CNAME" --network host \
      --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
      -e SPRING_PROFILES_ACTIVE="postgres,loom" \
      -e SPRING_THREADS_VIRTUAL_ENABLED="$local_vflag" \
      -e HIKARI_MAX_POOL="$HIKARI" \
      -e LOOM_STUB_URL="http://localhost:${STUB_PORT}" \
      -e POSTGRES_URL="jdbc:postgresql://${RDS_HOST}:5432/petclinic" \
      -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
      -e SPRING_SQL_INIT_MODE="never" \
      "$IMAGE" >/dev/null
    ready_ts=""
    for i in $(seq 1 180); do
      if curl -sf "http://localhost:${APP_PORT}/actuator/health" >/dev/null 2>&1; then
        ready_ts=$(date +%s%N)
        startup_ms=$(( (ready_ts - start_ts) / 1000000 ))
        echo "$startup_ms" > "$RESULTS_DIR/${TAG}-startup-ms.txt"
        log "app healthy after ${startup_ms}ms"
        break
      fi
      sleep 1
    done
    [[ -z "$ready_ts" ]] && { log "ERROR: app not healthy in 180s"; docker logs "$CNAME" --tail 80; exit 5; }
    ts=$(curl -s "http://localhost:${APP_PORT}/api/threadstats" || true)
    log "threadstats@idle: $ts"
    start_stats_sampler
    ;;

  stop)
    CNAME="petclinic-loom"
    stop_stats_sampler
    docker stats "$CNAME" --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' \
      > "$RESULTS_DIR/${TAG}-appstats-after.txt" 2>/dev/null || true
    docker stop "$CNAME" >/dev/null 2>&1 || true
    docker rm "$CNAME" >/dev/null 2>&1 || true
    log "=== stopped ($TAG) ==="
    ;;

  stop-infra)
    log "Stopping slow-stub..."
    [[ -f "$STUB_PIDFILE" ]] && { kill "$(cat "$STUB_PIDFILE")" 2>/dev/null || true; rm -f "$STUB_PIDFILE"; }
    ;;

  upload)
    log "Uploading app results to S3 (loom-results/)..."
    aws s3 sync "$RESULTS_DIR" "s3://${S3_BUCKET}/loom-results/" --region "$AWS_REGION"
    ;;

  *)
    echo "Unknown action: $ACTION"; exit 2;;
esac
