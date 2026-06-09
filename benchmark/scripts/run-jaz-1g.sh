#!/usr/bin/env bash
# One-off: measure jaz at a 1 GB container limit (its intended operating point)
# on the EXISTING v2 stack. jaz's default heap sizing OOM-kills a 512 MB cgroup
# under peak burst (see the jaz @ 512 MB result) — this captures a *working*
# jaz throughput number at the memory its tuning actually assumes.
#
# Result key: jaz-1g (kept separate from the equal-memory jaz @ 512 MB).
# Reuses the petclinic:jaz image (re-tagged jaz-1g in ECR so docker pull works).
#
# Prereq: v2 terraform stack up; AWS_PROFILE set; same SSH key as benchmark-v2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
TF_DIR="$BENCHMARK_DIR/terraform"
RESULTS_DIR="$BENCHMARK_DIR/results/aws-v2"

AWS_REGION="${AWS_REGION:-eu-central-1}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ServerAliveInterval=60"
VARIANT="jaz-1g"
APP_MEMORY="${APP_MEMORY:-1g}"

log() { echo "[$(date '+%H:%M:%S')] [jaz-1g] $*"; }

cd "$TF_DIR"
APP_IP=$(terraform output -raw ec2_public_ip)
APP_PRIVATE_IP=$(terraform output -raw ec2_private_ip)
K6_IP=$(terraform output -raw k6_ec2_public_ip)
ECR_URL=$(terraform output -raw ecr_repository_url)
RDS_HOST=$(terraform output -raw rds_address)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
cd "$PROJECT_ROOT"

log "App EC2 $APP_IP (priv $APP_PRIVATE_IP) | k6 $K6_IP | mem $APP_MEMORY"

# Re-tag the existing jaz image as jaz-1g in ECR so app-on-ec2.sh can pull it.
log "Tagging petclinic:jaz -> ${ECR_URL}:${VARIANT} in ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_URL" >/dev/null
docker tag petclinic:jaz "${ECR_URL}:${VARIANT}"
docker push "${ECR_URL}:${VARIANT}" >/dev/null

# Drive the same three phases as benchmark-v2 run_variant, but APP_MEMORY=1g.
# APP_MEMORY is consumed by the remote app-on-ec2.sh, so set it on the ssh cmd.
log "Phase A: mixed (10 min sustained) at ${APP_MEMORY}..."
ssh $SSH_OPTS ubuntu@${APP_IP} \
  "sudo -n APP_MEMORY=$APP_MEMORY /tmp/app-on-ec2.sh start $VARIANT $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET mixed"
ssh $SSH_OPTS ubuntu@${K6_IP} \
  "/tmp/k6-on-ec2.sh mixed $VARIANT $APP_PRIVATE_IP $AWS_REGION $S3_BUCKET" \
  || log "WARN: mixed k6 non-zero — continuing"
ssh $SSH_OPTS ubuntu@${APP_IP} \
  "sudo -n APP_MEMORY=$APP_MEMORY /tmp/app-on-ec2.sh stop $VARIANT $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET mixed" || true

sleep 10

log "Phase B: peak (5 min ramp, fresh container) at ${APP_MEMORY}..."
ssh $SSH_OPTS ubuntu@${APP_IP} \
  "sudo -n APP_MEMORY=$APP_MEMORY /tmp/app-on-ec2.sh start $VARIANT $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET peak"
# JIT warm-up burst (jaz is JVM-based).
ssh $SSH_OPTS ubuntu@${K6_IP} \
  "for _ in \$(seq 1 300); do curl -s -o /dev/null http://${APP_PRIVATE_IP}:8080/vets -H 'Accept: application/json' || true; sleep 0.1; done"
ssh $SSH_OPTS ubuntu@${K6_IP} \
  "/tmp/k6-on-ec2.sh peak $VARIANT $APP_PRIVATE_IP $AWS_REGION $S3_BUCKET" \
  || log "WARN: peak k6 non-zero — continuing"
ssh $SSH_OPTS ubuntu@${APP_IP} \
  "sudo -n APP_MEMORY=$APP_MEMORY /tmp/app-on-ec2.sh stop $VARIANT $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET peak" || true

log "Phase C: cold-start under load at ${APP_MEMORY}..."
ssh $SSH_OPTS ubuntu@${APP_IP} \
  "sudo -n APP_MEMORY=$APP_MEMORY /tmp/app-on-ec2.sh cold_start $VARIANT $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET" || true

log "Uploading jaz-1g results..."
ssh $SSH_OPTS ubuntu@${APP_IP} \
  "sudo -n /tmp/app-on-ec2.sh upload $VARIANT $ECR_URL $RDS_HOST $AWS_REGION $S3_BUCKET"
ssh $SSH_OPTS ubuntu@${K6_IP} \
  "/tmp/k6-on-ec2.sh upload $VARIANT 0 $AWS_REGION $S3_BUCKET"

log "Downloading -> $RESULTS_DIR"
aws s3 sync "s3://${S3_BUCKET}/results/" "$RESULTS_DIR/" --region "$AWS_REGION" >/dev/null
log "=== jaz-1g done ==="
