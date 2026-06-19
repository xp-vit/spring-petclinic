#!/usr/bin/env bash
# Caffeine-vs-Redis cache benchmark (single-node, 3-way).
#
# Same petclinic:jvm fat JAR, three cache strategies selected by Spring profile:
#   cache-none      NoOpCacheManager    -> every /vets hits the DB (baseline)
#   cache-caffeine  CaffeineCacheManager-> in-heap cache, no network
#   cache-redis     RedisCacheManager   -> out-of-process cache (TCP + JSON)
#
# Workload (benchmark/k6/cache-workload.js): read-heavy GET /vets (cache hits) +
# a small fraction of POST /vets/{id}/touch (DB write + @CacheEvict -> repopulate).
#
# Usage:
#   ./benchmark/scripts/run-cache-local.sh [profile] [variants]
#     profile  = smoke (default, 3min/20 VUs, with think-time)
#              | standard (10min/50 VUs, with think-time)
#              | peak (3min/50 VUs, NO think-time -> max throughput)
#     variants = "all" (default) | space-separated subset of the three above
#
# Env overrides:
#   K6_DURATION, K6_VUS_TOTAL, WRITE_RATIO      -- workload tuning
#   WORKLOAD=vets|report, SIZE=N                -- payload shape (report = heavy, N rows)
#   READ_SLEEP, WRITE_SLEEP                     -- think-time seconds (peak sets both 0)
#   APP_PORT=8080                               -- app/host port (use 8081 if 8080 taken)
#   SKIP_BUILD=1                                -- reuse existing petclinic:jvm image
#   RESULTS_SUBDIR=local-cache                  -- results dir name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$BENCHMARK_DIR/.." && pwd)"
DOCKER_DIR="$BENCHMARK_DIR/docker"
RESULTS_DIR="$BENCHMARK_DIR/results/${RESULTS_SUBDIR:-local-cache}"

PROFILE="${1:-smoke}"
VARIANTS_ARG="${2:-all}"

APP_MEMORY="512m"
APP_CPUS="1"
APP_PORT="${APP_PORT:-8080}"
PG_NAME="petclinic-postgres"
PG_PORT=5432
REDIS_NAME="petclinic-redis"
REDIS_PORT=6379
WRITE_RATIO="${WRITE_RATIO:-0.1}"
WORKLOAD="${WORKLOAD:-vets}"      # vets (tiny) | report (heavy synthetic) | stats (heavy DB query)
SIZE="${SIZE:-1000}"             # report row count when WORKLOAD=report
READ_SLEEP="${READ_SLEEP:-0.1}"
WRITE_SLEEP="${WRITE_SLEEP:-0.2}"
# Large-dataset seed for WORKLOAD=stats (the heavy DB aggregation needs real volume).
SEED_OWNERS="${SEED_OWNERS:-100000}"
SEED_PETS="${SEED_PETS:-300000}"
SEED_VISITS="${SEED_VISITS:-2000000}"

case "$PROFILE" in
  smoke)    DURATION="${K6_DURATION:-3m}";  VUS_TOTAL="${K6_VUS_TOTAL:-20}";;
  standard) DURATION="${K6_DURATION:-10m}"; VUS_TOTAL="${K6_VUS_TOTAL:-50}";;
  # peak: no think-time -> saturate the app and measure max throughput, not fixed-rate latency.
  peak)     DURATION="${K6_DURATION:-3m}";  VUS_TOTAL="${K6_VUS_TOTAL:-50}"; READ_SLEEP=0; WRITE_SLEEP=0;;
  *) echo "Unknown profile: $PROFILE"; exit 2;;
esac

log() { echo "[$(date '+%H:%M:%S')] $*"; }
require() { for c in "$@"; do command -v "$c" >/dev/null || { echo "ERROR: $c not in PATH"; exit 2; }; done; }

