#!/usr/bin/env bash
# Produce a WARMED CRaC checkpoint and bake it into a restore image.
#
# Runs on the SAME host that will restore (local box or the app EC2) so the
# checkpoint captures that host's native CPU features — no -XX:CPUFeatures=generic
# throughput tax, no cross-node illegal-instruction crash.
#
# Steps: warmup image -> throwaway Postgres -> run app + warm JIT + jcmd
# checkpoint -> layer crac-files onto the warmup image as the restore image.
#
# Env:
#   WARMUP_IMAGE   image with jar+jdk-crac+entrypoints (default petclinic:crac-warmup)
#   RESTORE_IMAGE  output restore image tag           (default petclinic:crac)
#   WARMUP_SECONDS JIT warm duration                  (default 90)
#   BUILD_WARMUP=1 build the warmup image from source first (needs source tree)
#   RESULTS_DIR    where to write checkpoint metrics   (default none)
#   EXTERNAL_DB_URL / EXTERNAL_DB_USER / EXTERNAL_DB_PASS
#                  warm against an existing DB instead of a throwaway one. Use
#                  this on AWS pointing at RDS so the baked JDBC URL matches the
#                  restore target (CRaC bakes the URL; only creds are re-read in
#                  afterRestore). The warmup container then runs on the host
#                  network to reach RDS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
DOCKER_DIR="$BENCHMARK_DIR/docker"

WARMUP_IMAGE="${WARMUP_IMAGE:-petclinic:crac-warmup}"
RESTORE_IMAGE="${RESTORE_IMAGE:-petclinic:crac}"
WARMUP_SECONDS="${WARMUP_SECONDS:-90}"
PG_IMAGE="${PG_IMAGE:-postgres:18.3}"
NET="crac-checkpoint-net"
PG_NAME="crac-checkpoint-pg"
WARM_NAME="crac-checkpoint-warm"
RESULTS_DIR="${RESULTS_DIR:-}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
metric() { [[ -n "$RESULTS_DIR" ]] && { mkdir -p "$RESULTS_DIR"; echo "$2" > "$RESULTS_DIR/$1"; } || true; }

cleanup() {
  docker rm -f "$WARM_NAME" "$PG_NAME" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- optional: build the warmup image from source ---
if [[ "${BUILD_WARMUP:-0}" == "1" ]]; then
  log "Building warmup image $WARMUP_IMAGE from source..."
  cp "$DOCKER_DIR/.dockerignore" "$PROJECT_ROOT/.dockerignore"
  local_start=$(date +%s)
  docker build -f "$DOCKER_DIR/Dockerfile.crac-warmup" -t "$WARMUP_IMAGE" "$PROJECT_ROOT"
  metric "crac-warmup-build-s.txt" "$(( $(date +%s) - local_start ))"
  rm -f "$PROJECT_ROOT/.dockerignore"
fi

# --- DB for warmup ---
NET_ARGS=()
if [[ -n "${EXTERNAL_DB_URL:-}" ]]; then
  # Warm against an existing DB (e.g. RDS). Host network so the URL resolves the
  # same way the restore container will resolve it.
  log "Warming against external DB: $EXTERNAL_DB_URL"
  DB_URL="$EXTERNAL_DB_URL"
  DB_USER="${EXTERNAL_DB_USER:-petclinic}"
  DB_PASS="${EXTERNAL_DB_PASS:-petclinic}"
  NET_ARGS=(--network host)
else
  # throwaway Postgres (real secrets are read at restore, not here)
  docker network create "$NET" >/dev/null 2>&1 || true
  docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
  log "Starting throwaway Postgres for warmup..."
  docker run -d --name "$PG_NAME" --network "$NET" \
    -e POSTGRES_DB=petclinic -e POSTGRES_USER=petclinic -e POSTGRES_PASSWORD=petclinic \
    "$PG_IMAGE" >/dev/null
  for i in $(seq 1 30); do
    docker exec "$PG_NAME" pg_isready -U petclinic >/dev/null 2>&1 && { log "Postgres ready (${i}s)"; break; }
    sleep 1
  done
  DB_URL="jdbc:postgresql://${PG_NAME}:5432/petclinic"
  DB_USER=petclinic
  DB_PASS=petclinic
  NET_ARGS=(--network "$NET")
fi

# --- warm + checkpoint ---
rm -rf "$PROJECT_ROOT/crac-files"; mkdir -p "$PROJECT_ROOT/crac-files"
log "Warming ($WARMUP_SECONDS s) then checkpointing..."
ckpt_start=$(date +%s.%3N)
docker rm -f "$WARM_NAME" >/dev/null 2>&1 || true
docker run --name "$WARM_NAME" "${NET_ARGS[@]}" \
  -e WARMUP_SECONDS="$WARMUP_SECONDS" \
  -e POSTGRES_URL="$DB_URL" \
  -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASS="$DB_PASS" \
  -v "$PROJECT_ROOT/crac-files:/crac-files" \
  "$WARMUP_IMAGE"
ckpt_end=$(date +%s.%3N)
metric "crac-checkpoint-create-s.txt" "$(awk "BEGIN{printf \"%.1f\", $ckpt_end-$ckpt_start}")"

if [[ -z "$(ls -A "$PROJECT_ROOT/crac-files" 2>/dev/null)" ]]; then
  log "ERROR: checkpoint image is empty — aborting"; exit 1
fi
ckpt_bytes=$(du -sb "$PROJECT_ROOT/crac-files" | cut -f1)
metric "crac-checkpoint-image-bytes.txt" "$ckpt_bytes"
log "Checkpoint image size: $(awk "BEGIN{printf \"%.0f MB\", $ckpt_bytes/1048576}")"

# --- bake restore image (layer crac-files onto the warmup image) ---
log "Building restore image $RESTORE_IMAGE..."
cp "$DOCKER_DIR/.dockerignore" "$PROJECT_ROOT/.dockerignore"
build_start=$(date +%s)
docker build -f "$DOCKER_DIR/Dockerfile.crac-restore-layer" \
  --build-arg "WARMUP_IMAGE=${WARMUP_IMAGE}" \
  -t "$RESTORE_IMAGE" "$PROJECT_ROOT"
metric "crac-restore-build-s.txt" "$(( $(date +%s) - build_start ))"
rm -f "$PROJECT_ROOT/.dockerignore"
docker image inspect "$RESTORE_IMAGE" --format '{{.Size}}' | tee >(cat >/dev/null)
metric "crac-image-size-bytes.txt" "$(docker image inspect "$RESTORE_IMAGE" --format '{{.Size}}')"

log "Done. Restore image: $RESTORE_IMAGE"
