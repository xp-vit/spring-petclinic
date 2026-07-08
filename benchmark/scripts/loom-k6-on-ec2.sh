#!/usr/bin/env bash
# Virtual-thread benchmark load-side: runs loom-workload.js from the k6 EC2, looping the
# concurrency levels for one (endpoint, mode) combination. For each level it also samples the
# app's /api/threadstats so we can chart live PLATFORM thread count vs concurrency.
#
# Args: ACTION APP_IP AWS_REGION S3_BUCKET [ENDPOINT [MS [ITERS [TAG [LEVELS [DURATION]]]]]]
#   ACTION   = run | upload
#   ENDPOINT = slow | slow-db | cpu
#   TAG      = label shared with the app side, e.g. slow-platform / slowdb-h100 / cpu-virtual
#   LEVELS   = space-separated concurrency levels (quote it as one arg)
set -euo pipefail

ACTION="${1:?ACTION required}"
APP_IP="${2:?APP_IP required}"
AWS_REGION="${3:?AWS_REGION required}"
S3_BUCKET="${4:?S3_BUCKET required}"
ENDPOINT="${5:-slow}"
MS="${6:-200}"
ITERS="${7:-500000}"
TAG="${8:-run}"
LEVELS="${9:-50 100 200 500 1000 2000}"
DURATION="${10:-60s}"

RESULTS_DIR="/tmp/benchmark-results"
APP_PORT=8080
mkdir -p "$RESULTS_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*"; }
base_url="http://${APP_IP}:${APP_PORT}"

sample_threads() {  # $1=level  $2=outfile ; runs until killed
  while true; do
    j=$(curl -s "${base_url}/api/threadstats" 2>/dev/null || true)
    pt=$(echo "$j" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('platformThreadCount',''))
except: print('')" 2>/dev/null || echo "")
    [[ -n "$pt" ]] && echo "$(date +%s.%3N),$1,$pt" >> "$2"
    sleep 1
  done
}

case "$ACTION" in
  run)
    tfile="$RESULTS_DIR/${TAG}-threads.csv"
    echo "ts,level,platform_threads" > "$tfile"
    for lvl in $LEVELS; do
      log "--- $TAG @ concurrency=$lvl (endpoint=$ENDPOINT ms=$MS dur=$DURATION) ---"
      sample_threads "$lvl" "$tfile" & spid=$!
      k6 run \
        --summary-export "$RESULTS_DIR/${TAG}-c${lvl}-summary.json" \
        -e BASE_URL="$base_url" -e ENDPOINT="$ENDPOINT" \
        -e MS="$MS" -e ITERS="$ITERS" -e CONCURRENCY="$lvl" -e DURATION="$DURATION" \
        /tmp/k6/loom-workload.js 2>&1 | tee "$RESULTS_DIR/${TAG}-c${lvl}-output.txt"
      kill "$spid" 2>/dev/null || true
    done
    ;;

  upload)
    log "Uploading k6 results to S3 (loom-results/)..."
    aws s3 sync "$RESULTS_DIR" "s3://${S3_BUCKET}/loom-results/" --region "$AWS_REGION"
    ;;

  *)
    echo "Unknown action: $ACTION"; exit 2;;
esac
