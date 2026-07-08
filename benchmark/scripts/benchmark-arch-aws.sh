#!/usr/bin/env bash
# CPU-architecture price/performance benchmark: Intel vs AMD vs AWS Graviton.
#
# Same real Spring PetClinic app (identical multi-arch image, identical JDK bytecode) run on
# same-rank c7 instances across three CPU vendors, driven by two CPU-bound endpoints:
#   synthetic : GET /api/cpu?iters=N      -- pure compute floor (raw ISA/JIT delta)
#   real      : GET /api/render?rows=N    -- real Spring MVC + Jackson JSON serialize hot path
# The database (RDS) is OFF the instance under test and identical for every vendor, so the
# CPU on the app box -- not the DB or network -- is what saturates. We verify that per run.
#
# Vendors (same size 2 vCPU / 4 GB, compute-optimized c7):
#   c7i.large  Intel Sapphire Rapids  (amd64)
#   c7a.large  AMD 4th-gen EPYC       (amd64)
#   c7g.large  AWS Graviton3          (arm64)
#
# Architecture (reuses the v2 Terraform stack + loom EC2 scripts):
#   * RDS Postgres (db.m7i.large) and the k6 EC2 (c5.large) are provisioned ONCE and shared
#     across all vendors -- identical DB, identical load generator.
#   * The app instance (aws_instance.benchmark) is REPLACED for each vendor via
#     -var instance_type / -var app_arch and -replace, so every vendor gets a uniform fresh
#     instance lifecycle (user-data re-runs, tooling identical).
#   * Same ECR multi-arch image tag :jvm -- docker pull auto-selects amd64 or arm64.
#
# Per (vendor, endpoint) the app is started once (warm JVM) and the k6 concurrency sweep is
# repeated RUNS times so we can report median + range, not a single run.
#
# Usage:
#   AWS_PROFILE=<your-aws-profile> ./benchmark/scripts/benchmark-arch-aws.sh
#
# Env overrides:
#   AWS_REGION, SSH_KEY, RUNS, LEVELS, DURATION, ITERS, ROWS, VENDORS
#   SKIP_BUILD=1  -- reuse the multi-arch petclinic:jvm already in ECR
#   KEEP_INFRA=1  -- leave EC2+RDS up after the run (else auto-destroyed, even on failure)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
TF_DIR="$BENCHMARK_DIR/terraform"
RESULTS_DIR="$BENCHMARK_DIR/results/aws-arch"

AWS_REGION="${AWS_REGION:-eu-central-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"
RUNS="${RUNS:-5}"
# CPU-bound: throughput plateaus near the core count, so a short sweep that clearly reaches
# and holds saturation is enough. Peak sustained RPS per config feeds the price/perf chart.
LEVELS="${LEVELS:-10 20 50 100 200}"
DURATION="${DURATION:-45s}"
ITERS="${ITERS:-2000000}"     # synthetic /api/cpu work per request
ROWS="${ROWS:-400}"           # real /api/render owner rows per request (each has 3 pets)
# vendor spec: "instance_type:app_arch:tag"
VENDORS="${VENDORS:-c7i.large:amd64:c7i c7a.large:amd64:c7a c7g.large:arm64:c7g}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ServerAliveInterval=60"

export AWS_PROFILE AWS_REGION
log() { echo "[$(date '+%H:%M:%S')] $*"; }

preflight() {
  log "Pre-flight (profile=$AWS_PROFILE region=$AWS_REGION)..."
  for cmd in docker terraform aws jq scp ssh; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd missing"; exit 1; }
  done
  docker buildx version >/dev/null 2>&1 || { echo "ERROR: docker buildx missing"; exit 1; }
  aws sts get-caller-identity >/dev/null || { echo "ERROR: AWS not configured"; exit 1; }
  docker info >/dev/null || { echo "ERROR: docker daemon not running"; exit 1; }
  [[ -f "${SSH_KEY}.pub" ]] || { echo "ERROR: SSH key ${SSH_KEY}.pub missing"; exit 1; }
}

