#!/usr/bin/env bash
# Runs as PID 1 inside the CRaC warmup container.
#   1. start the app with a checkpoint target + placeholder secret
#   2. wait until a BUSINESS endpoint returns 200
#   3. drive load to warm the JIT (C2-hot)
#   4. jcmd JDK.checkpoint  -> JVM dumps warm image to /crac-files and exits
# The resulting /crac-files (host-mounted) is baked into the restore image.
#
# Env:
#   WARMUP_URL        base URL of the app (default http://localhost:8080)
#   WARMUP_SECONDS    JIT warm duration after first 200 (default 90)
#   POSTGRES_URL/USER/PASS  DB for warmup (throwaway; real DB supplied at restore)
set -uo pipefail

WARMUP_URL="${WARMUP_URL:-http://localhost:8080}"
WARMUP_SECONDS="${WARMUP_SECONDS:-90}"
CHECKPOINT_DIR="${CRAC_CHECKPOINT_DIR:-/crac-files}"

echo "[warmup] clearing $CHECKPOINT_DIR"
rm -rf "${CHECKPOINT_DIR:?}/"* 2>/dev/null || true

# Placeholder secret ONLY — the real one is read from env at restore time.
export PETCLINIC_API_SECRET="build-time-placeholder-not-a-real-secret"

echo "[warmup] starting app (CRaCCheckpointTo=$CHECKPOINT_DIR)"
# GC logging to stdout is captured in the checkpoint and continues after restore
# (visible via `docker logs`), so we can compare GC pressure crac vs crac-jvm.
java -XX:CRaCCheckpointTo="$CHECKPOINT_DIR" \
  -Xlog:gc*:stdout:time,level,tags \
  -Dspring.profiles.active=postgres,crac \
  -jar /app/app.jar &
APP_PID=$!

echo "[warmup] waiting for first business 200 at $WARMUP_URL/vets ..."
ready=0
for _ in $(seq 1 180); do
  if curl -sf -o /dev/null -H 'Accept: application/json' "$WARMUP_URL/vets"; then
    ready=1; echo "[warmup] app is serving business traffic"; break
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "[warmup] ERROR: app process died before becoming ready"; exit 1
  fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "[warmup] ERROR: app never served /vets"; kill "$APP_PID" 2>/dev/null; exit 1; }

echo "[warmup] driving load for ${WARMUP_SECONDS}s to warm the JIT ..."
end=$((SECONDS + WARMUP_SECONDS))
n=0
while [ "$SECONDS" -lt "$end" ]; do
  curl -s -o /dev/null "$WARMUP_URL/owners?lastName=Davis"
  curl -s -o /dev/null "$WARMUP_URL/owners/$(( (n % 10) + 1 ))"
  curl -s -o /dev/null -H 'Accept: application/json' "$WARMUP_URL/vets"
  n=$((n + 1))
done
echo "[warmup] warmed with ~$((n * 3)) requests"

echo "[warmup] triggering JDK.checkpoint ..."
# On success the JVM dumps and exits. On failure (e.g. an un-closed socket) it
# throws CheckpointException and KEEPS RUNNING — so we must not wait forever.
jcmd /app/app.jar JDK.checkpoint 2>&1 || jcmd "$APP_PID" JDK.checkpoint 2>&1 || true

for _ in $(seq 1 60); do
  kill -0 "$APP_PID" 2>/dev/null || break   # process gone => checkpoint dumped
  sleep 1
done

if kill -0 "$APP_PID" 2>/dev/null; then
  echo "[warmup] ERROR — JVM still alive after checkpoint (checkpoint failed). Recent log:"
  kill "$APP_PID" 2>/dev/null || true
  exit 1
fi

# The dump is written root:root 0600. Make it world-readable so an unprivileged
# host user can include it in the restore image's build context (Docker tars the
# context as the calling user). Secrets were scrubbed before the dump.
chmod -R a+rX "$CHECKPOINT_DIR" 2>/dev/null || true

echo "[warmup] checkpoint finished. Image contents:"
ls -la "$CHECKPOINT_DIR" || true
if [ -n "$(ls -A "$CHECKPOINT_DIR" 2>/dev/null)" ]; then
  echo "[warmup] OK — checkpoint image present"; exit 0
fi
echo "[warmup] ERROR — no checkpoint image produced"; exit 1
