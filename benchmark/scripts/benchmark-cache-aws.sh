#!/usr/bin/env bash
# Cache benchmark (Caffeine vs Redis) AWS orchestrator.
#
# Architecture (reuses v2 Terraform stack):
#   app EC2 (c7i.large)   — petclinic:jvm + Redis container, connects to RDS
#   k6  EC2 (c5.large)    — k6 load generator
#   RDS Postgres (db.t3.micro) — network-distant DB (the variable that makes Redis worthwhile)
#
# Three variants, same image:  cache-none | cache-caffeine | cache-redis
# Two workloads:
#   vets  — tiny payload, baseline (6-row vets response cached)
#   stats — heavy DB aggregation JOIN over 2M+ visits, cached result is small JSON
#
# Phases per workload per variant:  smoke (3m/20VU + think-time)  |  peak (3m/50VU/no-sleep)
#
# Usage:
#   AWS_PROFILE=<your-aws-profile> ./benchmark/scripts/benchmark-cache-aws.sh
#
# Env overrides:
#   AWS_REGION, SSH_KEY, VARIANTS, WORKLOADS
#   SKIP_BUILD=1    -- reuse petclinic:jvm already in ECR
#   KEEP_INFRA=1    -- leave EC2+RDS up after run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
TF_DIR="$BENCHMARK_DIR/terraform"
RESULTS_DIR="$BENCHMARK_DIR/results/aws-cache"

AWS_REGION="${AWS_REGION:-eu-central-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"
VARIANTS="${VARIANTS:-cache-none cache-caffeine cache-redis}"
WORKLOADS="${WORKLOADS:-vets stats}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ServerAliveInterval=60"

export AWS_PROFILE AWS_REGION

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Preflight ---
preflight() {
  log "Pre-flight (profile=$AWS_PROFILE region=$AWS_REGION)..."
  for cmd in docker terraform aws jq scp ssh; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd missing"; exit 1; }
  done
  aws sts get-caller-identity >/dev/null || { echo "ERROR: AWS not configured"; exit 1; }
  docker info >/dev/null || { echo "ERROR: docker daemon not running"; exit 1; }
  [[ -f "${SSH_KEY}.pub" ]] || { echo "ERROR: SSH key ${SSH_KEY}.pub missing"; exit 1; }
}

