#!/usr/bin/env bash
set -euo pipefail

# Force C locale so bc / printf use '.' as decimal separator regardless of $LANG.
export LC_ALL=C

RESULTS_DIR="${1:?Usage: generate-report.sh RESULTS_DIR}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Spring Boot PetClinic: JVM vs Native Benchmark      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# --- Startup Time ---
jvm_startup=$(cat "$RESULTS_DIR/jvm-startup-ms.txt" 2>/dev/null || echo "N/A")
native_startup=$(cat "$RESULTS_DIR/native-startup-ms.txt" 2>/dev/null || echo "N/A")
jvm_cold=$(cat "$RESULTS_DIR/jvm-cold-start-ms.txt" 2>/dev/null || echo "N/A")
native_cold=$(cat "$RESULTS_DIR/native-cold-start-ms.txt" 2>/dev/null || echo "N/A")

echo "┌─────────────────────────────────────────────────────────────┐"
echo "│ STARTUP TIME                                                │"
echo "├──────────────────────┬──────────────┬───────────────────────┤"
printf "│ %-20s │ %-12s │ %-21s │\n" "Scenario" "JVM" "Native"
echo "├──────────────────────┼──────────────┼───────────────────────┤"
printf "│ %-20s │ %-12s │ %-21s │\n" "Cold (no load)" "${jvm_startup}ms" "${native_startup}ms"
printf "│ %-20s │ %-12s │ %-21s │\n" "Cold (under load)" "${jvm_cold}ms" "${native_cold}ms"
echo "└──────────────────────┴──────────────┴───────────────────────┘"
echo ""

# --- Memory ---
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│ MEMORY (after load)                                         │"
echo "├──────────────┬──────────────────────────────────────────────┤"
jvm_mem=$(cat "$RESULTS_DIR/jvm-stats-after.txt" 2>/dev/null || echo "N/A")
native_mem=$(cat "$RESULTS_DIR/native-stats-after.txt" 2>/dev/null || echo "N/A")
printf "│ JVM          │ %-44s │\n" "$jvm_mem"
printf "│ Native       │ %-44s │\n" "$native_mem"
echo "└──────────────┴──────────────────────────────────────────────┘"
echo ""

# --- Throughput & Latency from k6 summary ---
extract_metric() {
  local file="$1"
  local metric="$2"
  local field="$3"
  if [ -f "$file" ]; then
    jq -r ".metrics.${metric}[\"${field}\"] // \"N/A\"" "$file" 2>/dev/null || echo "N/A"
  else
    echo "N/A"
  fi
}

jvm_summary="$RESULTS_DIR/jvm-k6-summary.json"
native_summary="$RESULTS_DIR/native-k6-summary.json"

jvm_rps=$(extract_metric "$jvm_summary" "http_reqs" "rate")
native_rps=$(extract_metric "$native_summary" "http_reqs" "rate")

jvm_p50=$(extract_metric "$jvm_summary" "http_req_duration" "med")
native_p50=$(extract_metric "$native_summary" "http_req_duration" "med")

jvm_p95=$(extract_metric "$jvm_summary" "http_req_duration" "p(95)")
native_p95=$(extract_metric "$native_summary" "http_req_duration" "p(95)")

jvm_p99=$(extract_metric "$jvm_summary" "http_req_duration" "p(99)")
native_p99=$(extract_metric "$native_summary" "http_req_duration" "p(99)")

jvm_errors=$(extract_metric "$jvm_summary" "http_req_failed" "rate")
native_errors=$(extract_metric "$native_summary" "http_req_failed" "rate")

echo "┌─────────────────────────────────────────────────────────────┐"
echo "│ THROUGHPUT & LATENCY (mixed workload, 50 VUs, 10 min)       │"
echo "├─────────────────────┬──────────────┬────────────────────────┤"
printf "│ %-19s │ %-12s │ %-22s │\n" "Metric" "JVM" "Native"
echo "├─────────────────────┼──────────────┼────────────────────────┤"
printf "│ %-19s │ %10.1f/s │ %20.1f/s │\n" "Throughput (req/s)" "$jvm_rps" "$native_rps" 2>/dev/null || \
printf "│ %-19s │ %-12s │ %-22s │\n" "Throughput (req/s)" "$jvm_rps" "$native_rps"
printf "│ %-19s │ %10.1fms │ %20.1fms │\n" "Latency p50" "$jvm_p50" "$native_p50" 2>/dev/null || \
printf "│ %-19s │ %-12s │ %-22s │\n" "Latency p50" "$jvm_p50" "$native_p50"
printf "│ %-19s │ %10.1fms │ %20.1fms │\n" "Latency p95" "$jvm_p95" "$native_p95" 2>/dev/null || \
printf "│ %-19s │ %-12s │ %-22s │\n" "Latency p95" "$jvm_p95" "$native_p95"
printf "│ %-19s │ %10.1fms │ %20.1fms │\n" "Latency p99" "$jvm_p99" "$native_p99" 2>/dev/null || \
printf "│ %-19s │ %-12s │ %-22s │\n" "Latency p99" "$jvm_p99" "$native_p99"
printf "│ %-19s │ %-12s │ %-22s │\n" "Error rate" "$jvm_errors" "$native_errors"
echo "└─────────────────────┴──────────────┴────────────────────────┘"
echo ""

# --- Throughput ratio ---
if command -v bc &> /dev/null && [ "$jvm_rps" != "N/A" ] && [ "$native_rps" != "N/A" ]; then
  ratio=$(echo "scale=2; $native_rps / $jvm_rps * 100" | bc 2>/dev/null || echo "N/A")
  echo "Native throughput is ${ratio}% of JVM throughput."
  echo ""
fi

echo "Raw results available in: $RESULTS_DIR"
echo "CSV files contain time-series data for throughput-over-time charts."