# Build the arch-independent fat jar once on the host, then buildx a single multi-arch
# manifest (amd64 + arm64) and push it to ECR as :jvm. No compile happens under emulation --
# the jar is prebuilt, so both arches are just a JRE-base layer copy.
build_and_push() {
  local ecr_url="$1"
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then log "SKIP_BUILD=1 -- reusing multi-arch petclinic:jvm in ECR"; return; fi

  log "Building fat jar on host (./gradlew bootJar)..."
  ( cd "$PROJECT_ROOT" && ./gradlew bootJar -x test -x checkstyleMain -x checkstyleTest \
      -x checkstyleNohttp -x checkFormatMain -x checkFormatTest --no-daemon )
  local jar; jar=$(ls -1 "$PROJECT_ROOT"/build/libs/*.jar | grep -v plain | head -1)
  [[ -f "$jar" ]] || { echo "ERROR: bootJar not found"; exit 1; }

  # Stage a minimal build context (jar + Dockerfile) so the project .dockerignore -- which
  # excludes build/ -- does not hide the jar.
  local ctx; ctx="$(mktemp -d)"
  cp "$jar" "$ctx/app.jar"
  cp "$BENCHMARK_DIR/docker/Dockerfile.arch" "$ctx/Dockerfile"

  log "Ensuring arm64 emulation (binfmt) + a docker-container buildx builder..."
  docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 || \
    log "WARN: binfmt install skipped (may already be present)"
  docker buildx inspect archbuilder >/dev/null 2>&1 || \
    docker buildx create --name archbuilder --driver docker-container >/dev/null
  docker buildx use archbuilder

  log "ECR login + multi-arch buildx push (linux/amd64,linux/arm64 -> ${ecr_url}:jvm)..."
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ecr_url"
  docker buildx build --platform linux/amd64,linux/arm64 \
    -t "${ecr_url}:jvm" --push "$ctx"
  docker buildx use default
  rm -rf "$ctx"
}

# --- Terraform (RDS + k6 provisioned once; app instance replaced per vendor) ---
tf_init() { cd "$TF_DIR"; terraform init -input=false >/dev/null; cd "$PROJECT_ROOT"; }
tf_apply_vendor() {
  local type="$1" arch="$2"
  log "Terraform apply: app=$type arch=$arch (RDS+k6 unchanged, app instance replaced)..."
  cd "$TF_DIR"
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" terraform apply -auto-approve \
    -var "aws_region=$AWS_REGION" -var "instance_type=$type" -var "app_arch=$arch" \
    -replace=aws_instance.benchmark
  cd "$PROJECT_ROOT"
}
tf_output() { cd "$TF_DIR"; terraform output -raw "$1"; cd "$PROJECT_ROOT"; }
tf_destroy() {
  log "Destroying infra..."
  cd "$TF_DIR"
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" terraform destroy -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}

wait_for_user_data() {
  local ip="$1" label="$2"
  log "Waiting for $label ($ip) user-data..."
  for i in $(seq 1 120); do
    ssh $SSH_OPTS -o ConnectTimeout=5 "ubuntu@${ip}" "test -f /tmp/user-data-done" 2>/dev/null \
      && { log "$label ready (~${i}x5s)"; return 0; }
    sleep 5
  done
  echo "ERROR: $label EC2 not ready in 10 min"; return 1
}

deploy_app_scripts() {
  local app_ip="$1"
  log "Deploying app-side script + slow-stub to app EC2 ($app_ip)..."
  scp $SSH_OPTS "$SCRIPT_DIR/loom-app-on-ec2.sh" "ubuntu@${app_ip}:/tmp/loom-app-on-ec2.sh"
  scp $SSH_OPTS "$BENCHMARK_DIR/loom/slow-stub.py" "ubuntu@${app_ip}:/tmp/slow-stub.py"
  ssh $SSH_OPTS "ubuntu@${app_ip}" "chmod +x /tmp/loom-app-on-ec2.sh"
}
deploy_k6_scripts() {
  local k6_ip="$1"
  log "Deploying k6 script + workload to k6 EC2 ($k6_ip)..."
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "mkdir -p /tmp/k6"
  scp $SSH_OPTS "$BENCHMARK_DIR/k6/loom-workload.js" "ubuntu@${k6_ip}:/tmp/k6/loom-workload.js"
  scp $SSH_OPTS "$SCRIPT_DIR/loom-k6-on-ec2.sh" "ubuntu@${k6_ip}:/tmp/loom-k6-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "chmod +x /tmp/loom-k6-on-ec2.sh"
}

# printf %q preserves empty positional args across ssh (see cache orchestrator note).
app_run() { ssh $SSH_OPTS "ubuntu@${APP_IP}" "sudo -n /tmp/loom-app-on-ec2.sh $(printf '%q ' "$@")"; }
k6_run()  { ssh $SSH_OPTS "ubuntu@${K6_IP}"  "/tmp/loom-k6-on-ec2.sh $(printf '%q ' "$@")"; }

# One (vendor, endpoint): start app once (warm JVM), repeat the k6 sweep RUNS times.
run_endpoint() {
  local endpoint="$1" vtag="$2" work="$3"   # work = iters (cpu) or rows (render)
  local base_tag="${endpoint}-${vtag}"
  log "=== $base_tag : start app (mode=platform), warm JVM, ${RUNS} runs ==="
  # mode=platform, hikari=10 (unused here -- no DB path). TAG drives appstats/startup files.
  app_run start "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" platform 10 "$base_tag"
  for r in $(seq 1 "$RUNS"); do
    local tag="${base_tag}-r${r}"
    log "--- $tag (endpoint=$endpoint work=$work) ---"
    if [[ "$endpoint" == "cpu" ]]; then
      k6_run run "$APP_PRIVATE_IP" "$AWS_REGION" "$S3_BUCKET" cpu 200 "$work" "$tag" "$LEVELS" "$DURATION" 400 \
        || log "WARN: k6 $tag non-zero -- continuing"
    else
      k6_run run "$APP_PRIVATE_IP" "$AWS_REGION" "$S3_BUCKET" render 200 2000000 "$tag" "$LEVELS" "$DURATION" "$work" \
        || log "WARN: k6 $tag non-zero -- continuing"
    fi
  done
  app_run stop "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" platform 10 "$base_tag" || true
  sleep 3
}

cleanup() {
  local rc=$?
  [[ $rc -eq 0 ]] && return
  log "ERROR: benchmark failed (exit $rc)."
  if [[ "${KEEP_INFRA:-0}" == "1" ]]; then
    log "KEEP_INFRA=1 -- leaving infra up. Destroy: cd $TF_DIR && terraform destroy -auto-approve -var aws_region=$AWS_REGION"
  else
    log "Auto-destroying infra..."
    tf_destroy || log "WARN: auto-destroy failed -- destroy manually: cd $TF_DIR && terraform destroy -auto-approve -var aws_region=$AWS_REGION"
  fi
}
trap cleanup EXIT

# ===== MAIN =====
log "=== PetClinic CPU-Arch Price/Perf Benchmark (Intel vs AMD vs Graviton) ==="
log "Vendors: $VENDORS | Levels: $LEVELS | runs=$RUNS dur=$DURATION iters=$ITERS rows=$ROWS"
preflight
tf_init

FIRST=1
K6_DEPLOYED=0
for spec in $VENDORS; do
  IFS=':' read -r VTYPE VARCH VTAG <<<"$spec"
  log "############ VENDOR $VTAG ($VTYPE / $VARCH) ############"
  tf_apply_vendor "$VTYPE" "$VARCH"

  APP_IP=$(tf_output ec2_public_ip)
  APP_PRIVATE_IP=$(tf_output ec2_private_ip)
  K6_IP=$(tf_output k6_ec2_public_ip)
  ECR_URL=$(tf_output ecr_repository_url)
  S3_BUCKET=$(tf_output s3_bucket_name)
  RDS_HOST=$(tf_output rds_address)
  log "App EC2: $APP_IP (private $APP_PRIVATE_IP) | k6 EC2: $K6_IP | RDS: $RDS_HOST"

  # Build+push the multi-arch image once (after the first stack exists so ECR repo is up).
  if [[ "$FIRST" == "1" ]]; then build_and_push "$ECR_URL"; FIRST=0; fi

  wait_for_user_data "$APP_IP" "app-$VTAG"
  if [[ "$K6_DEPLOYED" == "0" ]]; then wait_for_user_data "$K6_IP" "k6"; deploy_k6_scripts "$K6_IP"; K6_DEPLOYED=1; fi
  deploy_app_scripts "$APP_IP"

  app_run start-infra "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET"

  run_endpoint cpu    "$VTAG" "$ITERS"   # synthetic
  run_endpoint render "$VTAG" "$ROWS"    # real

  app_run stop-infra "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" || true
  log "Uploading $VTAG app results to S3..."
  app_run upload "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" || log "WARN: app upload failed ($VTAG)"
done

log "Uploading k6 results to S3..."
k6_run upload "$APP_PRIVATE_IP" "$AWS_REGION" "$S3_BUCKET" || log "WARN: k6 upload failed"

log "Downloading from S3 -> $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
aws s3 sync "s3://${S3_BUCKET}/loom-results/" "$RESULTS_DIR/" --region "$AWS_REGION"

python3 "$SCRIPT_DIR/arch-summarize.py" "$RESULTS_DIR" "$RUNS" "$LEVELS" || log "WARN: summarize failed"

if [[ "${KEEP_INFRA:-0}" == "1" ]]; then
  log "KEEP_INFRA=1 -- infra left up. Destroy: cd $TF_DIR && terraform destroy -auto-approve -var aws_region=$AWS_REGION"
else
  tf_destroy
fi
log "=== Arch benchmark complete === Results: $RESULTS_DIR"
