#!/usr/bin/env bash
# v2 app-side: starts ONE variant container connected to RDS, samples CPU+RSS
# in the background, writes startup-ms + image-size + (for JVM) GC log.  k6
# is driven from a separate EC2 -- this script only manages the SUT.
#
# Args: ACTION VARIANT ECR_URL RDS_HOST AWS_REGION S3_BUCKET [PHASE]
#   ACTION = start | stop | upload | cold_start
#   PHASE  = optional tag (e.g. "mixed", "peak").  When provided, the stats
#            CSV is named {variant}-stats-{phase}.csv so subsequent phases
#            don't overwrite each other.  Default keeps the legacy
#            {variant}-stats.csv name for backward compatibility.
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
PHASE="${7:-}"

RESULTS_DIR="/tmp/benchmark-results"
# 8th positional overrides memory (sudo -n strips env vars, so pass it explicitly).
APP_MEMORY="${8:-${APP_MEMORY:-512m}}"
APP_CPUS="${APP_CPUS:-1}"
APP_PORT=8080
CNAME="petclinic-${VARIANT}"
if [[ -n "$PHASE" ]]; then
  STATS_CSV="$RESULTS_DIR/${VARIANT}-stats-${PHASE}.csv"
  STATS_AFTER="$RESULTS_DIR/${VARIANT}-stats-after-${PHASE}.txt"
else
  STATS_CSV="$RESULTS_DIR/${VARIANT}-stats.csv"
  STATS_AFTER="$RESULTS_DIR/${VARIANT}-stats-after.txt"
fi
STATS_PIDFILE="/tmp/stats-pid-${VARIANT}"
# Business endpoint for the cold-start measure (brief: first BUSINESS 200, not
# /actuator/health). Must return 200 only once the app truly serves traffic.
BUSINESS_PATH="${BUSINESS_PATH:-/vets}"
BUSINESS_ACCEPT="${BUSINESS_ACCEPT:-application/json}"

