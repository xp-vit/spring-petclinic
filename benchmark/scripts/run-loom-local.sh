#!/usr/bin/env bash
# Virtual-thread (Project Loom) benchmark - local validation harness.
#
# Same petclinic:jvm fat JAR, two thread modes toggled by config only:
#   platform  spring.threads.virtual.enabled=false  (Tomcat default, ~200 worker threads)
#   virtual   spring.threads.virtual.enabled=true    (virtual threads)
#
# Drives a blocking endpoint (GET /api/slow?ms=N -> co-located async stub) at rising
# concurrency levels and records, per (mode, level): throughput, latency percentiles, error
# rate, live PLATFORM thread count (via /api/threadstats), and container CPU/memory.
#
# The story: on platform threads, once concurrency passes the ~200 worker pool, requests
# queue -> latency climbs, throughput plateaus. On virtual threads the app keeps scaling.
#
# Usage:
#   ./benchmark/scripts/run-loom-local.sh [modes] [levels]
#     modes  = "platform virtual" (default) | subset
#     levels = "50 100 200 500 1000" (default) | custom space-separated
#
# Env:
#   ENDPOINT=slow|slow-db|cpu   MS=200   ITERS=500000   DURATION=30s
#   HIKARI_MAX_POOL=10          (slow-db pool story)
#   APP_PORT=8080  STUB_PORT=9090
#   SKIP_BUILD=1                reuse existing petclinic:jvm + loom-stub images
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
DOCKER_DIR="$BENCHMARK_DIR/docker"
LOOM_DIR="$BENCHMARK_DIR/loom"
RESULTS_DIR="$BENCHMARK_DIR/results/${RESULTS_SUBDIR:-local-loom}"

MODES_ARG="${1:-platform virtual}"
LEVELS="${2:-50 100 200 500 1000}"

ENDPOINT="${ENDPOINT:-slow}"
MS="${MS:-200}"
ITERS="${ITERS:-500000}"
DURATION="${DURATION:-30s}"
HIKARI_MAX_POOL="${HIKARI_MAX_POOL:-10}"

APP_MEMORY="${APP_MEMORY:-1g}"
APP_CPUS="${APP_CPUS:-2}"
APP_PORT="${APP_PORT:-8080}"
STUB_PORT="${STUB_PORT:-9090}"
PG_NAME="petclinic-postgres"
PG_PORT=5432
STUB_NAME="loom-stub"
APP_NAME="petclinic-loom"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
require() { for c in "$@"; do command -v "$c" >/dev/null || { echo "ERROR: $c not in PATH"; exit 2; }; done; }

cleanup() {
  log "Cleanup..."
  docker rm -f "$APP_NAME" "$STUB_NAME" "$PG_NAME" 2>/dev/null || true
  [[ -n "${SAMPLER_PID:-}" ]] && kill "$SAMPLER_PID" 2>/dev/null || true
}
trap cleanup EXIT

build_images() {
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then log "SKIP_BUILD=1, reusing images"; return; fi
  log "Building petclinic:jvm..."
  cp "$DOCKER_DIR/.dockerignore" "$PROJECT_ROOT/.dockerignore"
  docker build -f "$DOCKER_DIR/Dockerfile.jvm" -t petclinic:jvm "$PROJECT_ROOT"
  rm -f "$PROJECT_ROOT/.dockerignore"
  log "Building loom-stub..."
  docker build -f "$LOOM_DIR/Dockerfile.stub" -t loom-stub "$LOOM_DIR"
}

start_postgres() {
  log "Starting Postgres..."
  docker rm -f "$PG_NAME" 2>/dev/null || true
  docker run -d --name "$PG_NAME" --network host \
    -e POSTGRES_DB=petclinic -e POSTGRES_USER=petclinic -e POSTGRES_PASSWORD=petclinic \
    postgres:18.3 >/dev/null
  for i in $(seq 1 30); do
    docker exec "$PG_NAME" pg_isready -U petclinic >/dev/null 2>&1 && { log "Postgres ready (${i}s)"; return; }
    sleep 1
  done
  echo "ERROR: Postgres not ready"; exit 4
}