cleanup() {
  log "Cleanup..."
  docker rm -f petclinic-cache-none petclinic-cache-caffeine petclinic-cache-redis \
    "$PG_NAME" "$REDIS_NAME" 2>/dev/null || true
  if [[ -n "${STATS_PID:-}" ]]; then kill "$STATS_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

profile_for() {
  case "$1" in
    cache-none|cache-caffeine|cache-redis) echo "postgres,$1";;
    *) echo "ERROR: unknown cache variant: $1" >&2; exit 2;;
  esac
}

build_image() {
  if [[ "${SKIP_BUILD:-0}" == "1" ]]; then log "SKIP_BUILD=1, reusing petclinic:jvm"; return; fi
  log "Building petclinic:jvm (cache code baked in)..."
  cp "$DOCKER_DIR/.dockerignore" "$PROJECT_ROOT/.dockerignore"
  docker build -f "$DOCKER_DIR/Dockerfile.jvm" -t petclinic:jvm "$PROJECT_ROOT"
  rm -f "$PROJECT_ROOT/.dockerignore"
}

start_postgres() {
  log "Starting Postgres..."
  docker rm -f "$PG_NAME" 2>/dev/null || true
  docker run -d --name "$PG_NAME" -p ${PG_PORT}:5432 \
    -e POSTGRES_DB=petclinic -e POSTGRES_USER=petclinic -e POSTGRES_PASSWORD=petclinic \
    postgres:18.3 >/dev/null
  for i in $(seq 1 30); do
    docker exec "$PG_NAME" pg_isready -U petclinic >/dev/null 2>&1 && { log "Postgres ready (${i}s)"; return; }
    sleep 1
  done
  echo "ERROR: Postgres not ready"; exit 4
}

start_redis() {
  log "Starting Redis..."
  docker rm -f "$REDIS_NAME" 2>/dev/null || true
  docker run -d --name "$REDIS_NAME" -p ${REDIS_PORT}:6379 redis:7-alpine >/dev/null
  for i in $(seq 1 30); do
    docker exec "$REDIS_NAME" redis-cli ping 2>/dev/null | grep -q PONG && { log "Redis ready (${i}s)"; return; }
    sleep 1
  done
  echo "ERROR: Redis not ready"; exit 4
}

reset_db() {
  docker exec "$PG_NAME" psql -U petclinic -c \
    "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 || true
}
flush_redis() { docker exec "$REDIS_NAME" redis-cli FLUSHALL >/dev/null 2>&1 || true; }

psql_q() { docker exec -i "$PG_NAME" psql -U petclinic -d petclinic -v ON_ERROR_STOP=1 "$@"; }

# Seed a large dataset for WORKLOAD=stats so the heavy aggregation is genuinely expensive.
# Creates the schema + base reference data (from the app's own SQL files), then bulk-inserts
# owners/pets/visits with generate_series. Apps then run with SQL init disabled so they do
# not re-init or wipe it.
seed_stats_db() {
  log "Seeding stats dataset (owners=$SEED_OWNERS pets=$SEED_PETS visits=$SEED_VISITS)..."
  psql_q < "$PROJECT_ROOT/src/main/resources/db/postgres/schema.sql" >/dev/null
  psql_q < "$PROJECT_ROOT/src/main/resources/db/postgres/data.sql" >/dev/null
  psql_q >/dev/null <<SQL
INSERT INTO owners (first_name, last_name, address, city, telephone)
SELECT 'F'||g, 'L'||g, g||' Main St',
       (ARRAY['Madison','Monona','Windsor','McFarland','Sun Prairie'])[1+(g%5)],
       lpad((g%1000000)::text,10,'0')
FROM generate_series(1, $SEED_OWNERS) g;

INSERT INTO pets (name, birth_date, type_id, owner_id)
SELECT 'P'||g, DATE '2015-01-01' + (g%3000), 1+(g%6), 1+(g % $SEED_OWNERS)
FROM generate_series(1, $SEED_PETS) g;

INSERT INTO visits (pet_id, visit_date, description)
SELECT 1+(g % $SEED_PETS), DATE '2018-01-01' + (g%2000), 'visit '||g
FROM generate_series(1, $SEED_VISITS) g;

ANALYZE;
SQL
  local n; n=$(psql_q -tAc "SELECT count(*) FROM visits")
  log "Seed done: visits row count = $n"
}

