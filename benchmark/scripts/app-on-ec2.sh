#!/usr/bin/env bash
# v2 app-side: starts ONE variant container connected to RDS, samples CPU+RSS
# in the background, writes startup-ms + image-size + (for JVM) GC log.  k6
# is driven from a separate EC2 -- this script only manages the SUT.
#
# Args: ACTION VARIANT ECR_URL RDS_HOST AWS_REGION S3_BUCKET
#   ACTION = start | stop | upload | cold_start
#
# 'start':  pulls image, starts container, waits healthy, starts sampler.
# 'stop':   stops sampler + container.
# 'upload': uploads /tmp/benchmark-results to s3.
# 'cold_start': cold-start-under-load measurement (probes loopback while
#               the container is starting).
set -euo pipefail

ACTION="${1:?ACTION required}"
VARIANT="${2:?VARIANT required}"
ECR_URL="${3:?ECR_URL required}"
RDS_HOST="${4:?RDS_HOST required}"
AWS_REGION="${5:?AWS_REGION required}"
S3_BUCKET="${6:?S3_BUCKET required}"

RESULTS_DIR="/tmp/benchmark-results"
APP_MEMORY="${APP_MEMORY:-512m}"
APP_CPUS="${APP_CPUS:-1}"
APP_PORT=8080
CNAME="petclinic-${VARIANT}"
STATS_PIDFILE="/tmp/stats-pid-${VARIANT}"

mkdir -p "$RESULTS_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

ecr_login() {
  if ! docker info >/dev/null 2>&1; then
    log "docker daemon not running"; return 1
  fi
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_URL" >/dev/null
}

start_stats() {
  local out="$RESULTS_DIR/${VARIANT}-stats.csv"
  echo "ts,cpu_pct,mem_bytes" > "$out"
  (
    set +e
    while docker inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null | grep -q true; do
      line=$(docker stats "$CNAME" --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null || true)
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
  echo $! > "$STATS_PIDFILE"
}

stop_stats() {
  if [[ -f "$STATS_PIDFILE" ]]; then
    local pid; pid=$(cat "$STATS_PIDFILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$STATS_PIDFILE"
  fi
}

start_container() {
  local image="${ECR_URL}:${VARIANT}"
  local gc_dir="$RESULTS_DIR/${VARIANT}-gc"
  rm -rf "$gc_dir"; mkdir -p "$gc_dir"
  local mounts=()
  [[ "$VARIANT" == "jvm" ]] && mounts+=("-v" "$gc_dir:/var/log/petclinic")
  docker rm -f "$CNAME" >/dev/null 2>&1 || true

  local start_ts; start_ts=$(date +%s%N)
  docker run -d --name "$CNAME" --network host \
    --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE=postgres \
    -e POSTGRES_URL="jdbc:postgresql://${RDS_HOST}:5432/petclinic" \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    "${mounts[@]}" "$image" >/dev/null

  for i in $(seq 1 180); do
    if curl -sf "http://localhost:${APP_PORT}/actuator/health" >/dev/null 2>&1; then
      local ready_ts; ready_ts=$(date +%s%N)
      local startup_ms=$(( (ready_ts - start_ts) / 1000000 ))
      echo "$startup_ms" > "$RESULTS_DIR/${VARIANT}-startup-ms.txt"
      log "$VARIANT startup: ${startup_ms}ms"
      docker image inspect "$image" --format '{{.Size}}' \
        > "$RESULTS_DIR/${VARIANT}-image-size-bytes.txt"
      return 0
    fi
    sleep 1
  done
  log "ERROR: $VARIANT did not become healthy in 180s"
  docker logs "$CNAME" --tail 80
  return 5
}

case "$ACTION" in
  start)
    ecr_login
    docker pull "${ECR_URL}:${VARIANT}" >/dev/null
    start_container
    start_stats
    ;;

  stop)
    stop_stats
    docker stats "$CNAME" --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' \
      > "$RESULTS_DIR/${VARIANT}-stats-after.txt" 2>/dev/null || true
    docker stop "$CNAME" >/dev/null 2>&1 || true
    docker rm "$CNAME" >/dev/null 2>&1 || true
    ;;

  upload)
    aws s3 sync "$RESULTS_DIR" "s3://${S3_BUCKET}/results/" --region "$AWS_REGION"
    ;;

  cold_start)
    ecr_login
    docker pull "${ECR_URL}:${VARIANT}" >/dev/null
    local probe_log="$RESULTS_DIR/${VARIANT}-cold-probe.log"
    : > "$probe_log"
    docker rm -f "${CNAME}-cold" >/dev/null 2>&1 || true

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
    docker run -d --name "${CNAME}-cold" --network host \
      --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
      -e SPRING_PROFILES_ACTIVE=postgres \
      -e POSTGRES_URL="jdbc:postgresql://${RDS_HOST}:5432/petclinic" \
      -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
      "${ECR_URL}:${VARIANT}" >/dev/null

    local first_200_ts=""
    for _ in $(seq 1 900); do
      first_200_ts=$(awk -v st="$start_ts" '$1>=st && $2=="200" {print $1; exit}' "$probe_log" 2>/dev/null || true)
      [[ -n "$first_200_ts" ]] && break
      sleep 0.2
    done

    if [[ -n "$first_200_ts" ]]; then
      local cold_ms; cold_ms=$(awk "BEGIN{printf \"%d\", ($first_200_ts - $start_ts) * 1000}")
      echo "$cold_ms" > "$RESULTS_DIR/${VARIANT}-cold-start-ms.txt"
      log "$VARIANT cold-start-under-load: ${cold_ms}ms"
    else
      echo "TIMEOUT" > "$RESULTS_DIR/${VARIANT}-cold-start-ms.txt"
    fi

    kill "$probe_pid" 2>/dev/null || true
    docker rm -f "${CNAME}-cold" >/dev/null 2>&1 || true
    ;;

  *)
    echo "Unknown action: $ACTION"
    exit 2
    ;;
esac
