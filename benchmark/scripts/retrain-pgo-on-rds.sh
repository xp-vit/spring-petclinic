#!/usr/bin/env bash
# Retrain PGO using a profile collected against the *production* topology
# (app EC2 + RDS over the network) instead of localhost-on-the-dev-box.
#
# Prereqs:
#   * v2 terraform stack still up; SSH key works.
#   * Oracle GraalVM 25 locally (sdk install java 25.0.3-graal).
#   * AWS_PROFILE pointing at the right account.
#
# Flow:
#   1. Stage 1 locally: nativeCompile --pgo-instrument -> instrumented binary
#   2. Wrap binary in petclinic:native-pgo-instrument image, push to ECR.
#   3. SSH app EC2: run instrumented container against RDS.
#   4. SSH k6 EC2: drive a 60-s mixed workload against the app's private IP.
#   5. SSH app EC2: graceful-stop container and docker-cp default.iprof out.
#   6. SCP iprof back to local.
#   7. Stage 3 locally: nativeCompile --pgo=<iprof> -march=x86-64-v3 (default GC/opt)
#   8. Re-tag as petclinic:native-pgo, push to ECR.
#   9. Re-run native-pgo phases on AWS (mixed + peak + cold-start), upload, download.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
TF_DIR="$BENCHMARK_DIR/terraform"
RESULTS_DIR="$BENCHMARK_DIR/results/aws-v2"

AWS_REGION="${AWS_REGION:-eu-central-1}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ServerAliveInterval=60"
INSTR_TAG="${INSTR_TAG:-native-pgo-instrument}"

log() { echo "[$(date '+%H:%M:%S')] [v3] $*"; }

# Resolve Oracle GraalVM (PGO requires it).
if [[ -z "${GRAALVM_HOME:-}" ]]; then
  for cand in "$HOME/.sdkman/candidates/java/25.0.3-graal" \
              "$HOME/.sdkman/candidates/java/current"; do
    [[ -x "$cand/bin/native-image" ]] && GRAALVM_HOME="$cand" && break
  done
fi
if ! "$GRAALVM_HOME/bin/native-image" --version 2>&1 | grep -q 'Oracle GraalVM'; then
  echo "ERROR: Oracle GraalVM 25 required for --pgo. Install:"
  echo "       sdk install java 25.0.3-graal"
  exit 2
fi
export JAVA_HOME="$GRAALVM_HOME"
export PATH="$GRAALVM_HOME/bin:$PATH"

# Pull terraform outputs.
cd "$TF_DIR"
APP_IP=$(terraform output -raw ec2_public_ip)
APP_PRIVATE_IP=$(terraform output -raw ec2_private_ip)
K6_IP=$(terraform output -raw k6_ec2_public_ip)
ECR_URL=$(terraform output -raw ecr_repository_url)
RDS_HOST=$(terraform output -raw rds_address)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
cd "$PROJECT_ROOT"

WORK_DIR="$(mktemp -d -t petclinic-pgo-v3-XXXXXX)"
log "Work dir: $WORK_DIR"
log "App EC2:    $APP_IP (private $APP_PRIVATE_IP)"
log "k6 EC2:     $K6_IP"
log "RDS:        $RDS_HOST"

