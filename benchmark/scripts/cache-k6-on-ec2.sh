#!/usr/bin/env bash
# Cache benchmark load-side: runs cache-workload.js from the k6 EC2.
#
# Args: SCENARIO WORKLOAD VARIANT APP_IP AWS_REGION S3_BUCKET
#   SCENARIO = smoke | peak | upload
#   WORKLOAD = vets | stats
set -euo pipefail

SCENARIO="${1:?SCENARIO required}"
WORKLOAD="${2:-}"
VARIANT="${3:-}"
APP_IP="${4:-}"
AWS_REGION="${5:?AWS_REGION required}"
S3_BUCKET="${6:?S3_BUCKET required}"

RESULTS_DIR="/tmp/benchmark-results"
# Headline = cache-warm HIT comparison: no writers, so the cache stays populated and reads
# are hits (the regime where caching's value shows). A separate churn pass can set
# WRITE_RATIO=0.1 to measure eviction/repopulation cost. (Critical: with writers + no
# think-time the no-op evict calls dominate RPS and the cache stays cold -> reads become
# misses, which is NOT a hit measurement.)
WRITE_RATIO="${WRITE_RATIO:-0}"

mkdir -p "$RESULTS_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

base_url="http://${APP_IP}:8080"

case "$SCENARIO" in
  smoke)
    DURATION="${DURATION:-3m}"
    VUS_TOTAL="${VUS_TOTAL:-20}"
    READ_SLEEP=0.1
    WRITE_SLEEP=0.2
    out_csv="$RESULTS_DIR/${VARIANT}-${WORKLOAD}-smoke-k6.csv"
    out_json="$RESULTS_DIR/${VARIANT}-${WORKLOAD}-smoke-summary.json"
    log "k6 cache smoke ($DURATION, ${VUS_TOTAL}VU, workload=$WORKLOAD, variant=$VARIANT)"
    k6 run \
      --out "csv=${out_csv}" \
      --summary-export "${out_json}" \
      -e BASE_URL="$base_url" \
      -e DURATION="$DURATION" -e VUS_TOTAL="$VUS_TOTAL" \
      -e WORKLOAD="$WORKLOAD" \
      -e WRITE_RATIO="$WRITE_RATIO" \
      -e READ_SLEEP="$READ_SLEEP" -e WRITE_SLEEP="$WRITE_SLEEP" \
      /tmp/k6/cache-workload.js 2>&1 | tee "$RESULTS_DIR/${VARIANT}-${WORKLOAD}-smoke-output.txt"
    ;;

  peak)
    DURATION="${DURATION:-3m}"
    VUS_TOTAL="${VUS_TOTAL:-50}"
    READ_SLEEP=0
    WRITE_SLEEP=0
    out_csv="$RESULTS_DIR/${VARIANT}-${WORKLOAD}-peak-k6.csv"
    out_json="$RESULTS_DIR/${VARIANT}-${WORKLOAD}-peak-summary.json"
    log "k6 cache peak ($DURATION, ${VUS_TOTAL}VU no-sleep, workload=$WORKLOAD, variant=$VARIANT)"
    k6 run \
      --out "csv=${out_csv}" \
      --summary-export "${out_json}" \
      -e BASE_URL="$base_url" \
      -e DURATION="$DURATION" -e VUS_TOTAL="$VUS_TOTAL" \
      -e WORKLOAD="$WORKLOAD" \
      -e WRITE_RATIO="$WRITE_RATIO" \
      -e READ_SLEEP="$READ_SLEEP" -e WRITE_SLEEP="$WRITE_SLEEP" \
      /tmp/k6/cache-workload.js 2>&1 | tee "$RESULTS_DIR/${VARIANT}-${WORKLOAD}-peak-output.txt"
    ;;

  upload)
    log "Uploading k6 results to S3..."
    aws s3 sync "$RESULTS_DIR" "s3://${S3_BUCKET}/cache-results/" --region "$AWS_REGION"
    ;;

  *)
    echo "Unknown scenario: $SCENARIO"; exit 2;;
esac