# --- Terraform ---
tf_apply() {
  log "Provisioning v2 infra (cache run)..."
  cd "$TF_DIR"
  terraform init -input=false >/dev/null
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" \
    terraform apply -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}

tf_output() {
  cd "$TF_DIR"; terraform output -raw "$1"; cd "$PROJECT_ROOT"
}

tf_destroy() {
  log "Destroying infra..."
  cd "$TF_DIR"
  TF_VAR_ssh_public_key="${SSH_KEY}.pub" \
    terraform destroy -auto-approve -var "aws_region=$AWS_REGION"
  cd "$PROJECT_ROOT"
}

# --- Build + push petclinic:jvm ---
build_and_push() {
  local ecr_url="$1"
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
    log "SKIP_BUILD=1 — reusing petclinic:jvm in ECR"
    return
  fi
  log "Building petclinic:jvm..."
  DOCKER_DIR="$BENCHMARK_DIR/docker"
  cp "$DOCKER_DIR/.dockerignore" "$PROJECT_ROOT/.dockerignore"
  docker build -f "$DOCKER_DIR/Dockerfile.jvm" -t petclinic:jvm "$PROJECT_ROOT"
  rm -f "$PROJECT_ROOT/.dockerignore"

  log "Pushing to ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ecr_url"
  docker tag petclinic:jvm "${ecr_url}:jvm"
  docker push "${ecr_url}:jvm"
}

# --- Wait for EC2 user-data ---
wait_for_user_data() {
  local ip="$1" label="$2"
  log "Waiting for $label ($ip) user-data..."
  for i in $(seq 1 120); do
    if ssh $SSH_OPTS -o ConnectTimeout=5 "ubuntu@${ip}" "test -f /tmp/user-data-done" 2>/dev/null; then
      log "$label ready (~${i}×5s)"; return 0
    fi
    sleep 5
  done
  echo "ERROR: $label EC2 not ready in 10 min"; return 1
}

# --- Deploy scripts to EC2s ---
deploy_scripts() {
  local app_ip="$1" k6_ip="$2"
  log "Deploying scripts to app EC2..."
  scp $SSH_OPTS "$SCRIPT_DIR/cache-app-on-ec2.sh" "ubuntu@${app_ip}:/tmp/cache-app-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${app_ip}" "chmod +x /tmp/cache-app-on-ec2.sh"

  log "Deploying scripts + k6 workloads to k6 EC2..."
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "mkdir -p /tmp/k6"
  scp $SSH_OPTS "$BENCHMARK_DIR/k6/cache-workload.js" "ubuntu@${k6_ip}:/tmp/k6/cache-workload.js"
  scp $SSH_OPTS "$SCRIPT_DIR/cache-k6-on-ec2.sh" "ubuntu@${k6_ip}:/tmp/cache-k6-on-ec2.sh"
  ssh $SSH_OPTS "ubuntu@${k6_ip}" "chmod +x /tmp/cache-k6-on-ec2.sh"
}

# --- Shorthand SSH helpers ---
# printf %q preserves empty positional args ('' stays a token); a bare "$*" collapses them,
# which would shift later args (e.g. AWS_REGION) into the wrong slot over ssh.
app_run() { ssh $SSH_OPTS "ubuntu@${APP_IP}" "sudo -n /tmp/cache-app-on-ec2.sh $(printf '%q ' "$@")"; }
k6_run()  { ssh $SSH_OPTS "ubuntu@${K6_IP}"  "/tmp/cache-k6-on-ec2.sh $(printf '%q ' "$@")"; }

# --- Run one variant + phase (smoke or peak) ---
run_phase() {
  local variant="$1" workload="$2" phase="$3" sql_init_mode="$4"
  log "--- $variant / $workload / $phase (sql_init=$sql_init_mode) ---"
  app_run start "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" "$variant" "$phase" "$sql_init_mode"
  k6_run "$phase" "$workload" "$variant" "$APP_PRIVATE_IP" "$AWS_REGION" "$S3_BUCKET" \
    || log "WARN: k6 $phase exited non-zero — continuing"
  app_run stop "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" "$variant" "$phase" || true
  sleep 5
}

# --- Vets workload: reset DB before each variant, both phases back-to-back ---
run_vets_variant() {
  local variant="$1"
  log "=== vets: $variant ==="
  # Reset DB so each variant starts from identical petclinic base data.
  app_run reset-db "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET"
  # Smoke: Spring inits schema + data (SQL_INIT_MODE=always)
  run_phase "$variant" "vets" "smoke" "always"
  # Peak: schema already there, just flush Redis (SQL_INIT_MODE=never)
  run_phase "$variant" "vets" "peak" "never"
}

# --- Stats workload: seed once, all variants with SQL_INIT_MODE=never ---
run_stats_variant() {
  local variant="$1"
  log "=== stats: $variant ==="
  run_phase "$variant" "stats" "smoke" "never"
  run_phase "$variant" "stats" "peak" "never"
}

# --- Error handler ---
# On any non-zero exit, tear infra down (unless KEEP_INFRA=1) so a mid-run failure never leaves
# EC2+RDS billing. The normal success path destroys explicitly at the end, after which this is a
# no-op. Results worth keeping are uploaded to S3 before teardown.
cleanup() {
  local rc=$?
  [[ $rc -eq 0 ]] && return
  log "ERROR: benchmark failed (exit $rc)."
  if [[ "${KEEP_INFRA:-0}" == "1" ]]; then
    log "KEEP_INFRA=1 — leaving infra up for debugging. Destroy manually:"
    log "  cd $TF_DIR && TF_VAR_ssh_public_key=${SSH_KEY}.pub terraform destroy -auto-approve -var aws_region=$AWS_REGION"
  else
    log "Auto-destroying infra (set KEEP_INFRA=1 to keep it on failure)..."
    tf_destroy || log "WARN: auto-destroy failed — destroy manually: cd $TF_DIR && terraform destroy -auto-approve -var aws_region=$AWS_REGION"
  fi
}
trap cleanup EXIT

# ===== MAIN =====
log "=== PetClinic Cache Benchmark (AWS v2 infra) ==="
log "Workloads: $WORKLOADS | Variants: $VARIANTS"
preflight

tf_apply

APP_IP=$(tf_output ec2_public_ip)
APP_PRIVATE_IP=$(tf_output ec2_private_ip)
K6_IP=$(tf_output k6_ec2_public_ip)
ECR_URL=$(tf_output ecr_repository_url)
S3_BUCKET=$(tf_output s3_bucket_name)
RDS_HOST=$(tf_output rds_address)

log "App EC2:  $APP_IP (private $APP_PRIVATE_IP)"
log "k6  EC2:  $K6_IP"
log "RDS:      $RDS_HOST"
log "ECR:      $ECR_URL"
log "S3:       $S3_BUCKET"

build_and_push "$ECR_URL"

wait_for_user_data "$APP_IP" "app"
wait_for_user_data "$K6_IP" "k6"
deploy_scripts "$APP_IP" "$K6_IP"

# Pull image + start Redis (shared for all variants)
app_run start-infra "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET"

for workload in $WORKLOADS; do
  case "$workload" in
    vets)
      for variant in $VARIANTS; do
        run_vets_variant "$variant" \
          || log "WARN: vets/$variant failed — continuing"
      done
      ;;

    stats)
      # Seed schema + large dataset once, before any stats variant.
      log "=== stats: seeding DB ==="
      app_run reset-db "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET"
      # Start cache-none briefly to initialize schema via Spring SQL init.
      app_run start "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" "cache-none" "init" "always"
      app_run stop  "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" "cache-none" "init" || true
      # Bulk-insert large dataset directly into RDS.
      app_run seed-stats "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET"

      for variant in $VARIANTS; do
        run_stats_variant "$variant" \
          || log "WARN: stats/$variant failed — continuing"
      done
      ;;

    *)
      log "WARN: unknown workload $workload — skipping";;
  esac
