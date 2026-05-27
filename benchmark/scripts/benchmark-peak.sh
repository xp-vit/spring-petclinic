#!/usr/bin/env bash
# Peak-RPS reproducibility run: spins up the same v2 infra (2 EC2 + RDS),
# but ONLY exercises the peak-RPS saturation sweep -- N times per variant
# against a single warm container -- to characterise variance and average.
#
# Skips the mixed-workload and startup phases (already shown reproducible).
#
#   PEAK_ITERS=5  VARIANTS="jvm native"  AWS_PROFILE=...  ./benchmark-peak.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
TF_DIR="$BENCHMARK_DIR/terraform"
RESULTS_DIR="$BENCHMARK_DIR/results/aws-v2-peak"

AWS_REGION="${AWS_REGION:-eu-central-1}"
VARIANTS="${VARIANTS:-jvm native}"
PEAK_ITERS="${PEAK_ITERS:-5}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ServerAliveInterval=60"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

preflight() {
  log "Pre-flight checks..."
  for cmd in docker terraform aws jq scp ssh; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd missing"; exit 1; }
  done
  aws sts get-caller-identity >/dev/null || { echo "ERROR: AWS not configured"; exit 1; }
  docker info >/dev/null || { echo "ERROR: docker daemon not running"; exit 1; }
  [[ -f "$SSH_KEY.pub" ]] || { echo "ERROR: SSH key $SSH_KEY.pub missing"; exit 1; }
}

