#!/usr/bin/env bash
# Local JVM vs Native benchmark orchestrator.
# Builds (or reuses) images, starts Postgres, runs k6 mixed workload against each variant,
# samples CPU+RSS, captures JVM GC log, records image size + startup time.
#
# Usage:
#   ./benchmark/scripts/run-local.sh [profile] [variant]
#     profile = smoke (default, 3min/20 VUs) | standard (10min/50 VUs)
#     variant = both (default) | jvm | native
#
# Env overrides:
#   K6_DURATION  (e.g. "3m")     -- overrides profile duration
#   K6_VUS_TOTAL (e.g. "20")     -- overrides VU split (5/5/5/5 or proportional)
#   SKIP_BUILD=1                 -- assume images already built
#   SKIP_COLD_START=1            -- don't run cold-start-under-load phase
#   RESULTS_SUBDIR=local         -- where to dump results
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
RESULTS_DIR="$BENCHMARK_DIR/results/${RESULTS_SUBDIR:-local}"

PROFILE="${1:-smoke}"
VARIANT="${2:-both}"  # accepted: "both" (=jvm+native), "all" (=jvm+native+native-pgo),
                      # or any space-separated subset like "native native-pgo".

APP_MEMORY="512m"
APP_CPUS="1"
APP_PORT=8080
PG_NAME="petclinic-postgres"
PG_PORT=5432

case "$PROFILE" in
  smoke)    DURATION="${K6_DURATION:-3m}"; VUS_TOTAL="${K6_VUS_TOTAL:-20}";;
  standard) DURATION="${K6_DURATION:-10m}"; VUS_TOTAL="${K6_VUS_TOTAL:-50}";;
  *) echo "Unknown profile: $PROFILE"; exit 2;;
esac

log() { echo "[$(date '+%H:%M:%S')] $*"; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not in PATH"; exit 2; }
  done
}

