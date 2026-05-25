#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"

echo "=== Building Docker images ==="
echo "Project root: $PROJECT_ROOT"

# Copy .dockerignore to project root (Docker needs it there)
cp "$DOCKER_DIR/.dockerignore" "$PROJECT_ROOT/.dockerignore"

cleanup() {
  rm -f "$PROJECT_ROOT/.dockerignore"
}
trap cleanup EXIT

echo ""
echo "--- Building JVM image ---"
docker build \
  -f "$DOCKER_DIR/Dockerfile.jvm" \
  -t petclinic:jvm \
  "$PROJECT_ROOT"

echo ""
echo "--- Building Native image (this takes several minutes) ---"
docker build \
  -f "$DOCKER_DIR/Dockerfile.native" \
  -t petclinic:native \
  "$PROJECT_ROOT"

echo ""
echo "=== Build complete ==="
docker images | grep petclinic
