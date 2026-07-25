#!/usr/bin/env bash
# Focused re-test for the crac-peak anomaly: does the warmed CRaC checkpoint's
# lower peak throughput come from GC pressure of the restored warm heap at a tight
# memory cap? Compare crac vs crac-jvm at 512m AND 768m. If crac gains much more
# from the extra headroom than crac-jvm, the warm-heap-GC hypothesis holds.
#
# Reuses the v2 terraform + the on-EC2 scripts. Provisions, runs the 2x2 matrix
# (variant x memory) with PEAK_ITERS sweeps each, pulls results, destroys infra.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
TF_DIR="$BENCHMARK_DIR/terraform"
OUT="$BENCHMARK_DIR/results/aws-crac-retest"

AWS_REGION="${AWS_REGION:-eu-central-1}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ServerAliveInterval=60 -o ConnectTimeout=15"
MEMS="${MEMS:-512m 768m}"
VARIANTS="crac-jvm crac"
PEAK_ITERS="${PEAK_ITERS:-3}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
tfo() { (cd "$TF_DIR" && terraform output -raw "$1"); }

cleanup() { [[ $? -ne 0 ]] && log "FAILED — infra may be up. Destroy: cd $TF_DIR && TF_VAR_ssh_public_key=${SSH_KEY}.pub terraform destroy -auto-approve -var aws_region=$AWS_REGION"; }
trap cleanup EXIT

log "=== CRaC peak re-test (2x2: {crac,crac-jvm} x {$MEMS}) ==="
aws sts get-caller-identity >/dev/null || { echo "AWS not authed"; exit 1; }

# --- provision ---
log "terraform apply..."
(cd "$TF_DIR" && terraform init -input=false >/dev/null && \
   TF_VAR_ssh_public_key="${SSH_KEY}.pub" terraform apply -auto-approve -var "aws_region=$AWS_REGION" >/dev/null)
APP_IP=$(tfo ec2_public_ip); APP_PRIV=$(tfo ec2_private_ip); K6_IP=$(tfo k6_ec2_public_ip)
ECR=$(tfo ecr_repository_url); S3=$(tfo s3_bucket_name); RDS=$(tfo rds_address)
log "app=$APP_IP k6=$K6_IP rds=$RDS"

# --- build + push crac-warmup (GC logging + -PwithCrac) and crac-jvm ---
log "build + push images..."
cp "$BENCHMARK_DIR/docker/.dockerignore" "$PROJECT_ROOT/.dockerignore"
docker build -f "$BENCHMARK_DIR/docker/Dockerfile.crac-warmup" -t petclinic:crac-warmup "$PROJECT_ROOT" >/dev/null
docker build -f "$BENCHMARK_DIR/docker/Dockerfile.crac-jvm"    -t petclinic:crac-jvm    "$PROJECT_ROOT" >/dev/null
rm -f "$PROJECT_ROOT/.dockerignore"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${ECR%%/*}" >/dev/null
for t in crac-warmup crac-jvm; do docker tag "petclinic:$t" "$ECR:$t"; docker push "$ECR:$t" >/dev/null; log "pushed $t"; done

# --- wait for user-data, deploy scripts ---
log "waiting for EC2 user-data..."
for ip in "$APP_IP" "$K6_IP"; do
  for i in $(seq 1 120); do ssh $SSH_OPTS "ubuntu@$ip" "test -f /tmp/user-data-done" 2>/dev/null && break; sleep 5; done
done
scp $SSH_OPTS "$SCRIPT_DIR/app-on-ec2.sh" "ubuntu@$APP_IP:/tmp/app-on-ec2.sh"
scp $SSH_OPTS "$SCRIPT_DIR/crac-prepare-on-ec2.sh" "ubuntu@$APP_IP:/tmp/crac-prepare-on-ec2.sh"
ssh $SSH_OPTS "ubuntu@$APP_IP" "chmod +x /tmp/app-on-ec2.sh /tmp/crac-prepare-on-ec2.sh"
ssh $SSH_OPTS "ubuntu@$K6_IP" "mkdir -p /tmp/k6"
scp $SSH_OPTS "$BENCHMARK_DIR/k6/"*.js "ubuntu@$K6_IP:/tmp/k6/"
scp $SSH_OPTS "$SCRIPT_DIR/k6-on-ec2.sh" "ubuntu@$K6_IP:/tmp/k6-on-ec2.sh"
ssh $SSH_OPTS "ubuntu@$K6_IP" "chmod +x /tmp/k6-on-ec2.sh"

# --- prepare crac checkpoint once (memory-independent; restored into each cap) ---
log "prepare crac checkpoint on EC2..."
ssh $SSH_OPTS "ubuntu@$APP_IP" "sudo -n /tmp/crac-prepare-on-ec2.sh $ECR $AWS_REGION $RDS warmed"

run_cell() {
  local v="$1" mem="$2"
  local tag="${v}-${mem}"
  log "=== cell: $tag ==="
  ssh $SSH_OPTS "ubuntu@$APP_IP" "sudo -n /tmp/app-on-ec2.sh start $v $ECR $RDS $AWS_REGION $S3 peak $mem"
  # cold-JIT warmup burst before sweeps (both crac-jvm cold and crac get one for parity here)
  ssh $SSH_OPTS "ubuntu@$K6_IP" "for _ in \$(seq 1 300); do curl -s -o /dev/null http://${APP_PRIV}:8080/vets -H 'Accept: application/json' || true; sleep 0.1; done"
  for i in $(seq 1 "$PEAK_ITERS"); do
    log "$tag sweep $i/$PEAK_ITERS"
    ssh $SSH_OPTS "ubuntu@$K6_IP" "/tmp/k6-on-ec2.sh peak $v $APP_PRIV $AWS_REGION $S3 $i" \
      || log "WARN: $tag sweep $i non-zero"
  done
  # capture GC + peak RSS from the app container before stopping
  ssh $SSH_OPTS "ubuntu@$APP_IP" "docker logs petclinic-$v 2>&1 | grep -iE 'Pause|GC\\(' | tail -400 > /tmp/${tag}-gc.txt; cp /tmp/benchmark-results/${v}-stats-peak.csv /tmp/${tag}-stats-peak.csv 2>/dev/null || true"
  ssh $SSH_OPTS "ubuntu@$APP_IP" "sudo -n /tmp/app-on-ec2.sh stop $v $ECR $RDS $AWS_REGION $S3 peak" || true
  # pull this cell's results into a labeled local dir
  mkdir -p "$OUT/$tag"
  scp $SSH_OPTS "ubuntu@$K6_IP:/tmp/benchmark-results/${v}-peak-rps-iter*-summary.json" "$OUT/$tag/" 2>/dev/null || true
  scp $SSH_OPTS "ubuntu@$APP_IP:/tmp/${tag}-gc.txt" "$OUT/$tag/" 2>/dev/null || true
  scp $SSH_OPTS "ubuntu@$APP_IP:/tmp/${tag}-stats-peak.csv" "$OUT/$tag/" 2>/dev/null || true
  # clear k6 peak files so next cell doesn't mix
  ssh $SSH_OPTS "ubuntu@$K6_IP" "rm -f /tmp/benchmark-results/${v}-peak-rps-iter*"
}

mkdir -p "$OUT"
for mem in $MEMS; do
  for v in $VARIANTS; do
    run_cell "$v" "$mem"
  done
done

log "destroying infra..."
(cd "$TF_DIR" && TF_VAR_ssh_public_key="${SSH_KEY}.pub" terraform destroy -auto-approve -var "aws_region=$AWS_REGION" >/dev/null)
log "=== re-test complete. Results: $OUT ==="