# CRaC restore variants run an image built LOCALLY on this instance by
# crac-prepare-on-ec2.sh (checkpoint must be made on the target CPU + RDS URL).
# Everything else pulls from ECR.
is_crac_restore() { [[ "$VARIANT" == "crac" || "$VARIANT" == "crac-onrefresh" ]]; }
image_ref() {
  case "$VARIANT" in
    crac)           echo "petclinic-crac:warmed" ;;
    crac-onrefresh) echo "petclinic-crac:onrefresh" ;;
    *)              echo "${ECR_URL}:${VARIANT}" ;;
  esac
}

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
  local out="$STATS_CSV"
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
  local image; image=$(image_ref)
  local gc_dir="$RESULTS_DIR/${VARIANT}-gc"
  rm -rf "$gc_dir"; mkdir -p "$gc_dir"
  local mounts=()
  [[ "$VARIANT" == "jvm" || "$VARIANT" == "jaz" || "$VARIANT" == "crac-jvm" ]] && mounts+=("-v" "$gc_dir:/var/log/petclinic")
  docker rm -f "$CNAME" >/dev/null 2>&1 || true

  local start_ts; start_ts=$(date +%s%N)
  docker run -d --name "$CNAME" --network host \
    --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE=postgres \
    -e POSTGRES_URL="jdbc:postgresql://${RDS_HOST}:5432/petclinic" \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    -e PETCLINIC_API_SECRET="${PETCLINIC_API_SECRET:-runtime-secret-never-in-image}" \
    "${mounts[@]}" "$image" >/dev/null

  # Poll a BUSINESS endpoint at 50ms so a sub-second native/CRaC boot isn't
  # quantised, and so "ready" means it truly serves traffic (brief requirement).
  for i in $(seq 1 3600); do
    if curl -sf -H "Accept: ${BUSINESS_ACCEPT}" "http://localhost:${APP_PORT}${BUSINESS_PATH}" >/dev/null 2>&1; then
      local ready_ts; ready_ts=$(date +%s%N)
      local startup_ms=$(( (ready_ts - start_ts) / 1000000 ))
      echo "$startup_ms" > "$RESULTS_DIR/${VARIANT}-startup-ms.txt"
      # Authoritative startup from the app's own log: Spring "Started X in <a>s"
      # for cold boots, or warp "restored JVM running for <n> ms" for CRaC restore.
      local logs started_s proc_s restore_ms
      logs=$(docker logs "$CNAME" 2>&1 || true)
      started_s=$(echo "$logs" | grep -oE 'Started [A-Za-z0-9_]+ in [0-9.]+ seconds' | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
      proc_s=$(echo "$logs" | grep -oE 'process running for [0-9.]+' | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
      restore_ms=$(echo "$logs" | grep -oE 'restored JVM running for [0-9]+ ms' | tail -1 | grep -oE '[0-9]+' | head -1 || true)
      [[ -n "$started_s" ]] && echo "$started_s" > "$RESULTS_DIR/${VARIANT}-spring-started-s.txt" || true
      [[ -n "$proc_s" ]] && echo "$proc_s" > "$RESULTS_DIR/${VARIANT}-process-running-s.txt" || true
      [[ -n "$restore_ms" ]] && echo "$restore_ms" > "$RESULTS_DIR/${VARIANT}-restore-ms.txt" || true
      log "$VARIANT startup: probe ${startup_ms}ms | Spring ${started_s:-?}s | restore ${restore_ms:-?}ms"
      docker image inspect "$image" --format '{{.Size}}' \
        > "$RESULTS_DIR/${VARIANT}-image-size-bytes.txt"
      return 0
    fi
    sleep 0.05
  done
  log "ERROR: $VARIANT did not serve ${BUSINESS_PATH} in 180s"
  docker logs "$CNAME" --tail 80
  return 5
}

case "$ACTION" in
  start)
    if ! is_crac_restore; then ecr_login; docker pull "${ECR_URL}:${VARIANT}" >/dev/null; fi
    start_container
    start_stats
    ;;

  stop)
    stop_stats
    docker stats "$CNAME" --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' \
      > "$STATS_AFTER" 2>/dev/null || true
    docker stop "$CNAME" >/dev/null 2>&1 || true
    docker rm "$CNAME" >/dev/null 2>&1 || true
    ;;

  upload)
    aws s3 sync "$RESULTS_DIR" "s3://${S3_BUCKET}/results/" --region "$AWS_REGION"
    ;;

  cold_start)
    if ! is_crac_restore; then ecr_login; docker pull "${ECR_URL}:${VARIANT}" >/dev/null; fi
    probe_log="$RESULTS_DIR/${VARIANT}-cold-probe.log"
    : > "$probe_log"
    docker rm -f "${CNAME}-cold" >/dev/null 2>&1 || true

    # Probe the BUSINESS endpoint (not /actuator/health) so cold-start = first 200
    # from real traffic.
    ( set +e
      while true; do
        ts=$(date +%s.%3N)
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
          -H "Accept: ${BUSINESS_ACCEPT}" "http://localhost:${APP_PORT}${BUSINESS_PATH}" 2>/dev/null)
        [[ -z "$code" ]] && code="000"
        echo "$ts $code" >> "$probe_log"
        sleep 0.05
      done ) </dev/null >/dev/null 2>&1 &
    probe_pid=$!
    sleep 2

    start_ts=$(date +%s.%3N)
    docker run -d --name "${CNAME}-cold" --network host \
      --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
      -e SPRING_PROFILES_ACTIVE=postgres \
      -e POSTGRES_URL="jdbc:postgresql://${RDS_HOST}:5432/petclinic" \
      -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
      -e PETCLINIC_API_SECRET="${PETCLINIC_API_SECRET:-runtime-secret-never-in-image}" \
      "$(image_ref)" >/dev/null

    first_200_ts=""
    for _ in $(seq 1 900); do
      first_200_ts=$(awk -v st="$start_ts" '$1>=st && $2=="200" {print $1; exit}' "$probe_log" 2>/dev/null || true)
      [[ -n "$first_200_ts" ]] && break
      sleep 0.2
    done

    if [[ -n "$first_200_ts" ]]; then
      cold_ms=$(awk "BEGIN{printf \"%d\", ($first_200_ts - $start_ts) * 1000}")
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
