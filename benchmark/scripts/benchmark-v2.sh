#!/usr/bin/env bash
# v2 architecture orchestrator:
#   * app EC2 (c7i.large) — runs the variant container, connects to RDS
#   * k6  EC2 (c5.large)  — runs k6 against the app's private IP
#   * RDS Postgres (db.t3.micro) — managed DB, low-latency same-AZ
#
# Builds + pushes all variants to ECR, then for each variant:
#   1. SSH app EC2  : start container + stats sampler
#   2. SSH k6  EC2  : run k6 mixed-workload (10 min, 50 VUs)
#   3. SSH app EC2  : stop container
#   4. SSH app EC2  : start container fresh
#   5. SSH k6  EC2  : run k6 peak-RPS (5 min ramp)
#   6. SSH app EC2  : stop
#   7. SSH app EC2  : cold-start-under-load
# Then download results from S3, generate charts, destroy infra.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
TF_DIR="$BENCHMARK_DIR/terraform"
RESULTS_DIR="$BENCHMARK_DIR/results/aws-v2"

AWS_REGION="${AWS_REGION:-eu-central-1}"
VARIANTS="${VARIANTS:-jvm native}"   # space-separated; e.g. "jvm native native-pgo"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ServerAliveInterval=60"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Preflight ---
preflight() {
  log "Pre-flight checks..."
  for cmd in docker terraform aws jq scp ssh; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd missing"; exit 1; }
  done
  aws sts get-caller-identity >/dev/null || { echo "ERROR: AWS not configured"; exit 1; }
  docker info >/dev/null || { echo "ERROR: docker daemon not running"; exit 1; }
  [[ -f "$SSH_KEY.pub" ]] || { echo "ERROR: SSH key $SSH_KEY.pub missing"; exit 1; }
}

# --- Terraform ---
tf_apply() {
  log "Provisioning v2 infrastructure..."
  cd "$TF_DIR"
  terraform init -input=false >/dev/null
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" \
    terraform apply -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}

tf_output() {
  cd "$TF_DIR"
  terraform output -raw "$1"
  cd "$PROJECT_ROOT"
}

tf_destroy() {
  log "Destroying v2 infrastructure..."
  cd "$TF_DIR"
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" \
    terraform destroy -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}

# --- Build + push images ---
build_and_push() {
  local ecr_url="$1"
  log "Building images: $VARIANTS"
  for v in $VARIANTS; do
    case "$v" in
      jvm|native)
        "$SCRIPT_DIR/build.sh"
        break  # build.sh builds both jvm + native in one go
        ;;
    esac
  done
  if [[ "$VARIANTS" == *native-pgo* ]]; then
    "$SCRIPT_DIR/build-native-pgo.sh"
  fi

  log "Authenticating to ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ecr_url"
  for v in $VARIANTS; do
    log "Pushing $v..."
    docker tag "petclinic:${v}" "${ecr_url}:${v}"
    docker push "${ecr_url}:${v}"
  done
}

# --- Wait for EC2 user-data ---
wait_for_user_data() {
  local ip="$1" label="$2"
  log "Waiting for $label EC2 ($ip) user-data..."
  for i in $(seq 1 120); do
    if ssh $SSH_OPTS -o ConnectTimeout=5 "ubuntu@${ip}" "test -f /tmp/user-data-done" 2>/dev/null; then
      log "$label ready after ~${i}s"
      return 0
    fi
    sleep 5
  done
  echo "ERROR: $label EC2 not ready in 10 min"
  return 1
}

# --- Deploy scripts to EC2s ---
deploy_scripts() {
  local app_ip="$1" k6_ip="$2"
  log "Uploading app-side script..."
  scp $SSH_OPTS "$SCRIPT_DIR/app-on-ec2.sh" "ubuntu@${app_ip}:/tmp/app-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${app_ip}" "chmod +x /tmp/app-on-ec2.sh"

  log "Uploading load-side script + k6 workloads..."
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "mkdir -p /tmp/k6"
  scp $SSH_OPTS "$BENCHMARK_DIR/k6/"*.js "ubuntu@${k6_ip}:/tmp/k6/"
  scp $SSH_OPTS "$SCRIPT_DIR/k6-on-ec2.sh" "ubuntu@${k6_ip}:/tmp/k6-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "chmod +x /tmp/k6-on-ec2.sh"
}

# --- Run one variant ---
run_variant() {
  local variant="$1" app_ip="$2" k6_ip="$3" ecr_url="$4" rds_host="$5" s3_bucket="$6" app_private_ip="$7"
  log "=== Variant: $variant ==="

  # Phase A: mixed workload (10 min sustained)
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh start $variant $ecr_url $rds_host $AWS_REGION $s3_bucket mixed"
  ssh $SSH_OPTS "ubuntu@${k6_ip}" \
    "/tmp/k6-on-ec2.sh mixed $variant $app_private_ip $AWS_REGION $s3_bucket"
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh stop $variant $ecr_url $rds_host $AWS_REGION $s3_bucket mixed"

  sleep 10

  # Phase B: peak-RPS (5 min ramp, fresh container)
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh start $variant $ecr_url $rds_host $AWS_REGION $s3_bucket peak"
  # JIT warm-up burst for JVM
  if [[ "$variant" == "jvm" ]]; then
    ssh $SSH_OPTS "ubuntu@${k6_ip}" \
      "for _ in \$(seq 1 300); do curl -s -o /dev/null http://${app_private_ip}:8080/vets -H 'Accept: application/json' || true; sleep 0.1; done"
  fi
  ssh $SSH_OPTS "ubuntu@${k6_ip}" \
    "/tmp/k6-on-ec2.sh peak $variant $app_private_ip $AWS_REGION $s3_bucket"
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh stop $variant $ecr_url $rds_host $AWS_REGION $s3_bucket peak"

  # Phase C: cold-start under load (app-side only, loopback probe)
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh cold_start $variant $ecr_url $rds_host $AWS_REGION $s3_bucket"

  log "=== $variant done ==="
}

# --- Cleanup handler ---
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log "ERROR: v2 benchmark failed (exit $exit_code)"
    log "Infra still up. Run: cd $TF_DIR && TF_VAR_ssh_public_key=${SSH_KEY}.pub terraform destroy -auto-approve -var aws_region=$AWS_REGION"
  fi
}
trap cleanup EXIT