start_stub() {
  log "Starting slow-stub on :$STUB_PORT..."
  docker rm -f "$STUB_NAME" 2>/dev/null || true
  docker run -d --name "$STUB_NAME" --network host -e PORT="$STUB_PORT" loom-stub >/dev/null
  for i in $(seq 1 20); do
    curl -sf "http://localhost:${STUB_PORT}/health" >/dev/null 2>&1 && { log "stub ready (${i}s)"; return; }
    sleep 1
  done
  echo "ERROR: stub not ready"; docker logs "$STUB_NAME" --tail 40; exit 4
}

flag_for() { [[ "$1" == "virtual" ]] && echo "true" || echo "false"; }

start_app() {
  local mode="$1" vflag; vflag="$(flag_for "$mode")"
  docker rm -f "$APP_NAME" 2>/dev/null || true
  log "Starting app (mode=$mode, virtual.enabled=$vflag, hikari=$HIKARI_MAX_POOL, tomcat.max=${TOMCAT_THREADS_MAX:-200})..."
  docker run -d --name "$APP_NAME" --network host --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE="postgres,loom" \
    -e SPRING_THREADS_VIRTUAL_ENABLED="$vflag" \
    -e SERVER_PORT="$APP_PORT" \
    -e LOOM_STUB_URL="http://localhost:${STUB_PORT}" \
    -e HIKARI_MAX_POOL="$HIKARI_MAX_POOL" \
    -e TOMCAT_THREADS_MAX="${TOMCAT_THREADS_MAX:-200}" \
    -e POSTGRES_URL="jdbc:postgresql://localhost:5432/petclinic" \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    petclinic:jvm >/dev/null
  for i in $(seq 1 120); do
    if curl -sf "http://localhost:${APP_PORT}/actuator/health" >/dev/null 2>&1; then
      log "app healthy (${i}s)"; break
    fi
    sleep 1
  done
  curl -sf "http://localhost:${APP_PORT}/actuator/health" >/dev/null 2>&1 || {
    echo "ERROR: app not healthy"; docker logs "$APP_NAME" --tail 80; return 5; }
  # Confirm the toggle actually took effect (a request handled on a virtual thread?).
  local ts; ts=$(curl -s "http://localhost:${APP_PORT}/api/threadstats" || true)
  log "threadstats@idle: $ts"
}