tf_apply() {
  log "Provisioning v2 infrastructure..."
  cd "$TF_DIR"
  terraform init -input=false >/dev/null
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" \
    terraform apply -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}
tf_output() { cd "$TF_DIR"; terraform output -raw "$1"; cd "$PROJECT_ROOT"; }
tf_destroy() {
  log "Destroying v2 infrastructure..."
  cd "$TF_DIR"
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" \
    terraform destroy -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}

build_and_push() {
  local ecr_url="$1"
  log "Building images: $VARIANTS"
  "$SCRIPT_DIR/build.sh"
  log "Authenticating to ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ecr_url"
  for v in $VARIANTS; do
    log "Pushing $v..."
    docker tag "petclinic:${v}" "${ecr_url}:${v}"
    docker push "${ecr_url}:${v}"
  done
}

wait_for_user_data() {
  local ip="$1" label="$2"
  log "Waiting for $label EC2 ($ip) user-data..."
  for i in $(seq 1 120); do
    if ssh $SSH_OPTS -o ConnectTimeout=5 "ubuntu@${ip}" "test -f /tmp/user-data-done" 2>/dev/null; then
      log "$label ready after ~${i}s"; return 0
    fi
    sleep 5
  done
  echo "ERROR: $label EC2 not ready in 10 min"; return 1
}

deploy_scripts() {
  local app_ip="$1" k6_ip="$2"
  scp $SSH_OPTS "$SCRIPT_DIR/app-on-ec2.sh" "ubuntu@${app_ip}:/tmp/app-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${app_ip}" "chmod +x /tmp/app-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "mkdir -p /tmp/k6"
  scp $SSH_OPTS "$BENCHMARK_DIR/k6/"*.js "ubuntu@${k6_ip}:/tmp/k6/"
  scp $SSH_OPTS "$SCRIPT_DIR/k6-on-ec2.sh" "ubuntu@${k6_ip}:/tmp/k6-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "chmod +x /tmp/k6-on-ec2.sh"
}

# Run N peak sweeps against one warm container.
run_peak_variant() {
  local variant="$1" app_ip="$2" k6_ip="$3" ecr_url="$4" rds_host="$5" s3_bucket="$6" app_private_ip="$7"
  log "=== Variant: $variant ($PEAK_ITERS peak iterations) ==="
  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh start $variant $ecr_url $rds_host $AWS_REGION $s3_bucket peak"

  # Warm the JIT once before measuring (JVM only); native needs nothing.
  if [[ "$variant" == "jvm" ]]; then
    log "JVM JIT warm-up burst..."
    ssh $SSH_OPTS "ubuntu@${k6_ip}" \
      "for _ in \$(seq 1 600); do curl -s -o /dev/null http://${app_private_ip}:8080/vets -H 'Accept: application/json' || true; sleep 0.05; done"
  fi

  for i in $(seq 1 "$PEAK_ITERS"); do
    log "--- $variant peak iteration $i/$PEAK_ITERS ---"
    ssh $SSH_OPTS "ubuntu@${k6_ip}" \
      "/tmp/k6-on-ec2.sh peak $variant $app_private_ip $AWS_REGION $s3_bucket $i"
    sleep 15   # let queues drain between iterations
  done

  ssh $SSH_OPTS "ubuntu@${app_ip}" \
    "sudo -n /tmp/app-on-ec2.sh stop $variant $ecr_url $rds_host $AWS_REGION $s3_bucket peak"
  log "=== $variant done ==="
}

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log "ERROR: peak benchmark failed (exit $exit_code)"
    log "Infra still up. Run: cd $TF_DIR && TF_VAR_ssh_public_key=${SSH_KEY}.pub terraform destroy -auto-approve -var aws_region=$AWS_REGION"
  fi
}
trap cleanup EXIT

# === Main ===
log "=== PetClinic PEAK-RPS reproducibility run (${PEAK_ITERS}x per variant) ==="
preflight
tf_apply

APP_IP=$(tf_output ec2_public_ip)
APP_PRIVATE_IP=$(tf_output ec2_private_ip)
K6_IP=$(tf_output k6_ec2_public_ip)
ECR_URL=$(tf_output ecr_repository_url)
S3_BUCKET=$(tf_output s3_bucket_name)
RDS_HOST=$(tf_output rds_address)

log "App EC2: $APP_IP ($APP_PRIVATE_IP) | k6: $K6_IP | RDS: $RDS_HOST"

build_and_push "$ECR_URL"
wait_for_user_data "$APP_IP" "app"
wait_for_user_data "$K6_IP" "k6"
deploy_scripts "$APP_IP" "$K6_IP"

for variant in $VARIANTS; do
  run_peak_variant "$variant" "$APP_IP" "$K6_IP" "$ECR_URL" "$RDS_HOST" "$S3_BUCKET" "$APP_PRIVATE_IP"
done

log "Uploading results..."
ssh $SSH_OPTS "ubuntu@${K6_IP}" "/tmp/k6-on-ec2.sh upload jvm 0 $AWS_REGION $S3_BUCKET"

log "Downloading from S3 -> $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
aws s3 sync "s3://${S3_BUCKET}/results/" "$RESULTS_DIR/" --region "$AWS_REGION"

tf_destroy

# --- Averages ---
log "Computing per-variant peak averages..."
PY="$BENCHMARK_DIR/.venv/bin/python"; [[ -x "$PY" ]] || PY=python3
"$PY" - "$RESULTS_DIR" $VARIANTS <<'PYEOF'
import json, sys, glob, statistics as st
results_dir = sys.argv[1]; variants = sys.argv[2:]
def stats(xs):
    xs=[x for x in xs if x is not None]
    if not xs: return "n/a"
    m=st.mean(xs); sd=st.pstdev(xs) if len(xs)>1 else 0.0
    return f"mean={m:8.1f}  sd={sd:6.1f}  min={min(xs):8.1f}  max={max(xs):8.1f}  (n={len(xs)})"
print("\n=== PEAK-RPS reproducibility ===")
for v in variants:
    files=sorted(glob.glob(f"{results_dir}/{v}-peak-rps-iter*-summary.json"))
    rates=[]; p50=[]; p95=[]; p99=[]; fails=[]
    for f in files:
        d=json.load(open(f))["metrics"]
        rates.append(d.get("http_reqs",{}).get("rate"))
        dur=d.get("http_req_duration",{})
        p50.append(dur.get("med")); p95.append(dur.get("p(95)")); p99.append(dur.get("p(99)"))
        fails.append(d.get("http_req_failed",{}).get("value"))
    print(f"\n[{v}]  iterations={len(files)}")
    print(f"  RPS  : {stats(rates)}")
    print(f"  p50ms: {stats(p50)}")
    print(f"  p95ms: {stats(p95)}")
    print(f"  p99ms: {stats(p99)}")
    print(f"  fail%: {stats(fails)}")
PYEOF

log "=== peak benchmark complete ==="
log "Results: $RESULTS_DIR"