# === Main ===
log "=== PetClinic v2 Benchmark (2 EC2 + RDS) ==="
preflight
tf_apply

APP_IP=$(tf_output ec2_public_ip)
APP_PRIVATE_IP=$(tf_output ec2_private_ip)
K6_IP=$(tf_output k6_ec2_public_ip)
ECR_URL=$(tf_output ecr_repository_url)
S3_BUCKET=$(tf_output s3_bucket_name)
RDS_HOST=$(tf_output rds_address)

log "App EC2: $APP_IP (private $APP_PRIVATE_IP)"
log "k6  EC2: $K6_IP"
log "RDS:     $RDS_HOST"
log "ECR:     $ECR_URL"
log "S3:      $S3_BUCKET"

build_and_push "$ECR_URL"

wait_for_user_data "$APP_IP" "app"
wait_for_user_data "$K6_IP" "k6"
deploy_scripts "$APP_IP" "$K6_IP"

for variant in $VARIANTS; do
  run_variant "$variant" "$APP_IP" "$K6_IP" "$ECR_URL" "$RDS_HOST" "$S3_BUCKET" "$APP_PRIVATE_IP"
done

# Upload all results from both EC2s
log "Uploading results..."
ssh $SSH_OPTS "ubuntu@${APP_IP}" \
  "sudo -n /tmp/app-on-ec2.sh upload jvm $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET"
ssh $SSH_OPTS "ubuntu@${K6_IP}" \
  "/tmp/k6-on-ec2.sh upload jvm 0 $AWS_REGION $S3_BUCKET"

log "Downloading from S3 -> $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
aws s3 sync "s3://${S3_BUCKET}/results/" "$RESULTS_DIR/" --region "$AWS_REGION"

if [[ -x "$BENCHMARK_DIR/.venv/bin/python" ]]; then
  "$BENCHMARK_DIR/.venv/bin/python" "$SCRIPT_DIR/charts.py" "$RESULTS_DIR" || true
fi
"$SCRIPT_DIR/generate-report.sh" "$RESULTS_DIR" || true

tf_destroy

log "=== v2 benchmark complete ==="
log "Results: $RESULTS_DIR"
