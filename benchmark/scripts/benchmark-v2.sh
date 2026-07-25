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
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
    log "SKIP_BUILD=1 — reusing images already in ECR, skipping build+push"
    return
  fi
  log "Building images: $VARIANTS"
  # build.sh produces jvm + jaz + native in one go; run it if any are requested.
  for v in $VARIANTS; do
    case "$v" in
      jvm|jaz|native)
        "$SCRIPT_DIR/build.sh"
        break
        ;;
    esac
  done
  if [[ "$VARIANTS" == *native-mlpgo* ]]; then
    "$SCRIPT_DIR/build-native-mlpgo.sh"
  fi
  if [[ "$VARIANTS" == *native-pgo* ]]; then
    # Local quick profile (curl loop). For the publishable PGO number, refine
    # with retrain-pgo-on-rds.sh after this run — it trains on the prod topology
    # with the real k6 workload (the "correct profile").
    "$SCRIPT_DIR/build-native-pgo.sh"
  fi

  # CRaC: crac + crac-onrefresh restore images are built ON the app EC2 by
  # crac-prepare-on-ec2.sh (checkpoint must capture the target's CPU features +
  # the RDS URL). Here we only build+push the inputs: the crac-warmup image
  # (feeds both checkpoints) and crac-jvm (a normal cold-JVM image on Zulu CRaC).
  local need_warmup=0 need_cracjvm=0
  for v in $VARIANTS; do
    case "$v" in
      crac|crac-onrefresh) need_warmup=1 ;;
      crac-jvm)            need_cracjvm=1 ;;
    esac
  done
  if [[ $need_warmup == 1 || $need_cracjvm == 1 ]]; then
    cp "$BENCHMARK_DIR/docker/.dockerignore" "$PROJECT_ROOT/.dockerignore"
    if [[ $need_warmup == 1 ]]; then
      log "Building crac-warmup image..."
      docker build -f "$BENCHMARK_DIR/docker/Dockerfile.crac-warmup" -t petclinic:crac-warmup "$PROJECT_ROOT"
    fi
    if [[ $need_cracjvm == 1 ]]; then
      log "Building crac-jvm image..."
      docker build -f "$BENCHMARK_DIR/docker/Dockerfile.crac-jvm" -t petclinic:crac-jvm "$PROJECT_ROOT"
    fi
    rm -f "$PROJECT_ROOT/.dockerignore"
  fi

  log "Authenticating to ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ecr_url"
  for v in $VARIANTS; do
    case "$v" in
      crac|crac-onrefresh)
        # restore image is built on the EC2 from crac-warmup; nothing to push here
        ;;
      *)
        log "Pushing $v..."
        docker tag "petclinic:${v}" "${ecr_url}:${v}"
        docker push "${ecr_url}:${v}"
        ;;
    esac
  done
  if [[ $need_warmup == 1 ]]; then
    log "Pushing crac-warmup..."
    docker tag petclinic:crac-warmup "${ecr_url}:crac-warmup"
    docker push "${ecr_url}:crac-warmup"
  fi
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

  log "Uploading CRaC prepare script..."
  scp $SSH_OPTS "$SCRIPT_DIR/crac-prepare-on-ec2.sh" "ubuntu@${app_ip}:/tmp/crac-prepare-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${app_ip}" "chmod +x /tmp/crac-prepare-on-ec2.sh"

  log "Uploading load-side script + k6 workloads..."
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "mkdir -p /tmp/k6"
  scp $SSH_OPTS "$BENCHMARK_DIR/k6/"*.js "ubuntu@${k6_ip}:/tmp/k6/"
  scp $SSH_OPTS "$SCRIPT_DIR/k6-on-ec2.sh" "ubuntu@${k6_ip}:/tmp/k6-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "chmod +x /tmp/k6-on-ec2.sh"
}

# Build the CRaC restore image ON the app EC2 for a given variant (crac|crac-onrefresh).
prepare_crac() {
  local variant="$1" app_ip="$2" ecr_url="$3" rds_host="$4"
  local mode; [[ "$variant" == "crac" ]] && mode="warmed" || mode="onrefresh"
  log "Preparing CRaC image on app EC2 ($variant, mode=$mode)..."
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/crac-prepare-on-ec2.sh $ecr_url $AWS_REGION $rds_host $mode"
}

