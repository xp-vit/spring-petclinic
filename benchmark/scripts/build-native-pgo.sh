#!/usr/bin/env bash
# Two-stage GraalVM Profile-Guided Optimization build.
#
#   1. Build instrumented native binary (./gradlew nativeCompile w/ --pgo-instrument).
#   2. Start it locally against Postgres (Docker), run a training workload
#      (curl loop hitting representative endpoints) for ~60 s.
#   3. Collect the default.iprof produced in the binary's working directory.
#   4. Re-build native with --pgo=<iprof> -O3 --gc=G1.
#   5. Wrap the optimized binary in a docker image: petclinic:native-pgo
#
# Requires GraalVM 25 toolchain locally (gradle auto-provisions via foojay).
# Total build time: ~12-15 min.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
DOCKER_DIR="$BENCHMARK_DIR/docker"
WORK_DIR="$(mktemp -d -t petclinic-pgo-XXXXXX)"
PG_NAME="petclinic-pgo-pg"

# Point gradle's toolchain at a GraalVM 25 install so `native-image` is present.
# We pick a sensible default and let the caller override with GRAALVM_HOME.
# PGO requires Oracle GraalVM (free under GFTC) — Community Edition doesn't
# ship --pgo / --pgo-instrument as of 25.0.2.  Prefer Oracle if present.
if [[ -z "${GRAALVM_HOME:-}" ]]; then
  for cand in \
      "$HOME/.sdkman/candidates/java/25.0.3-graal" \
      "$HOME/.sdkman/candidates/java/25.0.2-graal" \
      "$HOME/.sdkman/candidates/java/25.0.2-graalce" \
      "$HOME/.sdkman/candidates/java/current" \
      /usr/lib/jvm/graalvm-jdk-25 \
      /opt/graalvm-jdk-25; do
    if [[ -x "$cand/bin/native-image" ]]; then
      GRAALVM_HOME="$cand"; break
    fi
  done
fi
if [[ -z "${GRAALVM_HOME:-}" || ! -x "$GRAALVM_HOME/bin/native-image" ]]; then
  echo "ERROR: GraalVM 25 not found. Install Oracle GraalVM via:"
  echo "       sdk install java 25.0.3-graal"
  echo "       (PGO is not available in the Community Edition)"
  exit 2
fi
if ! "$GRAALVM_HOME/bin/native-image" --help 2>&1 | grep -q -- '--pgo '; then
  echo "ERROR: native-image at $GRAALVM_HOME doesn't support --pgo (CE?)."
  echo "       Install Oracle GraalVM: sdk install java 25.0.3-graal"
  exit 2
fi
export JAVA_HOME="$GRAALVM_HOME"
export PATH="$GRAALVM_HOME/bin:$PATH"
echo "[pgo] Using GraalVM at $GRAALVM_HOME"
"$GRAALVM_HOME/bin/native-image" --version | head -1 || true

log() { echo "[$(date '+%H:%M:%S')] [pgo] $*"; }

