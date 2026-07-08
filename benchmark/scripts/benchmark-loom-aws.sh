#!/usr/bin/env bash
# Virtual-thread (Project Loom) benchmark AWS orchestrator.
#
# Architecture (reuses the v2 Terraform stack):
#   app EC2 (c7i.large)  — petclinic:jvm + co-located async slow-HTTP stub (localhost:9090)
#   k6  EC2 (c5.large)   — k6 load generator, sweeps concurrency levels
#   RDS Postgres         — provides a live JDBC pool for the /api/slow-db pool story
#
# Same image, thread mode toggled by config only (spring.threads.virtual.enabled).
# Combinations run:
#   slow     : platform vs virtual  x  concurrency sweep   (the clean thread crossover)
#   slow-db  : virtual, Hikari 10 vs 100  x  sweep         (pool becomes the bottleneck)
#   cpu      : platform vs virtual  x  sweep               (Loom does NOT help — honest case)
#
# Usage:
#   AWS_PROFILE=<your-aws-profile> ./benchmark/scripts/benchmark-loom-aws.sh
#
# Env overrides:
#   AWS_REGION, SSH_KEY, ENDPOINTS, LEVELS, DURATION, MS, ITERS
#   SKIP_BUILD=1  -- reuse petclinic:jvm already in ECR
#   KEEP_INFRA=1  -- leave EC2+RDS up after the run (else auto-destroyed, even on failure)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
TF_DIR="$BENCHMARK_DIR/terraform"
RESULTS_DIR="$BENCHMARK_DIR/results/aws-loom"

AWS_REGION="${AWS_REGION:-eu-central-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"
ENDPOINTS="${ENDPOINTS:-slow slow-db cpu}"
LEVELS="${LEVELS:-50 100 200 500 1000 2000}"
DURATION="${DURATION:-60s}"
MS="${MS:-200}"
ITERS="${ITERS:-2000000}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ServerAliveInterval=60"

export AWS_PROFILE AWS_REGION
log() { echo "[$(date '+%H:%M:%S')] $*"; }

preflight() {
  log "Pre-flight (profile=$AWS_PROFILE region=$AWS_REGION)..."
  for cmd in docker terraform aws jq scp ssh; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd missing"; exit 1; }
  done
  aws sts get-caller-identity >/dev/null || { echo "ERROR: AWS not configured"; exit 1; }
  docker info >/dev/null || { echo "ERROR: docker daemon not running"; exit 1; }
  [[ -f "${SSH_KEY}.pub" ]] || { echo "ERROR: SSH key ${SSH_KEY}.pub missing"; exit 1; }
}

