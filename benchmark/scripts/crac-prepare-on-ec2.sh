#!/usr/bin/env bash
# Runs ON the app EC2 (c7i.large). Produces a CRaC restore image LOCALLY on the
# instance so the checkpoint captures this host's native CPU features (no
# -XX:CPUFeatures=generic tax, no cross-node SIGILL) and bakes the RDS URL that
# the restore will actually use (CRaC bakes the JDBC URL; only creds are re-read).
#
# Self-contained: needs only the pushed warmup image (jar + Zulu CRaC JDK +
# entrypoints). No source tree, no repo Dockerfiles required on the instance.
#
# Args: ECR_URL AWS_REGION RDS_HOST MODE
#   MODE = warmed    -> jcmd JDK.checkpoint after load-warming (warm JIT)
#        | onrefresh -> -Dspring.context.checkpoint=onRefresh (cold JIT, the trap)
# Output image: petclinic-crac:<MODE>
set -euo pipefail

ECR_URL="${1:?ECR_URL}"; AWS_REGION="${2:?AWS_REGION}"; RDS_HOST="${3:?RDS_HOST}"; MODE="${4:?MODE warmed|onrefresh}"
WARMUP_IMAGE="${ECR_URL}:crac-warmup"
OUT_IMAGE="petclinic-crac:${MODE}"
# Metric filenames keyed by the benchmark VARIANT name (warmed=crac).
VN=$([[ "$MODE" == "warmed" ]] && echo "crac" || echo "crac-onrefresh")
WARMUP_SECONDS="${WARMUP_SECONDS:-90}"
DB_URL="jdbc:postgresql://${RDS_HOST}:5432/petclinic"
WORK="/tmp/crac-prep-${MODE}"
RESULTS_DIR="/tmp/benchmark-results"
mkdir -p "$RESULTS_DIR"

log() { echo "[$(date '+%H:%M:%S')] [crac-prepare $MODE] $*"; }
metric() { echo "$2" > "$RESULTS_DIR/$1"; }

log "ECR auth + pull warmup image"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_URL" >/dev/null
docker pull "$WARMUP_IMAGE" >/dev/null

rm -rf "$WORK"; mkdir -p "$WORK/crac-files"
docker rm -f crac-prep >/dev/null 2>&1 || true

ckpt_start=$(date +%s.%3N)
if [[ "$MODE" == "warmed" ]]; then
  log "warm ${WARMUP_SECONDS}s vs RDS then jcmd checkpoint (baked URL=$DB_URL)"
  docker run --name crac-prep --network host \
    -e WARMUP_SECONDS="$WARMUP_SECONDS" \
    -e POSTGRES_URL="$DB_URL" -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    -v "$WORK/crac-files:/crac-files" \
    "$WARMUP_IMAGE" || true
else
  # onRefresh: checkpoint at context-refresh, DB-free (lazy pool, no sql.init,
  # pinned dialect). Reuse the warmup image but override its entrypoint.
  log "onRefresh checkpoint (cold JIT), baked URL=$DB_URL"
  docker run --name crac-prep --network host --entrypoint bash \
    -e POSTGRES_URL="$DB_URL" -e POSTGRES_USER=petclinic -e POSTGRES_PASS=petclinic \
    -v "$WORK/crac-files:/crac-files" \
    "$WARMUP_IMAGE" -c '
      java -Dspring.context.checkpoint=onRefresh \
        -XX:CRaCCheckpointTo=/crac-files \
        -Dspring.profiles.active=postgres,crac \
        -Dspring.sql.init.mode=never \
        -Dspring.datasource.hikari.initialization-fail-timeout=-1 \
        -Dspring.jpa.database-platform=org.hibernate.dialect.PostgreSQLDialect \
        -Dspring.jpa.properties.hibernate.temp.use_jdbc_metadata_defaults=false \
        -jar /app/app.jar || true
      chmod -R a+rX /crac-files 2>/dev/null || true
      test -n "$(ls -A /crac-files 2>/dev/null)"' || true
fi
ckpt_end=$(date +%s.%3N)
docker rm -f crac-prep >/dev/null 2>&1 || true

if [[ -z "$(ls -A "$WORK/crac-files" 2>/dev/null)" ]]; then
  log "ERROR: no checkpoint produced"; exit 1
fi
metric "${VN}-crac-checkpoint-create-s.txt" "$(awk "BEGIN{printf \"%.1f\", $ckpt_end-$ckpt_start}")"
metric "${VN}-crac-checkpoint-image-bytes.txt" "$(du -sb "$WORK/crac-files" | cut -f1)"
log "checkpoint: $(du -sh "$WORK/crac-files" | cut -f1)"

log "building restore image $OUT_IMAGE"
cat > "$WORK/Dockerfile" <<EOF
FROM ${WARMUP_IMAGE}
COPY crac-files/ /crac-files/
ENTRYPOINT ["/usr/local/bin/restore-or-start.sh"]
EOF
docker build -t "$OUT_IMAGE" "$WORK" >/dev/null
metric "${VN}-crac-image-size-bytes.txt" "$(docker image inspect "$OUT_IMAGE" --format '{{.Size}}')"
log "done -> $OUT_IMAGE"