cleanup() {
  docker rm -f "$PG_NAME" petclinic-pgo-instr 2>/dev/null || true
  # restore build.gradle from backup if interrupted mid-edit
  if [[ -f "$PROJECT_ROOT/build.gradle.pgo-bak" ]]; then
    mv "$PROJECT_ROOT/build.gradle.pgo-bak" "$PROJECT_ROOT/build.gradle"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PGO_PROFILE="$WORK_DIR/default.iprof"

# --- Save current build.gradle ---
cp "$PROJECT_ROOT/build.gradle" "$PROJECT_ROOT/build.gradle.pgo-bak"

# --- Inject helper for native build args (idempotent) ---
inject_args() {
  local args="$1"  # comma-separated list of args, e.g. "'--pgo-instrument'"
  cp "$PROJECT_ROOT/build.gradle.pgo-bak" "$PROJECT_ROOT/build.gradle"
  cat >> "$PROJECT_ROOT/build.gradle" <<EOF

graalvmNative {
  binaries {
    main {
      buildArgs.addAll([${args}])
    }
  }
}
EOF
}

# --- Postgres for training ---
log "Starting training Postgres..."
docker rm -f "$PG_NAME" 2>/dev/null || true
docker run -d --name "$PG_NAME" --network host \
  -e POSTGRES_DB=petclinic -e POSTGRES_USER=petclinic -e POSTGRES_PASSWORD=petclinic \
  postgres:18.3 >/dev/null
for i in $(seq 1 30); do
  docker exec "$PG_NAME" pg_isready -U petclinic >/dev/null 2>&1 && break
  sleep 1
done

# --- Stage 1: instrumented build ---
log "Stage 1: nativeCompile --pgo-instrument (this takes ~5 min)..."
inject_args "'--pgo-instrument'"
cd "$PROJECT_ROOT"
./gradlew nativeCompile -x test -x checkstyleMain -x checkstyleTest \
  -x checkstyleNohttp -x checkFormatMain -x checkFormatTest --no-daemon

INSTR_BINARY="$PROJECT_ROOT/build/native/nativeCompile/spring-petclinic"
[[ -x "$INSTR_BINARY" ]] || { echo "ERROR: instrumented binary not found"; exit 4; }

# --- Stage 2: training run ---
log "Stage 2: training run (60 s of mixed workload)..."
mkdir -p "$WORK_DIR/run"
cd "$WORK_DIR/run"
SPRING_PROFILES_ACTIVE=postgres \
  POSTGRES_URL=jdbc:postgresql://localhost:5432/petclinic \
  POSTGRES_USER=petclinic POSTGRES_PASS=petclinic \
  "$INSTR_BINARY" > "$WORK_DIR/instr.log" 2>&1 &
APP_PID=$!

for i in $(seq 1 120); do
  if curl -sf http://localhost:8080/actuator/health >/dev/null 2>&1; then
    log "instrumented binary healthy after ${i}s"; break
  fi
  sleep 1
done

# 60 s of mixed traffic, single thread
log "Driving training workload for 60 s..."
end=$(( $(date +%s) + 60 ))
while [[ $(date +%s) -lt $end ]]; do
  curl -s -o /dev/null "http://localhost:8080/owners?lastName=Davis" || true
  curl -s -o /dev/null "http://localhost:8080/owners/$(( RANDOM % 10 + 1 ))" || true
  curl -s -o /dev/null -H "Accept: application/json" "http://localhost:8080/vets" || true
  curl -s -o /dev/null -X POST -d "firstName=A&lastName=B&address=X&city=Y&telephone=1234567890" \
    "http://localhost:8080/owners/new" || true
done

log "Stopping instrumented binary..."
# SIGINT alone sometimes hangs the binary in this build; chase with SIGTERM
# after a short grace period to ensure the profile writer flushes and exits.
kill -INT "$APP_PID" 2>/dev/null || true
for _ in $(seq 1 30); do
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$APP_PID" 2>/dev/null; then
  log "  binary still alive after 30s; sending SIGTERM"
  kill -TERM "$APP_PID" 2>/dev/null || true
fi
wait "$APP_PID" 2>/dev/null || true

cp "$WORK_DIR/run/default.iprof" "$PGO_PROFILE"
log "Profile collected: $(wc -c < "$PGO_PROFILE") bytes"

# --- Stage 3: optimized build ---
# -march=x86-64-v3 gives an Intel/AMD-compatible AVX2 baseline (Haswell+).
# We intentionally do NOT use -march=native because the dev box may differ
# from the deployment target (e.g. AMD Zen build, Intel c7i runtime).
log "Stage 3: nativeCompile --pgo=$PGO_PROFILE -O3 --gc=G1 -march=x86-64-v3 (this takes ~5 min)..."
inject_args "'--pgo=${PGO_PROFILE}', '-O3', '--gc=G1', '-march=x86-64-v3'"
cd "$PROJECT_ROOT"
./gradlew nativeCompile -x test -x checkstyleMain -x checkstyleTest \
  -x checkstyleNohttp -x checkFormatMain -x checkFormatTest --no-daemon

OPT_BINARY="$PROJECT_ROOT/build/native/nativeCompile/spring-petclinic"
[[ -x "$OPT_BINARY" ]] || { echo "ERROR: optimized binary not found"; exit 5; }

# --- Stage 4: wrap into docker image ---
log "Building petclinic:native-pgo docker image..."
PGO_BIN_DIR="$WORK_DIR/img"
mkdir -p "$PGO_BIN_DIR"
cp "$OPT_BINARY" "$PGO_BIN_DIR/spring-petclinic"
cat > "$PGO_BIN_DIR/Dockerfile" <<EOF
FROM debian:bookworm-slim
WORKDIR /app
COPY spring-petclinic ./spring-petclinic
EXPOSE 8080
ENTRYPOINT ["./spring-petclinic"]
EOF
docker build -t petclinic:native-pgo "$PGO_BIN_DIR"

# --- Restore build.gradle ---
mv "$PROJECT_ROOT/build.gradle.pgo-bak" "$PROJECT_ROOT/build.gradle"

docker stop "$PG_NAME" >/dev/null 2>&1 || true
docker rm "$PG_NAME" >/dev/null 2>&1 || true

log "=== Done. petclinic:native-pgo ready. ==="
docker images petclinic:native-pgo
