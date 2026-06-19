#!/usr/bin/env bash
# Cache benchmark app-side: manages Redis + cache-variant containers on one EC2.
# All three variants (cache-none / cache-caffeine / cache-redis) use the same
# petclinic:jvm ECR image; only SPRING_PROFILES_ACTIVE differs.
#
# Designed to run on the app EC2 via:  sudo -n /tmp/cache-app-on-ec2.sh ACTION ...
#
# Args: ACTION ECR_URL RDS_HOST AWS_REGION S3_BUCKET [VARIANT [PHASE [SQL_INIT_MODE]]]
#
# ACTION:
#   start-infra             -- ECR login, pull jvm image, start Redis container
#   reset-db                -- DROP + CREATE schema in RDS (clean slate per variant)
#   seed-stats              -- bulk-insert large owners/pets/visits into RDS for stats workload
#   start VARIANT [PHASE] [SQL_INIT_MODE]  -- start app container + stats sampler
#   stop  VARIANT [PHASE]                  -- stop stats sampler + app container
#   stop-infra              -- stop Redis container
#   upload                  -- sync /tmp/benchmark-results to S3
set -euo pipefail

ACTION="${1:?ACTION required}"
ECR_URL="${2:?ECR_URL required}"
RDS_HOST="${3:?RDS_HOST required}"
AWS_REGION="${4:?AWS_REGION required}"
S3_BUCKET="${5:?S3_BUCKET required}"
VARIANT="${6:-}"
PHASE="${7:-}"
SQL_INIT_MODE="${8:-always}"

RESULTS_DIR="/tmp/benchmark-results"
APP_MEMORY="${APP_MEMORY:-512m}"
APP_CPUS="${APP_CPUS:-1}"
APP_PORT=8080
REDIS_NAME="petclinic-redis"
REDIS_PORT=6379
IMAGE="${ECR_URL}:jvm"
SEED_OWNERS="${SEED_OWNERS:-100000}"
SEED_PETS="${SEED_PETS:-300000}"
SEED_VISITS="${SEED_VISITS:-2000000}"

mkdir -p "$RESULTS_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

start_stats_sampler() {
  local cname="petclinic-${VARIANT}"
  local out="$RESULTS_DIR/${VARIANT}-stats${PHASE:+-${PHASE}}.csv"
  echo "ts,cpu_pct,mem_bytes" > "$out"
  (
    set +e
    while docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null | grep -q true; do
      line=$(docker stats "$cname" --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null || true)
      if [[ -n "$line" ]]; then
        ts=$(date +%s.%3N)
        cpu="${line%%|*}"; cpu="${cpu//%/}"
        memraw="${line##*|}"; memraw="${memraw%% /*}"
        mem=$(python3 -c "
s='$memraw'.strip()
u=[('GiB',1024**3),('MiB',1024**2),('KiB',1024),('GB',1000**3),('MB',1000**2),('KB',1000),('B',1)]
for k,v in u:
  if s.endswith(k): print(int(float(s[:-len(k)])*v)); break
else: print(0)
" 2>/dev/null || echo 0)
        echo "$ts,$cpu,$mem" >> "$out"
      fi
      sleep 1
    done
  ) </dev/null >/dev/null 2>&1 &
  echo $! > "/tmp/stats-pid-${VARIANT}"
}

stop_stats_sampler() {
  local pf="/tmp/stats-pid-${VARIANT}"
  if [[ -f "$pf" ]]; then
    kill "$(cat "$pf")" 2>/dev/null || true
    rm -f "$pf"
  fi
}

rds_psql() {
  # -i so heredoc/stdin (seed-stats SQL) reaches psql inside the container.
  docker run --rm -i --network host postgres:18.3 \
    psql -v ON_ERROR_STOP=1 "postgresql://petclinic:petclinic@${RDS_HOST}:5432/petclinic" "$@"
}

case "$ACTION" in

  start-infra)
    log "ECR login + pulling jvm image..."
    aws ecr get-login-password --region "$AWS_REGION" | \
      docker login --username AWS --password-stdin "$ECR_URL" >/dev/null
    docker pull "$IMAGE" >/dev/null
    log "Pre-pulling postgres image for psql ops..."
    docker pull postgres:18.3 >/dev/null
    log "Starting Redis..."
    docker rm -f "$REDIS_NAME" 2>/dev/null || true
    docker run -d --name "$REDIS_NAME" --network host redis:7-alpine >/dev/null
    for i in $(seq 1 30); do
      docker exec "$REDIS_NAME" redis-cli ping 2>/dev/null | grep -q PONG && { log "Redis ready (${i}s)"; break; }
      sleep 1
    done
    ;;

  reset-db)
    log "Resetting RDS schema..."
    rds_psql -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null
    log "Schema reset done."
    ;;

  seed-stats)
    log "Seeding stats dataset (owners=$SEED_OWNERS pets=$SEED_PETS visits=$SEED_VISITS)..."
    rds_psql >/dev/null <<SQL