cleanup() {
  if [[ -f "$PROJECT_ROOT/build.gradle.pgo-bak" ]]; then
    mv "$PROJECT_ROOT/build.gradle.pgo-bak" "$PROJECT_ROOT/build.gradle"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cp "$PROJECT_ROOT/build.gradle" "$PROJECT_ROOT/build.gradle.pgo-bak"
inject_args() {
  cp "$PROJECT_ROOT/build.gradle.pgo-bak" "$PROJECT_ROOT/build.gradle"
  cat >> "$PROJECT_ROOT/build.gradle" <<EOF

graalvmNative {
  binaries {
    main {
      buildArgs.addAll([$1])
    }
  }
}
EOF
}

# --- Stage 1: instrumented build ---
log "Stage 1: nativeCompile --pgo-instrument (~5 min)..."
inject_args "'--pgo-instrument'"
cd "$PROJECT_ROOT"
./gradlew nativeCompile -x test -x checkstyleMain -x checkstyleTest \
  -x checkstyleNohttp -x checkFormatMain -x checkFormatTest --no-daemon

INSTR_BIN="$PROJECT_ROOT/build/native/nativeCompile/spring-petclinic"
[[ -x "$INSTR_BIN" ]] || { echo "ERROR: no instrumented binary"; exit 3; }

# --- Stage 2: wrap + push ---
log "Stage 2: wrap into docker image and push as $INSTR_TAG..."
INSTR_BUILD_DIR="$WORK_DIR/img"
mkdir -p "$INSTR_BUILD_DIR"
cp "$INSTR_BIN" "$INSTR_BUILD_DIR/spring-petclinic"
cat > "$INSTR_BUILD_DIR/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
WORKDIR /app
COPY spring-petclinic ./spring-petclinic
EXPOSE 8080
# Default to writing the iprof in /app so we know where to docker cp from.
ENTRYPOINT ["./spring-petclinic"]
EOF
docker build -t petclinic:$INSTR_TAG "$INSTR_BUILD_DIR"

aws ecr get-login-password --region "$AWS_REGION" --profile "${AWS_PROFILE:-default}" | \
  docker login --username AWS --password-stdin "$ECR_URL"
docker tag petclinic:$INSTR_TAG "${ECR_URL}:${INSTR_TAG}"
docker push "${ECR_URL}:${INSTR_TAG}"

# --- Stage 3: training run on app EC2 ---
log "Stage 3: training run against RDS..."
ssh $SSH_OPTS ubuntu@${APP_IP} "sudo -n aws ecr get-login-password --region $AWS_REGION | \
  sudo -n docker login --username AWS --password-stdin $ECR_URL && \
  sudo -n docker pull ${ECR_URL}:${INSTR_TAG} && \
  sudo -n docker rm -f petclinic-pgo-instr 2>/dev/null || true; \
  sudo -n docker run -d --name petclinic-pgo-instr --network host \
    --memory 512m --cpus 1 \
    -e SPRING_PROFILES_ACTIVE=postgres \
    -e POSTGRES_URL=jdbc:postgresql://${RDS_HOST}:5432/petclinic \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    -w /app \
    ${ECR_URL}:${INSTR_TAG}"

log "Waiting for instrumented binary to be healthy..."
for i in $(seq 1 120); do
  ssh $SSH_OPTS ubuntu@${APP_IP} 'curl -sf http://localhost:8080/actuator/health' >/dev/null 2>&1 && break
  sleep 1
done

# Drive the training workload from k6 EC2 using the SAME script, VU count and
# endpoint mix (40/20/20/20) as the measured benchmark — this is what makes the
# PGO profile "correct": the optimizer sees the exact hot paths and branch
# frequencies of the workload we report on. 3 min (not 60 s) so cold paths get
# exercised and the profile has enough samples.
TRAIN_DURATION="${TRAIN_DURATION:-3m}"
log "Driving ${TRAIN_DURATION} of training workload (same mix as benchmark) from k6 EC2..."
ssh $SSH_OPTS ubuntu@${K6_IP} "DURATION=$TRAIN_DURATION VUS_TOTAL=50 k6 run \
  -e BASE_URL=http://${APP_PRIVATE_IP}:8080 \
  -e DURATION=$TRAIN_DURATION -e VUS_TOTAL=50 \
  /tmp/k6/mixed-workload.js >/dev/null 2>&1 || true"

# Graceful stop and copy out iprof. Signal from the HOST via `docker kill
# --signal` — the slim runtime image has no `kill` binary, so `docker exec kill`
# fails and the profile never flushes. SIGINT triggers Spring graceful shutdown,
# which lets Substrate VM write default.iprof to the working dir before exit.
log "Stopping instrumented container (host SIGINT -> flush default.iprof)..."
ssh $SSH_OPTS ubuntu@${APP_IP} "sudo -n docker kill --signal=SIGINT petclinic-pgo-instr 2>/dev/null || true; \
  for i in \$(seq 1 40); do \
    sudo -n docker inspect -f '{{.State.Running}}' petclinic-pgo-instr 2>/dev/null | grep -q false && break; \
    sleep 1; \
  done; \
  sudo -n docker kill --signal=SIGTERM petclinic-pgo-instr 2>/dev/null || true; \
  sleep 3; \
  sudo -n docker cp petclinic-pgo-instr:/app/default.iprof /tmp/default.iprof 2>&1 || \
  echo 'docker cp failed -- container may have already exited'; \
  sudo -n chmod 0644 /tmp/default.iprof 2>/dev/null || true"

scp $SSH_OPTS "ubuntu@${APP_IP}:/tmp/default.iprof" "$WORK_DIR/default.iprof"
ls -la "$WORK_DIR/default.iprof"

ssh $SSH_OPTS ubuntu@${APP_IP} "sudo -n docker rm -f petclinic-pgo-instr 2>/dev/null || true"

PROFILE="$WORK_DIR/default.iprof"
# Fail loud on an empty/missing profile. A 0-byte iprof means the SIGINT/SIGTERM
# flush failed and the "optimized" build would silently fall back to ML inference
# (or no profile) — producing a mislabelled result. Better to abort than lie.
PROFILE_BYTES=$( [[ -f "$PROFILE" ]] && wc -c < "$PROFILE" || echo 0 )
if [[ "${PROFILE_BYTES:-0}" -lt 1000 ]]; then
  echo "ERROR: PGO profile is empty or tiny (${PROFILE_BYTES} bytes). The instrumented"
  echo "       binary likely didn't flush default.iprof. Aborting — refusing to build"
  echo "       a 'native-pgo' image without a real profile."
  exit 6
fi
log "Profile collected: ${PROFILE_BYTES} bytes"

# --- Stage 4: optimized build ---
# Default GC (Serial) + default opt level so the only difference from the CE and
# ML native builds is the (correct) profile — controlled comparison.
log "Stage 4: nativeCompile --pgo=$PROFILE -march=x86-64-v3 (~5 min)..."
inject_args "'--pgo=${PROFILE}', '-march=x86-64-v3'"
cd "$PROJECT_ROOT"
./gradlew nativeCompile -x test -x checkstyleMain -x checkstyleTest \
  -x checkstyleNohttp -x checkFormatMain -x checkFormatTest --no-daemon

OPT_BIN="$PROJECT_ROOT/build/native/nativeCompile/spring-petclinic"
[[ -x "$OPT_BIN" ]] || { echo "ERROR: no optimized binary"; exit 5; }

# --- Stage 5: package + push as native-pgo ---
log "Stage 5: package + push as petclinic:native-pgo..."
OPT_DIR="$WORK_DIR/opt"
mkdir -p "$OPT_DIR"
cp "$OPT_BIN" "$OPT_DIR/spring-petclinic"
cat > "$OPT_DIR/Dockerfile" <<'EOF'
FROM debian:bookworm-slim
WORKDIR /app
COPY spring-petclinic ./spring-petclinic
EXPOSE 8080
ENTRYPOINT ["./spring-petclinic"]
EOF
docker build -t petclinic:native-pgo "$OPT_DIR"
docker tag petclinic:native-pgo "${ECR_URL}:native-pgo"
docker push "${ECR_URL}:native-pgo"

mv "$PROJECT_ROOT/build.gradle.pgo-bak" "$PROJECT_ROOT/build.gradle"

# --- Stage 6: re-run native-pgo benchmark on AWS ---
log "Stage 6: re-running native-pgo benchmark on existing v2 infra..."
ssh $SSH_OPTS ubuntu@${APP_IP} "sudo -n /tmp/app-on-ec2.sh start native-pgo $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET"
ssh $SSH_OPTS ubuntu@${K6_IP} "/tmp/k6-on-ec2.sh mixed native-pgo $APP_PRIVATE_IP $AWS_REGION $S3_BUCKET"
ssh $SSH_OPTS ubuntu@${APP_IP} "sudo -n /tmp/app-on-ec2.sh stop native-pgo $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET"

sleep 10
ssh $SSH_OPTS ubuntu@${APP_IP} "sudo -n /tmp/app-on-ec2.sh start native-pgo $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET"
ssh $SSH_OPTS ubuntu@${K6_IP} "/tmp/k6-on-ec2.sh peak native-pgo $APP_PRIVATE_IP $AWS_REGION $S3_BUCKET"
ssh $SSH_OPTS ubuntu@${APP_IP} "sudo -n /tmp/app-on-ec2.sh stop native-pgo $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET"

ssh $SSH_OPTS ubuntu@${APP_IP} "sudo -n /tmp/app-on-ec2.sh cold_start native-pgo $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET"

ssh $SSH_OPTS ubuntu@${APP_IP} "sudo -n /tmp/app-on-ec2.sh upload native-pgo $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET"
ssh $SSH_OPTS ubuntu@${K6_IP} "/tmp/k6-on-ec2.sh upload native-pgo 0 $AWS_REGION $S3_BUCKET"

log "Downloading refreshed native-pgo results..."
aws s3 sync "s3://${S3_BUCKET}/results/" "$RESULTS_DIR/" --region "$AWS_REGION" >/dev/null

# Regenerate charts + steady-state report.
if [[ -x "$BENCHMARK_DIR/.venv/bin/python" ]]; then
  "$BENCHMARK_DIR/.venv/bin/python" "$SCRIPT_DIR/charts.py" "$RESULTS_DIR"
fi
"$SCRIPT_DIR/generate-report.sh" "$RESULTS_DIR" || true

log "=== v3 PGO retrain + measure complete ==="
