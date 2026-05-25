#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
TF_DIR="$BENCHMARK_DIR/terraform"
RESULTS_DIR="$BENCHMARK_DIR/results/aws"

AWS_REGION="${AWS_REGION:-eu-central-1}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Pre-flight checks ---

preflight() {
  log "Pre-flight checks..."
  local missing=()

  command -v docker &>/dev/null || missing+=("docker")
  command -v terraform &>/dev/null || missing+=("terraform")
  command -v aws &>/dev/null || missing+=("aws")
  command -v jq &>/dev/null || missing+=("jq")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required tools: ${missing[*]}"
    exit 1
  fi

  # Check AWS credentials
  if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERROR: AWS credentials not configured. Run 'aws configure' or set AWS_PROFILE."
    exit 1
  fi

  # Check Docker is running
  if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon is not running."
    exit 1
  fi

  log "Pre-flight checks passed."
}

# --- Terraform ---

terraform_apply() {
  log "Provisioning AWS infrastructure..."
  cd "$TF_DIR"
  terraform init -input=false
  terraform apply -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}

terraform_output() {
  cd "$TF_DIR"
  terraform output -raw "$1"
  cd "$PROJECT_ROOT"
}

terraform_destroy() {
  log "Destroying AWS infrastructure..."
  cd "$TF_DIR"
  terraform destroy -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}

# --- Docker Build & Push ---

build_images() {
  log "Building Docker images..."
  "$SCRIPT_DIR/build.sh"
}

push_images() {
  local ecr_url="$1"

  log "Authenticating to ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ecr_url"

  log "Pushing JVM image..."
  docker tag petclinic:jvm "${ecr_url}:jvm"
  docker push "${ecr_url}:jvm"

  log "Pushing Native image..."
  docker tag petclinic:native "${ecr_url}:native"
  docker push "${ecr_url}:native"
}

# --- Remote Execution ---

wait_for_ec2() {
  local ip="$1"
  log "Waiting for EC2 instance to be ready..."
  for i in $(seq 1 120); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "ubuntu@${ip}" "test -f /tmp/user-data-done" 2>/dev/null; then
      log "EC2 ready after ~${i}s"
      return 0
    fi
    sleep 5
  done
  log "ERROR: EC2 instance did not become ready within 10 minutes"
  return 1
}

run_remote_benchmark() {
  local ip="$1"
  local ecr_url="$2"
  local s3_bucket="$3"
  local ssh_opts="-o StrictHostKeyChecking=no"

  # Upload k6 scripts and benchmark runner
  log "Uploading scripts to EC2..."
  ssh $ssh_opts "ubuntu@${ip}" "mkdir -p /tmp/k6"
  scp $ssh_opts "$BENCHMARK_DIR/k6/"*.js "ubuntu@${ip}:/tmp/k6/"
  scp $ssh_opts "$SCRIPT_DIR/run-on-ec2.sh" "ubuntu@${ip}:/tmp/run-on-ec2.sh"
  ssh $ssh_opts "ubuntu@${ip}" "chmod +x /tmp/run-on-ec2.sh"

  # Run the benchmark
  log "Starting benchmark on EC2 (this takes ~30 minutes)..."
  ssh $ssh_opts "ubuntu@${ip}" \
    "sudo /tmp/run-on-ec2.sh '${ecr_url}' '${AWS_REGION}' '${s3_bucket}'"
}

# --- Download Results ---

download_results() {
  local s3_bucket="$1"

  mkdir -p "$RESULTS_DIR"
  log "Downloading results from S3..."
  aws s3 sync "s3://${s3_bucket}/results/" "$RESULTS_DIR/" --region "$AWS_REGION"
}

# --- Cleanup handler ---

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log "ERROR: Benchmark failed (exit code $exit_code)"
    log "Infrastructure may still be running. Run: cd $TF_DIR && terraform destroy -auto-approve -var aws_region=$AWS_REGION"
  fi
}
trap cleanup EXIT

# === Main ===

main() {
  log "=== PetClinic JVM vs Native Benchmark ==="
  echo ""

  preflight

  # Step 1: Provision infrastructure
  terraform_apply
  EC2_IP=$(terraform_output "ec2_public_ip")
  ECR_URL=$(terraform_output "ecr_repository_url")
  S3_BUCKET=$(terraform_output "s3_bucket_name")
  log "EC2: $EC2_IP | ECR: $ECR_URL | S3: $S3_BUCKET"

  # Step 2: Build Docker images locally
  build_images

  # Step 3: Push to ECR
  push_images "$ECR_URL"

  # Step 4: Wait for EC2 and run benchmark
  wait_for_ec2 "$EC2_IP"
  run_remote_benchmark "$EC2_IP" "$ECR_URL" "$S3_BUCKET"

  # Step 5: Download results
  download_results "$S3_BUCKET"

  # Step 6: Generate report + charts
  "$SCRIPT_DIR/generate-report.sh" "$RESULTS_DIR" || true
  if [[ -x "$BENCHMARK_DIR/.venv/bin/python" ]]; then
    "$BENCHMARK_DIR/.venv/bin/python" "$SCRIPT_DIR/charts.py" "$RESULTS_DIR" || true
  else
    log "Tip: create venv (python3 -m venv $BENCHMARK_DIR/.venv && $BENCHMARK_DIR/.venv/bin/pip install -r $SCRIPT_DIR/requirements.txt) then run charts.py for PNGs"
  fi

  # Step 7: Destroy infrastructure
  terraform_destroy

  log "=== Benchmark complete ==="
  log "Results saved to: $RESULTS_DIR"
}

main "$@"
