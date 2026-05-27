#!/usr/bin/env bash
# v2 load-side: runs k6 (mixed-workload or peak-rps) against an APP_IP.
# Outputs results to /tmp/benchmark-results and uploads to S3 at the end.
#
# Args: SCENARIO VARIANT APP_IP AWS_REGION S3_BUCKET
#   SCENARIO = mixed | peak | upload
#   VARIANT  = jvm | native | native-pgo
set -euo pipefail

SCENARIO="${1:?SCENARIO required}"
VARIANT="${2:?VARIANT required}"
APP_IP="${3:?APP_IP required}"
AWS_REGION="${4:?AWS_REGION required}"
S3_BUCKET="${5:?S3_BUCKET required}"
ITER="${6:-}"   # optional iteration tag; suffixes peak output as -iterN

RESULTS_DIR="/tmp/benchmark-results"
DURATION="${DURATION:-10m}"
VUS_TOTAL="${VUS_TOTAL:-50}"
START_RPS="${START_RPS:-100}"
END_RPS="${END_RPS:-2000}"
PEAK_DURATION="${PEAK_DURATION:-5m}"
PEAK_MAX_VUS="${PEAK_MAX_VUS:-500}"

mkdir -p "$RESULTS_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

case "$SCENARIO" in
  mixed)
    log "k6 mixed-workload ($DURATION, $VUS_TOTAL VUs) against http://${APP_IP}:8080"
    DURATION="$DURATION" VUS_TOTAL="$VUS_TOTAL" \
      k6 run \
      --out "csv=$RESULTS_DIR/${VARIANT}-k6-results.csv" \
      --summary-export "$RESULTS_DIR/${VARIANT}-k6-summary.json" \
      -e BASE_URL="http://${APP_IP}:8080" \
      -e DURATION="$DURATION" -e VUS_TOTAL="$VUS_TOTAL" \
      /tmp/k6/mixed-workload.js 2>&1 | tee "$RESULTS_DIR/${VARIANT}-k6-output.txt"
    ;;

  peak)
    tag="${ITER:+-iter${ITER}}"
    log "k6 peak-RPS (${START_RPS}->${END_RPS} req/s over ${PEAK_DURATION}) against http://${APP_IP}:8080${ITER:+ [iter $ITER]}"
    DURATION="$PEAK_DURATION" START_RPS="$START_RPS" END_RPS="$END_RPS" MAX_VUS="$PEAK_MAX_VUS" \
      k6 run \
      --out "csv=$RESULTS_DIR/${VARIANT}-peak-rps${tag}.csv" \
      --summary-export "$RESULTS_DIR/${VARIANT}-peak-rps${tag}-summary.json" \
      -e BASE_URL="http://${APP_IP}:8080" \
      -e START_RPS="$START_RPS" -e END_RPS="$END_RPS" \
      -e DURATION="$PEAK_DURATION" -e MAX_VUS="$PEAK_MAX_VUS" \
      /tmp/k6/peak-rps.js 2>&1 | tee "$RESULTS_DIR/${VARIANT}-peak-rps${tag}-output.txt"
    ;;

  upload)
    log "Uploading load-side results to S3..."
    aws s3 sync "$RESULTS_DIR" "s3://${S3_BUCKET}/results/" --region "$AWS_REGION"
    ;;

  *)
    echo "Unknown scenario: $SCENARIO"
    exit 2
    ;;
esac