start_stats_sampler() {
  local name="$1" out="$2"
  echo "ts,cpu_pct,mem_bytes" > "$out"
  (
    while docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; do
      local line ts cpu memraw mem
      line=$(docker stats "$name" --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null || true)
      if [[ -n "$line" ]]; then
        ts=$(date +%s.%3N)
        cpu="${line%%|*}"; cpu="${cpu//%/}"
        memraw="${line##*|}"; memraw="${memraw%% /*}"
        mem=$(python3 -c "
s='$memraw'.strip()
for k,v in [('GiB',1024**3),('MiB',1024**2),('KiB',1024),('GB',1000**3),('MB',1000**2),('KB',1000),('B',1)]:
  if s.endswith(k): print(int(float(s[:-len(k)])*v)); break
else: print(0)" 2>/dev/null || echo 0)
        echo "$ts,$cpu,$mem" >> "$out"
      fi
      sleep 1
    done
  ) &
  STATS_PID=$!
}
stop_stats_sampler() {
  if [[ -n "${STATS_PID:-}" ]]; then kill "$STATS_PID" 2>/dev/null || true; wait "$STATS_PID" 2>/dev/null || true; STATS_PID=""; fi
}

run_variant() {
  local variant="$1"
  local image="petclinic:jvm"
  local cname="petclinic-${variant}"
  local profiles; profiles="$(profile_for "$variant")"

  log "=== Variant: $variant (profiles=$profiles) ==="
  docker image inspect "$image" >/dev/null 2>&1 || { echo "ERROR: $image not found; run without SKIP_BUILD"; exit 3; }
  docker image inspect "$image" --format '{{.Size}}' > "$RESULTS_DIR/${variant}-image-size-bytes.txt"

  # stats workload keeps the large seeded dataset across variants (read-only); other
  # workloads reset the DB and let the app re-init the small base data each variant.
  local sql_init_mode="always"
  if [[ "$WORKLOAD" == "stats" ]]; then
    sql_init_mode="never"
  else
    reset_db
  fi
  flush_redis
  docker rm -f "$cname" 2>/dev/null || true

  local start_ts ready_ts startup_ms
  start_ts=$(date +%s%N)
  docker run -d --name "$cname" --network host --memory "$APP_MEMORY" --cpus "$APP_CPUS" \
    -e SPRING_PROFILES_ACTIVE="$profiles" \
    -e SERVER_PORT="${APP_PORT}" \
    -e SPRING_SQL_INIT_MODE="$sql_init_mode" \
    -e POSTGRES_URL=jdbc:postgresql://localhost:5432/petclinic \
    -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    -e SPRING_DATA_REDIS_HOST=localhost -e SPRING_DATA_REDIS_PORT=${REDIS_PORT} \
    "$image" >/dev/null

  log "Waiting for $variant to become healthy..."
  for i in $(seq 1 180); do
    if curl -sf http://localhost:${APP_PORT}/actuator/health >/dev/null 2>&1; then
      ready_ts=$(date +%s%N); startup_ms=$(( (ready_ts - start_ts) / 1000000 ))
      echo "$startup_ms" > "$RESULTS_DIR/${variant}-startup-ms.txt"
      log "$variant healthy after ${startup_ms}ms"; break
    fi
    sleep 1
  done
  if [[ -z "${ready_ts:-}" ]]; then echo "ERROR: $variant not healthy"; docker logs "$cname" --tail 80; return 5; fi

  # Sanity: confirm the active CacheManager matches the variant.
  local cm; cm=$(curl -s http://localhost:${APP_PORT}/actuator/caches 2>/dev/null || true)
  log "$variant /actuator/caches: ${cm:0:200}"

  start_stats_sampler "$cname" "$RESULTS_DIR/${variant}-stats.csv"

  log "Running k6 ($DURATION, $VUS_TOTAL VUs, write_ratio=$WRITE_RATIO, workload=$WORKLOAD/size=$SIZE, read_sleep=$READ_SLEEP write_sleep=$WRITE_SLEEP)..."
  docker run --rm --network host --user "$(id -u):$(id -g)" \
    -v "$BENCHMARK_DIR/k6:/scripts:ro" -v "$RESULTS_DIR:/out" \
    -e BASE_URL="http://localhost:${APP_PORT}" -e DURATION="$DURATION" \
    -e VUS_TOTAL="$VUS_TOTAL" -e WRITE_RATIO="$WRITE_RATIO" \
    -e WORKLOAD="$WORKLOAD" -e SIZE="$SIZE" \
    -e READ_SLEEP="$READ_SLEEP" -e WRITE_SLEEP="$WRITE_SLEEP" \
    grafana/k6:latest run \
    --out "csv=/out/${variant}-k6-results.csv" \
    --summary-export="/out/${variant}-k6-summary.json" \
    /scripts/cache-workload.js \
    2>&1 | tee "$RESULTS_DIR/${variant}-k6-output.txt"

  stop_stats_sampler
  docker stats "$cname" --no-stream --format '{{.MemUsage}}\t{{.CPUPerc}}' > "$RESULTS_DIR/${variant}-stats-after.txt" || true
  docker stop "$cname" >/dev/null; docker rm "$cname" >/dev/null
  log "=== $variant done ==="
}

summarize() {
  log "Computing comparison (drop first 30s warmup)..."
  python3 - "$RESULTS_DIR" "$@" <<'PY'
import sys, csv, statistics, os
rd = sys.argv[1]; variants = sys.argv[2:]
WARMUP = 30.0
def pct(xs, p):
    if not xs: return float('nan')
    xs = sorted(xs); k = (len(xs)-1)*p/100.0
    f = int(k); c = min(f+1, len(xs)-1)
    return xs[f] + (xs[c]-xs[f])*(k-f)
print(f"\n{'variant':<16}{'RPS':>9}{'p50':>9}{'p95':>9}{'p99':>9}{'reads':>9}{'writes':>9}")
print("-"*70)
for v in variants:
    f = os.path.join(rd, f"{v}-k6-results.csv")
    if not os.path.isfile(f): print(f"{v:<16}  (no results)"); continue
    durs=[]; t0=None; tend=0; reqs=0; reads=0; writes=0
    with open(f) as fh:
        for row in csv.DictReader(fh):
            if row.get('metric_name')!='http_req_duration': continue
            ts=float(row['timestamp'])
            if t0 is None: t0=ts
            if ts-t0 < WARMUP: continue
            tend=max(tend,ts)
            durs.append(float(row['metric_value'])); reqs+=1
            scen=row.get('scenario','')
            if scen.startswith('read'): reads+=1
            elif scen.startswith('write'): writes+=1
    span = (tend - (t0+WARMUP)) or 1
    rps = reqs/span
    print(f"{v:<16}{rps:>9.1f}{pct(durs,50):>9.2f}{pct(durs,95):>9.2f}{pct(durs,99):>9.2f}{reads:>9}{writes:>9}")
print("\n(latency ms; RPS = requests/sec after warmup)")
PY
}

main() {
  require docker curl python3
  mkdir -p "$RESULTS_DIR"
  local variants
  case "$VARIANTS_ARG" in
    all) variants="cache-none cache-caffeine cache-redis";;
    *)   variants="$VARIANTS_ARG";;
  esac
  log "Profile: $PROFILE | Duration: $DURATION | VUs: $VUS_TOTAL | Variants: $variants"
  log "Results: $RESULTS_DIR"

  build_image
  start_postgres
  start_redis
  if [[ "$WORKLOAD" == "stats" ]]; then seed_stats_db; fi

  local first=1
  for v in $variants; do
    [[ $first -eq 0 ]] && sleep 10
    run_variant "$v"
    first=0
  done

  summarize $variants | tee "$RESULTS_DIR/comparison.txt"
  log "Done. Results: $RESULTS_DIR"
}
main "$@"
