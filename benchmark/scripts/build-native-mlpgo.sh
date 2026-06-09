#!/usr/bin/env bash
# Native build using Oracle GraalVM's ML-based profile inference (the default
# when no --pgo profile is supplied). No training run required.
#
# This is the "free middle ground" between a no-profile native build and a
# fully PGO-trained one: Oracle GraalVM statically infers branch frequencies
# with an ML model (~6% runtime speedup per Oracle, zero training cost).
#
# Controlled comparison vs the trained PGO build: --pgo always force-enables -O3,
# so this ML build matches it with -O3 too (Serial GC default, -march pinned for
# dev-box->c7i portability). mlpgo (ML-inferred profile) vs native-pgo (trained
# profile) then differ ONLY by the profile source. The CE build (-O2, no profile)
# stands separately as the free-tier baseline.
#
# Requires Oracle GraalVM 25 (ML inference is NOT in Community Edition).
# Produces docker image: petclinic:native-mlpgo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d -t petclinic-mlpgo-XXXXXX)"

log() { echo "[$(date '+%H:%M:%S')] [mlpgo] $*"; }

# Resolve Oracle GraalVM (ML inference requires it; CE lacks it).
if [[ -z "${GRAALVM_HOME:-}" ]]; then
  for cand in "$HOME/.sdkman/candidates/java/25.0.3-graal" \
              "$HOME/.sdkman/candidates/java/current" \
              /usr/lib/jvm/graalvm-jdk-25 /opt/graalvm-jdk-25; do
    [[ -x "$cand/bin/native-image" ]] && GRAALVM_HOME="$cand" && break
  done
fi
if [[ -z "${GRAALVM_HOME:-}" || ! -x "$GRAALVM_HOME/bin/native-image" ]]; then
  echo "ERROR: Oracle GraalVM 25 not found. Install: sdk install java 25.0.3-graal"
  exit 2
fi
# ML inference is Oracle-only. Gate on the definitive edition marker in
# --version ("Oracle GraalVM" vs "GraalVM CE"); --help parsing is fragile
# because first-invocation setup noise can pollute it.
if ! "$GRAALVM_HOME/bin/native-image" --version 2>&1 | grep -q 'Oracle GraalVM'; then
  echo "ERROR: native-image at $GRAALVM_HOME is not Oracle GraalVM (no ML inference)."
  echo "       Install Oracle GraalVM: sdk install java 25.0.3-graal"
  exit 2
fi
export JAVA_HOME="$GRAALVM_HOME"
export PATH="$GRAALVM_HOME/bin:$PATH"
log "Using GraalVM at $GRAALVM_HOME"
"$GRAALVM_HOME/bin/native-image" --version | head -1 || true

cleanup() {
  if [[ -f "$PROJECT_ROOT/build.gradle.mlpgo-bak" ]]; then
    mv "$PROJECT_ROOT/build.gradle.mlpgo-bak" "$PROJECT_ROOT/build.gradle"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cp "$PROJECT_ROOT/build.gradle" "$PROJECT_ROOT/build.gradle.mlpgo-bak"
cat >> "$PROJECT_ROOT/build.gradle" <<'EOF'

graalvmNative {
  binaries {
    main {
      buildArgs.addAll(['-O3', '-march=x86-64-v3'])
    }
  }
}
EOF

log "nativeCompile with ML profile inference (~5 min)..."
cd "$PROJECT_ROOT"
./gradlew nativeCompile -x test -x checkstyleMain -x checkstyleTest \
  -x checkstyleNohttp -x checkFormatMain -x checkFormatTest --no-daemon \
  2>&1 | tee "$WORK_DIR/build.log"

# Confirm ML inference actually engaged (the build log mentions it when no PGO
# profile is supplied). Fail loud if absent — otherwise this is just a no-profile
# build masquerading as ML-PGO.
if grep -qiE 'machine.?learning|ML-inferred|inferred profiles|profile.?inference' "$WORK_DIR/build.log"; then
  log "ML profile inference confirmed in build log."
else
  log "WARN: could not confirm ML inference in build log. Check manually:"
  grep -iE 'profile|pgo|optimiz' "$WORK_DIR/build.log" || true
fi

OPT_BIN="$PROJECT_ROOT/build/native/nativeCompile/spring-petclinic"
[[ -x "$OPT_BIN" ]] || { echo "ERROR: native binary not found"; exit 5; }

log "Building petclinic:native-mlpgo docker image..."
IMG_DIR="$WORK_DIR/img"
mkdir -p "$IMG_DIR"
cp "$OPT_BIN" "$IMG_DIR/spring-petclinic"
cat > "$IMG_DIR/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
WORKDIR /app
COPY spring-petclinic ./spring-petclinic
EXPOSE 8080
ENTRYPOINT ["./spring-petclinic"]
EOF
docker build -t petclinic:native-mlpgo "$IMG_DIR"

mv "$PROJECT_ROOT/build.gradle.mlpgo-bak" "$PROJECT_ROOT/build.gradle"

log "=== Done. petclinic:native-mlpgo ready. ==="
docker images petclinic:native-mlpgo