# Poll /api/threadstats every second into a CSV for the duration of a level's load.
start_thread_sampler() {
  local outfile="$1" level="$2"
  ( while true; do
      local j pt; j=$(curl -s "http://localhost:${APP_PORT}/api/threadstats" 2>/dev/null || true)
      pt=$(echo "$j" | python3 -c "import sys,json;
try: print(json.load(sys.stdin).get('platformThreadCount',''))
except: print('')" 2>/dev/null || echo "")
      [[ -n "$pt" ]] && echo "$(date +%s.%3N),$level,$pt" >> "$outfile"
      sleep 1
    done ) &
  SAMPLER_PID=$!
}
stop_thread_sampler() { [[ -n "${SAMPLER_PID:-}" ]] && kill "$SAMPLER_PID" 2>/dev/null || true; SAMPLER_PID=""; }

run_level() {
  local mode="$1" level="$2"
  local tag="${mode}-c${level}"
  log "--- $mode @ concurrency=$level ($ENDPOINT, ms=$MS, dur=$DURATION) ---"
  # Per-level peak is derived from the sampled series (filtered by level), so no JVM-side
  # reset is needed; one warmup ping just confirms the endpoint is reachable.
  curl -s "http://localhost:${APP_PORT}/api/threadstats" >/dev/null 2>&1 || true
  start_thread_sampler "$RESULTS_DIR/${mode}-threads.csv" "$level"

  docker run --rm --network host --user "$(id -u):$(id -g)" \
    -v "$BENCHMARK_DIR/k6:/scripts:ro" -v "$RESULTS_DIR:/out" \
    -e BASE_URL="http://localhost:${APP_PORT}" -e ENDPOINT="$ENDPOINT" \
    -e MS="$MS" -e ITERS="$ITERS" -e CONCURRENCY="$level" -e DURATION="$DURATION" \
    grafana/k6:latest run \
    --summary-export="/out/${tag}-summary.json" \
    /scripts/loom-workload.js \
    2>&1 | tee "$RESULTS_DIR/${tag}-k6-output.txt"

  stop_thread_sampler
  docker stats "$APP_NAME" --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' \
    > "$RESULTS_DIR/${tag}-stats-after.txt" || true
}

run_mode() {
  local mode="$1"
  echo "ts,level,platform_threads" > "$RESULTS_DIR/${mode}-threads.csv"
  start_app "$mode"
  for lvl in $LEVELS; do run_level "$mode" "$lvl"; done
  docker stop "$APP_NAME" >/dev/null; docker rm "$APP_NAME" >/dev/null
}

summarize() {
  log "Summarizing..."
  python3 - "$RESULTS_DIR" "$ENDPOINT" "$MS" "$MODES_ARG" "$LEVELS" <<'PY'
import sys, os, json
rd, endpoint, ms, modes, levels = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split(), sys.argv[5].split()

def peak_threads(mode, level):
    f = os.path.join(rd, f"{mode}-threads.csv")
    if not os.path.isfile(f): return ""
    mx = 0
    with open(f) as fh:
        next(fh, None)
        for line in fh:
            p = line.strip().split(",")
            if len(p) == 3 and p[1] == level:
                try: mx = max(mx, int(p[2]))
                except: pass
    return mx or ""

print(f"\nendpoint={endpoint} ms={ms}")
hdr = f"{'mode':<10}{'conc':>6}{'RPS':>10}{'p50':>9}{'p95':>9}{'p99':>9}{'max':>9}{'err%':>7}{'peakThr':>9}"
print(hdr); print("-"*len(hdr))
for mode in modes:
    for lvl in levels:
        f = os.path.join(rd, f"{mode}-c{lvl}-summary.json")
        if not os.path.isfile(f):
            print(f"{mode:<10}{lvl:>6}   (no results)"); continue
        m = json.load(open(f)).get("metrics", {})
        d = m.get("http_req_duration", {})
        rps = m.get("http_reqs", {}).get("rate", float('nan'))
        err = m.get("http_req_failed", {}).get("rate", 0.0) * 100
        print(f"{mode:<10}{lvl:>6}{rps:>10.1f}{d.get('med',float('nan')):>9.1f}"
              f"{d.get('p(95)',float('nan')):>9.1f}{d.get('p(99)',float('nan')):>9.1f}"
              f"{d.get('max',float('nan')):>9.1f}{err:>7.2f}{str(peak_threads(mode,lvl)):>9}")
print("\n(latency ms; RPS=req/s; peakThr=peak PLATFORM thread count during the level)")
PY
}

main() {
  require docker curl python3
  mkdir -p "$RESULTS_DIR"
  local modes
  case "$MODES_ARG" in
    all) modes="platform virtual";;
    *)   modes="$MODES_ARG";;
  esac
  log "Modes: $modes | Levels: $LEVELS | endpoint=$ENDPOINT ms=$MS dur=$DURATION"
  log "Results: $RESULTS_DIR"

  build_images
  start_postgres
  start_stub
  for m in $modes; do run_mode "$m"; done
  summarize | tee "$RESULTS_DIR/comparison.txt"
  log "Done. Results: $RESULTS_DIR"
}
main "$@"