INSERT INTO owners (first_name, last_name, address, city, telephone)
SELECT 'F'||g, 'L'||g, g||' Main St',
       (ARRAY['Madison','Monona','Windsor','McFarland','Sun Prairie'])[1+(g%5)],
       lpad((g%1000000)::text,10,'0')
FROM generate_series(1, ${SEED_OWNERS}) g;

INSERT INTO pets (name, birth_date, type_id, owner_id)
SELECT 'P'||g, DATE '2015-01-01' + (g%3000), 1+(g%6), 1+(g % ${SEED_OWNERS})
FROM generate_series(1, ${SEED_PETS}) g;

INSERT INTO visits (pet_id, visit_date, description)
SELECT 1+(g % ${SEED_PETS}), DATE '2018-01-01' + (g%2000), 'visit '||g
FROM generate_series(1, ${SEED_VISITS}) g;

ANALYZE;
SQL
    n=$(rds_psql -tAc "SELECT count(*) FROM visits" | tr -d '[:space:]')
    log "Seed done: visits row count = ${n}"
    if [[ "${n:-0}" -lt "$SEED_VISITS" ]]; then
      log "ERROR: seed incomplete (visits=$n < $SEED_VISITS)"; exit 6
    fi
    ;;

  start)
    [[ -z "$VARIANT" ]] && { echo "VARIANT required for start"; exit 2; }
    PROFILES="postgres,${VARIANT}"
    CNAME="petclinic-${VARIANT}"
    log "=== Start $VARIANT (profiles=$PROFILES, sql_init=$SQL_INIT_MODE) ==="
    docker exec "$REDIS_NAME" redis-cli FLUSHALL >/dev/null 2>&1 || true
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    start_ts=$(date +%s%N)
    docker run -d --name "$CNAME" --network host \
      --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
      -e SPRING_PROFILES_ACTIVE="$PROFILES" \
      -e POSTGRES_URL="jdbc:postgresql://${RDS_HOST}:5432/petclinic" \
      -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
      -e SPRING_DATA_REDIS_HOST=localhost \
      -e SPRING_DATA_REDIS_PORT="${REDIS_PORT}" \
      -e SPRING_SQL_INIT_MODE="$SQL_INIT_MODE" \
      "$IMAGE" >/dev/null
    ready_ts=""
    for i in $(seq 1 180); do
      if curl -sf "http://localhost:${APP_PORT}/actuator/health" >/dev/null 2>&1; then
        ready_ts=$(date +%s%N)
        startup_ms=$(( (ready_ts - start_ts) / 1000000 ))
        echo "$startup_ms" > "$RESULTS_DIR/${VARIANT}-startup-ms.txt"
        docker image inspect "$IMAGE" --format '{{.Size}}' \
          > "$RESULTS_DIR/${VARIANT}-image-size-bytes.txt" 2>/dev/null || true
        log "$VARIANT healthy after ${startup_ms}ms"
        break
      fi
      sleep 1
    done
    if [[ -z "$ready_ts" ]]; then
      log "ERROR: $VARIANT not healthy in 180s"
      docker logs "$CNAME" --tail 80
      exit 5
    fi
    start_stats_sampler
    ;;

  stop)
    [[ -z "$VARIANT" ]] && { echo "VARIANT required for stop"; exit 2; }
    CNAME="petclinic-${VARIANT}"
    stop_stats_sampler
    docker stats "$CNAME" --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' \
      > "$RESULTS_DIR/${VARIANT}-stats-after${PHASE:+-${PHASE}}.txt" 2>/dev/null || true
    docker stop "$CNAME" >/dev/null 2>&1 || true
    docker rm "$CNAME" >/dev/null 2>&1 || true
    log "=== $VARIANT stopped ==="
    ;;

  stop-infra)
    log "Stopping Redis..."
    docker stop "$REDIS_NAME" >/dev/null 2>&1 || true
    docker rm "$REDIS_NAME" >/dev/null 2>&1 || true
    ;;

  upload)
    log "Uploading results to S3 (cache-results/)..."
    aws s3 sync "$RESULTS_DIR" "s3://${S3_BUCKET}/cache-results/" --region "$AWS_REGION"
    ;;

  *)
    echo "Unknown action: $ACTION"; exit 2;;
esac
