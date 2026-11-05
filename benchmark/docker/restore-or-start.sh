#!/usr/bin/env bash
# Final-image entrypoint. Restores from the baked CRaC checkpoint if present,
# otherwise falls back to a normal cold JVM start. The fallback is what lets the
# same image run on non-CRaC nodes (or after a checkpoint-incompatible upgrade)
# instead of crash-looping.
#
# Env:
#   CRAC_RESTORE_DIR   checkpoint image dir (default /crac-files)
#   JAVA_OPTS          extra flags for the cold-start fallback
set -uo pipefail

RESTORE_DIR="${CRAC_RESTORE_DIR:-/crac-files}"

if [ -n "$(ls -A "$RESTORE_DIR" 2>/dev/null)" ]; then
  echo "[entrypoint] checkpoint found in $RESTORE_DIR — restoring warm JVM"
  # Secrets/DB creds are re-read in afterRestore() from the current env, so the
  # real values live only in the running process, never in the image layer.
  exec java -XX:CRaCRestoreFrom="$RESTORE_DIR"
fi

echo "[entrypoint] no checkpoint in $RESTORE_DIR — cold JVM start (fallback)"
exec java ${JAVA_OPTS:-} \
  -Dspring.profiles.active="${SPRING_PROFILES_ACTIVE:-postgres,crac}" \
  -jar /app/app.jar