done

# Tear down Redis
app_run stop-infra "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" || true

# Upload results from both EC2s. Non-fatal: a hiccup here must not skip teardown below.
log "Uploading results to S3..."
app_run upload "$ECR_URL" "$RDS_HOST" "$AWS_REGION" "$S3_BUCKET" || log "WARN: app upload failed"
k6_run upload na na na "$AWS_REGION" "$S3_BUCKET" || log "WARN: k6 upload failed"

log "Downloading from S3 -> $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
aws s3 sync "s3://${S3_BUCKET}/cache-results/" "$RESULTS_DIR/" --region "$AWS_REGION"

# Print comparison table (same summarize logic as local script)
python3 - "$RESULTS_DIR" <<'PY'
import sys, csv, statistics, os, glob

rd = sys.argv[1]
WARMUP = 30.0

def pct(xs, p):
    if not xs: return float('nan')
    xs = sorted(xs); k = (len(xs)-1)*p/100.0
    f = int(k); c = min(f+1, len(xs)-1)
    return xs[f] + (xs[c]-xs[f])*(k-f)

variants = ["cache-none", "cache-caffeine", "cache-redis"]
workloads = ["vets", "stats"]
phases    = ["smoke", "peak"]

for wl in workloads:
    for ph in phases:
        header = f"\n=== {wl} / {ph} ==="
        rows = []
        for v in variants:
            f = os.path.join(rd, f"{v}-{wl}-{ph}-k6.csv")
            if not os.path.isfile(f):
                rows.append((v, None))
                continue
            durs = []; t0 = None; tend = 0; reqs = 0
            with open(f) as fh:
                for row in csv.DictReader(fh):
                    if row.get('metric_name') != 'http_req_duration': continue
                    # Read-only: exclude write/evict calls so they can't pollute RPS/latency
                    # (a no-op evict under no think-time otherwise dominates the median).
                    if not row.get('scenario', '').startswith('read'): continue
                    ts = float(row['timestamp'])
                    if t0 is None: t0 = ts
                    if ts - t0 < WARMUP: continue
                    tend = max(tend, ts)
                    durs.append(float(row['metric_value'])); reqs += 1
            span = (tend - (t0 + WARMUP)) if t0 else 1
            rows.append((v, (reqs / max(span, 1), durs)))
        if all(r[1] is None for r in rows):
            continue
        print(header)
        print(f"{'variant':<20}{'RPS':>8}{'p50':>8}{'p95':>8}{'p99':>8}")
        print("-" * 50)
        for v, data in rows:
            if data is None:
                print(f"{v:<20}  (no results)")
            else:
                rps, durs = data
                print(f"{v:<20}{rps:>8.1f}{pct(durs,50):>8.2f}{pct(durs,95):>8.2f}{pct(durs,99):>8.2f}")
        print("(read-only; latency ms; RPS after 30s warmup)")
PY

if [[ "${KEEP_INFRA:-0}" == "1" ]]; then
  log "KEEP_INFRA=1 — infra left up. Destroy with:"
  log "  cd $TF_DIR && TF_VAR_ssh_public_key=${SSH_KEY}.pub terraform destroy -auto-approve -var aws_region=$AWS_REGION"
else
  tf_destroy
fi

log "=== Cache benchmark complete ==="
log "Results: $RESULTS_DIR"