tf_apply() {
  log "Provisioning v2 infra (loom run)..."
  cd "$TF_DIR"; terraform init -input=false >/dev/null
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" terraform apply -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}
tf_output() { cd "$TF_DIR"; terraform output -raw "$1"; cd "$PROJECT_ROOT"; }
tf_destroy() {
  log "Destroying infra..."
  cd "$TF_DIR"
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" terraform destroy -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}

build_and_push() {
  local ecr_url="$1"
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then log "SKIP_BUILD=1 — reusing petclinic:jvm in ECR"; return; fi
  log "Building petclinic:jvm..."
  local DOCKER_DIR="$BENCHMARK_DIR/docker"
  cp "$DOCKER_DIR/.dockerignore" "$PROJECT_ROOT/.dockerignore"
  docker build -f "$DOCKER_DIR/Dockerfile.jvm" -t petclinic:jvm "$PROJECT_ROOT"
  rm -f "$PROJECT_ROOT/.dockerignore"
  log "Pushing to ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ecr_url"
  docker tag petclinic:jvm "${ecr_url}:jvm"
  docker push "${ecr_url}:jvm"
}

wait_for_user_data() {
  local ip="$1" label="$2"
  log "Waiting for $label ($ip) user-data..."
  for i in $(seq 1 120); do
    ssh $SSH_OPTS -o ConnectTimeout=5 "ubuntu@${ip}" "test -f /tmp/user-data-done" 2>/dev/null \
      && { log "$label ready (~${i}×5s)"; return 0; }
    sleep 5
  done
  echo "ERROR: $label EC2 not ready in 10 min"; return 1
}

deploy_scripts() {
  local app_ip="$1" k6_ip="$2"
  log "Deploying app-side script + slow-stub to app EC2..."
  scp $SSH_OPTS "$SCRIPT_DIR/loom-app-on-ec2.sh" "ubuntu@${app_ip}:/tmp/loom-app-on-ec2.sh"
  scp $SSH_OPTS "$BENCHMARK_DIR/loom/slow-stub.py" "ubuntu@${app_ip}:/tmp/slow-stub.py"
  ssh $SSH_OPTS "ubuntu@${app_ip}" "chmod +x /tmp/loom-app-on-ec2.sh"
  log "Deploying k6 script + workload to k6 EC2..."
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "mkdir -p /tmp/k6"
  scp $SSH_OPTS "$BENCHMARK_DIR/k6/loom-workload.js" "ubuntu@${k6_ip}:/tmp/k6/loom-workload.js"
  scp $SSH_OPTS "$SCRIPT_DIR/loom-k6-on-ec2.sh" "ubuntu@${k6_ip}:/tmp/loom-k6-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "chmod +x /tmp/loom-k6-on-ec2.sh"
}

# printf %q preserves empty positional args across ssh (see cache orchestrator note).
app_run() { ssh $SSH_OPTS "ubuntu@${APP_IP}" "sudo -n /tmp/loom-app-on-ec2.sh $(printf '%q ' "$@")"; }
k6_run()  { ssh $SSH_OPTS "ubuntu@${K6_IP}"  "/tmp/loom-k6-on-ec2.sh $(printf '%q ' "$@")"; }

# One (endpoint, mode, hikari) combination: start app, sweep levels from k6, stop app.
run_combo() {
  local endpoint="$1" mode="$2" hikari="$3" tag="$4" iters_or_ms="$5"
  log "=== combo: $tag (endpoint=$endpoint mode=$mode hikari=$hikari) ==="
  app_run start "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" "$mode" "$hikari" "$tag"
  k6_run run "$APP_PRIVATE_IP" "$AWS_REGION" "$S3_BUCKET" "$endpoint" "$MS" "$ITERS" "$tag" "$LEVELS" "$DURATION" \
    || log "WARN: k6 $tag exited non-zero — continuing"
  app_run stop "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" "$mode" "$hikari" "$tag" || true
  sleep 5
}

cleanup() {
  local rc=$?
  [[ $rc -eq 0 ]] && return
  log "ERROR: benchmark failed (exit $rc)."
  if [[ "${KEEP_INFRA:-0}" == "1" ]]; then
    log "KEEP_INFRA=1 — leaving infra up. Destroy: cd $TF_DIR && terraform destroy -auto-approve -var aws_region=$AWS_REGION"
  else
    log "Auto-destroying infra (KEEP_INFRA=1 to keep on failure)..."
    tf_destroy || log "WARN: auto-destroy failed — destroy manually: cd $TF_DIR && terraform destroy -auto-approve -var aws_region=$AWS_REGION"
  fi
}
trap cleanup EXIT

# ===== MAIN =====
log "=== PetClinic Virtual-Thread Benchmark (AWS v2 infra) ==="
log "Endpoints: $ENDPOINTS | Levels: $LEVELS | dur=$DURATION ms=$MS"
preflight
tf_apply

APP_IP=$(tf_output ec2_public_ip)
APP_PRIVATE_IP=$(tf_output ec2_private_ip)
K6_IP=$(tf_output k6_ec2_public_ip)
ECR_URL=$(tf_output ecr_repository_url)
S3_BUCKET=$(tf_output s3_bucket_name)
RDS_HOST=$(tf_output rds_address)

log "App EC2: $APP_IP (private $APP_PRIVATE_IP) | k6 EC2: $K6_IP | RDS: $RDS_HOST"

build_and_push "$ECR_URL"
wait_for_user_data "$APP_IP" "app"
wait_for_user_data "$K6_IP" "k6"
deploy_scripts "$APP_IP" "$K6_IP"

app_run start-infra "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET"

for endpoint in $ENDPOINTS; do
  case "$endpoint" in
    slow)
      run_combo slow platform 10 "slow-platform" "$MS"
      run_combo slow virtual  10 "slow-virtual"  "$MS"
      ;;
    slow-db)
      # Virtual threads only: threads are already cheap, so the pool is what caps throughput.
      run_combo slow-db virtual 10  "slowdb-h10"  "$MS"
      run_combo slow-db virtual 100 "slowdb-h100" "$MS"
      ;;
    cpu)
      run_combo cpu platform 10 "cpu-platform" "$ITERS"
      run_combo cpu virtual  10 "cpu-virtual"  "$ITERS"
      ;;
    *) log "WARN: unknown endpoint $endpoint — skipping";;
  esac
done

app_run stop-infra "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" || true

log "Uploading results to S3 (non-fatal)..."
app_run upload "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" || log "WARN: app upload failed"
k6_run  upload "$APP_PRIVATE_IP" "$AWS_REGION" "$S3_BUCKET" || log "WARN: k6 upload failed"

log "Downloading from S3 -> $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
aws s3 sync "s3://${S3_BUCKET}/loom-results/" "$RESULTS_DIR/" --region "$AWS_REGION"

python3 "$SCRIPT_DIR/loom-summarize.py" "$RESULTS_DIR" "$LEVELS" || log "WARN: summarize failed"

if [[ "${KEEP_INFRA:-0}" == "1" ]]; then
  log "KEEP_INFRA=1 — infra left up. Destroy: cd $TF_DIR && terraform destroy -auto-approve -var aws_region=$AWS_REGION"
else
  tf_destroy
fi
log "=== Loom benchmark complete === Results: $RESULTS_DIR"