cleanup() {
  log "Cleanup..."
  docker rm -f petclinic-jvm petclinic-native "$PG_NAME" 2>/dev/null || true
  if [[ -n "${STATS_PID:-}" ]]; then kill "$STATS_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

# --- Build ---
build_images() {
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
    log "SKIP_BUILD=1, skipping build"
    return
  fi
  log "Building images (this can take several minutes for native)..."
  "$SCRIPT_DIR/build.sh"
}

ensure_image() {
  local tag="$1"
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    echo "ERROR: image $tag not found. Run build.sh or unset SKIP_BUILD."
    exit 3
  fi
}

# --- Postgres ---
start_postgres() {
  log "Starting Postgres..."
  docker rm -f "$PG_NAME" 2>/dev/null || true
  docker run -d --name "$PG_NAME" \
    -p ${PG_PORT}:5432 \
    -e POSTGRES_DB=petclinic \
    -e POSTGRES_USER=petclinic \
    -e POSTGRES_PASSWORD=petclinic \
    postgres:18.3 >/dev/null
  for i in $(seq 1 30); do
    if docker exec "$PG_NAME" pg_isready -U petclinic >/dev/null 2>&1; then
      log "Postgres ready after ${i}s"; return 0
    fi
    sleep 1
  done
  echo "ERROR: Postgres did not become ready"; exit 4
}

reset_db() {
  docker exec "$PG_NAME" psql -U petclinic -c \
    "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 || true
}

# --- Stats sampler ---
start_stats_sampler() {
  local name="$1"
  local out="$2"
  echo "ts,cpu_pct,mem_bytes" > "$out"
  (
    while docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; do
      local line ts cpu memraw mem
      line=$(docker stats "$name" --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null || true)
      if [[ -n "$line" ]]; then
        ts=$(date +%s.%3N)
        cpu="${line%%|*}"; cpu="${cpu//%/}"
        memraw="${line##*|}"; memraw="${memraw%% /*}"  # e.g. "123.4MiB"
        mem=$(python3 -c "
s='$memraw'.strip()
units=[('GiB',1024**3),('MiB',1024**2),('KiB',1024),('GB',1000**3),('MB',1000**2),('KB',1000),('B',1)]
for k,v in units:
  if s.endswith(k): print(int(float(s[:-len(k)])*v)); break
else: print(0)
" 2>/dev/null || echo 0)
        echo "$ts,$cpu,$mem" >> "$out"
      fi
      sleep 1
    done
  ) &
  STATS_PID=$!
}

stop_stats_sampler() {
  if [[ -n "${STATS_PID:-}" ]]; then
    kill "$STATS_PID" 2>/dev/null || true
    wait "$STATS_PID" 2>/dev/null || true
    STATS_PID=""
  fi
}

# --- Run one variant ---
run_variant() {
  local variant="$1"   # jvm | native
  local image="petclinic:${variant}"
  local cname="petclinic-${variant}"

  log "=== Variant: $variant ==="
  ensure_image "$image"

  # Record image size
  docker image inspect "$image" --format '{{.Size}}' > "$RESULTS_DIR/${variant}-image-size-bytes.txt"
  log "$variant image size: $(cat "$RESULTS_DIR/${variant}-image-size-bytes.txt") bytes"

  reset_db

  # Mount log dir to capture GC log (JVM only — entrypoint writes /var/log/petclinic/gc.log)
  local extra_mounts=()
  local gc_host_dir="$RESULTS_DIR/${variant}-gc"
  rm -rf "$gc_host_dir"; mkdir -p "$gc_host_dir"
  if [[ "$variant" == "jvm" ]]; then
    extra_mounts+=("-v" "$gc_host_dir:/var/log/petclinic")
  fi

  docker rm -f "$cname" 2>/dev/null || true

  local start_ts ready_ts startup_ms
  start_ts=$(date +%s%N)

  docker run -d \
    --name "$cname" \
    --network host \
    --memory "$APP_MEMORY" \
    --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE=postgres \
    -e POSTGRES_URL=jdbc:postgresql://localhost:5432/petclinic \
    -e POSTGRES_USER=petclinic \
    -e POSTGRES_PASS=petclinic \
    "${extra_mounts[@]}" \
    "$image" >/dev/null

  log "Waiting for $variant to become healthy..."
  local timeout=180
  for i in $(seq 1 "$timeout"); do
    if curl -sf http://localhost:${APP_PORT}/actuator/health >/dev/null 2>&1; then
      ready_ts=$(date +%s%N)
      startup_ms=$(( (ready_ts - start_ts) / 1000000 ))
      echo "$startup_ms" > "$RESULTS_DIR/${variant}-startup-ms.txt"
      log "$variant healthy after ${startup_ms}ms"
      break
    fi
    sleep 1
  done
  if [[ -z "${ready_ts:-}" ]]; then
    echo "ERROR: $variant did not become healthy in ${timeout}s"
    docker logs "$cname" --tail 80
    return 5
  fi

  # Start stats sampler
  start_stats_sampler "$cname" "$RESULTS_DIR/${variant}-stats.csv"

  # Run k6 mixed workload
  log "Running k6 ($DURATION, $VUS_TOTAL VUs total)..."
  docker run --rm --network host \
    --user "$(id -u):$(id -g)" \
    -v "$BENCHMARK_DIR/k6:/scripts:ro" \
    -v "$RESULTS_DIR:/out" \
    -e BASE_URL="http://localhost:${APP_PORT}" \
    -e DURATION="$DURATION" \
    -e VUS_TOTAL="$VUS_TOTAL" \
    grafana/k6:latest run \
    --out "csv=/out/${variant}-k6-results.csv" \
    --summary-export="/out/${variant}-k6-summary.json" \
    /scripts/mixed-workload.js \
    2>&1 | tee "$RESULTS_DIR/${variant}-k6-output.txt"

  stop_stats_sampler

  # Snapshot final memory
  docker stats "$cname" --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' \
    > "$RESULTS_DIR/${variant}-stats-after.txt" || true

  # GC log capture
  if [[ "$variant" == "jvm" ]]; then
    # Already written by mounted volume; just confirm
    if compgen -G "$gc_host_dir/gc.log*" > /dev/null; then
      log "GC log: $(ls $gc_host_dir/)"
    else
      log "WARN: no GC log found at $gc_host_dir"
    fi
  fi

  docker stop "$cname" >/dev/null
  docker rm "$cname" >/dev/null
  log "=== $variant done ==="
}

# --- Main ---
main() {
  require docker curl python3
  mkdir -p "$RESULTS_DIR"
  log "Profile: $PROFILE | Duration: $DURATION | VUs: $VUS_TOTAL | Variant: $VARIANT"
  log "Results dir: $RESULTS_DIR"

  build_images
  start_postgres

  # Expand the convenience aliases.
  local variants_to_run
  case "$VARIANT" in
    both) variants_to_run="jvm native";;
    all)  variants_to_run="jvm native native-pgo";;
    *)    variants_to_run="$VARIANT";;
  esac

  local first=1
  for v in $variants_to_run; do
    if [[ $first -eq 0 ]]; then sleep 10; fi
    run_variant "$v"
    first=0
  done

  if [[ "${SKIP_COLD_START:-0}" != "1" ]]; then
    log "Cold-start-under-load phase..."
    "$SCRIPT_DIR/cold-start-under-load.sh" "$VARIANT" || log "WARN: cold-start phase failed"
  fi

  log "All runs complete. Generating charts..."
  if [[ -f "$SCRIPT_DIR/charts.py" ]]; then
    local py
    if [[ -x "$BENCHMARK_DIR/.venv/bin/python" ]]; then
      py="$BENCHMARK_DIR/.venv/bin/python"
    else
      log "Creating venv at $BENCHMARK_DIR/.venv (one-time)..."
      python3 -m venv "$BENCHMARK_DIR/.venv" \
        && "$BENCHMARK_DIR/.venv/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt" \
        && py="$BENCHMARK_DIR/.venv/bin/python" \
        || { log "WARN: venv setup failed, skipping charts"; py=""; }
    fi
    if [[ -n "$py" ]]; then
      "$py" "$SCRIPT_DIR/charts.py" "$RESULTS_DIR" || log "WARN: chart gen failed"
    fi
  fi

  "$SCRIPT_DIR/generate-report.sh" "$RESULTS_DIR" || true

  log "Done. Results: $RESULTS_DIR"
}

main "$@"