# --- Run one variant ---
run_variant() {
  local variant="$1" app_ip="$2" k6_ip="$3" ecr_url="$4" rds_host="$5" s3_bucket="$6" app_private_ip="$7"
  log "=== Variant: $variant ==="

  # Phase A: mixed workload (10 min sustained)
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh start $variant $ecr_url $rds_host $AWS_REGION $s3_bucket mixed"
  ssh $SSH_OPTS "ubuntu@${k6_ip}" \
    "/tmp/k6-on-ec2.sh mixed $variant $app_private_ip $AWS_REGION $s3_bucket" \
    || log "WARN: $variant mixed k6 exited non-zero — continuing"
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh stop $variant $ecr_url $rds_host $AWS_REGION $s3_bucket mixed" || true

  sleep 10

  # Phase B: peak-RPS (5 min ramp, fresh container)
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh start $variant $ecr_url $rds_host $AWS_REGION $s3_bucket peak"
  # JIT warm-up burst for COLD-JIT variants before the peak sweeps: jvm, jaz,
  # crac-jvm (plain cold JVMs) and crac-onrefresh (restore is fast but JIT is
  # cold). native (AOT) and crac (warmed checkpoint already hot) get no burst.
  if [[ "$variant" == "jvm" || "$variant" == "jaz" || "$variant" == "crac-jvm" || "$variant" == "crac-onrefresh" ]]; then
    ssh $SSH_OPTS "ubuntu@${k6_ip}" \
      "for _ in \$(seq 1 300); do curl -s -o /dev/null http://${app_private_ip}:8080/vets -H 'Accept: application/json' || true; sleep 0.1; done"
  fi
  # PEAK_ITERS back-to-back saturation sweeps against the SAME container, so we
  # get variance across runs (brief: 5 sweeps + variance). Each sweep writes
  # {variant}-peak-rps-iterN.csv/summary. k6 exits 99 when a threshold breaks
  # (e.g. a variant OOM-kills under burst) — that's a result, not a harness
  # error, so record it and keep going.
  for iter in $(seq 1 "${PEAK_ITERS:-5}"); do
    log "$variant peak sweep $iter/${PEAK_ITERS:-5}"
    ssh $SSH_OPTS "ubuntu@${k6_ip}" \
      "/tmp/k6-on-ec2.sh peak $variant $app_private_ip $AWS_REGION $s3_bucket $iter" \
      || log "WARN: $variant peak sweep $iter exited non-zero (threshold breach / app died) — continuing"
  done
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh stop $variant $ecr_url $rds_host $AWS_REGION $s3_bucket peak" || true

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
  # CRaC restore variants: build the checkpoint + restore image on the app EC2 first.
  if [[ "$variant" == "crac" || "$variant" == "crac-onrefresh" ]]; then
    prepare_crac "$variant" "$APP_IP" "$ECR_URL" "$RDS_HOST" \
      || { log "WARN: crac prepare failed for $variant — skipping variant"; continue; }
  fi
  run_variant "$variant" "$APP_IP" "$K6_IP" "$ECR_URL" "$RDS_HOST" "$S3_BUCKET" "$APP_PRIVATE_IP" \
    || log "WARN: variant $variant failed — continuing to next"
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

# KEEP_INFRA=1 leaves the stack up so retrain-pgo-on-rds.sh can train + measure
# the correct-profile native-pgo on the SAME EC2+RDS before teardown.
if [[ "${KEEP_INFRA:-0}" == "1" ]]; then
  log "KEEP_INFRA=1 — leaving stack up. Destroy later with:"
  log "  cd $TF_DIR && TF_VAR_ssh_public_key=${SSH_KEY}.pub terraform destroy -auto-approve -var aws_region=$AWS_REGION"
else
  tf_destroy
fi

log "=== v2 benchmark complete ==="
log "Results: $RESULTS_DIR"
