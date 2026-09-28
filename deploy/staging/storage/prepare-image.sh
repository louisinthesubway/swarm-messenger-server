#!/usr/bin/env bash
# SWARM Messenger staging - stage exactly what the storage service image needs into storage/build/.
#
# Run after building swarm-storage-service and before `docker compose build storage`:
#
#   (cd /opt/swarm/swarm-storage-service && ./mvnw -B -DskipTests package)
#   ./storage/prepare-image.sh [/opt/swarm/swarm-storage-service]
#
# The build leaves a thin jar (target/StorageService-<version>.jar) and its runtime dependencies
# (target/lib/, maven-dependency-plugin's copy-dependencies, runtime scope). This copies both to
# fixed names, so the Dockerfile's COPY lines never depend on a version string or a glob, and the
# Docker build context stays this one directory. Same idea as ../prepare-image.sh for the chat
# image. Prints the source commit and the jar's sha256.
set -euo pipefail

cd "$(dirname "$0")"

die() { printf '%s\n' "$*" >&2; exit 1; }

SRC="${1:-/opt/swarm/swarm-storage-service}"
TARGET="${SRC}/target"

JAR="$(ls -t "${TARGET}"/StorageService-*.jar 2>/dev/null \
  | grep -v -- '-tests\.jar$' | grep -v -- '-sources\.jar$' | head -1 || true)"
[ -n "${JAR}" ] && [ -f "${JAR}" ] || die "No StorageService jar in ${TARGET}. Build it first:
  (cd ${SRC} && ./mvnw -B -DskipTests package)"

ls "${TARGET}"/lib/*.jar >/dev/null 2>&1 || die "${TARGET}/lib has no jars. It is filled by the build
(maven-dependency-plugin copy-dependencies); rebuild with ./mvnw -B -DskipTests package."

rm -rf build
mkdir -p build/lib
cp -f "${JAR}" build/storage-service.jar
cp -f "${TARGET}"/lib/*.jar build/lib/

commit="$(git -C "${SRC}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
cat <<EOF
staged into $(pwd)/build from ${SRC} (commit ${commit}):
  storage-service.jar  <- $(basename "${JAR}")  sha256 $(sha256sum build/storage-service.jar | cut -d' ' -f1)
  lib/                 <- $(ls build/lib | wc -l) runtime dependency jars, $(du -sh build/lib | cut -f1)
next: docker compose build storage
EOF
