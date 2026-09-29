#!/usr/bin/env bash
# SWARM Messenger staging - stage exactly what the storage service image needs into storage/build/.
#
# Run after building swarm-storage-service and before `docker compose build storage`:
#
#   (cd /opt/swarm/swarm-storage-service && ./mvnw -B -DskipTests package)
#   ./storage/prepare-image.sh [/opt/swarm/swarm-storage-service]
#
# The build leaves a thin jar (target/StorageService-<version>.jar), its runtime dependencies
# (target/lib/, maven-dependency-plugin's copy-dependencies, runtime scope) and, since the
# FoundationDB backend, the FoundationDB client library (target/jib-extra/usr/lib/libfdb_c.so,
# downloaded and checksummed by the build). This copies all three to fixed names, so the
# Dockerfile's COPY lines never depend on a version string or a glob, and the Docker build context
# stays this one directory. Same idea as ../prepare-image.sh for the chat image. Prints the source
# commit and the sha256 of the jar and of the client library.
set -euo pipefail

cd "$(dirname "$0")"

die() { printf '%s\n' "$*" >&2; exit 1; }

SRC="${1:-/opt/swarm/swarm-storage-service}"
TARGET="${SRC}/target"

# FoundationDB client 7.3.76 (libfdb_c.x86_64.so), the version of the stack's FoundationDB server.
# The same checksum as foundationdb.client-library-sha256 in the fork's pom.xml and in this
# repository's pom.xml (the chat image's copy).
FDB_CLIENT_SHA256="af099848721d08904ff9e5d38fade0de24d92e86451ea491d9ab5ce84adcf62a"

JAR="$(ls -t "${TARGET}"/StorageService-*.jar 2>/dev/null \
  | grep -v -- '-tests\.jar$' | grep -v -- '-sources\.jar$' | head -1 || true)"
[ -n "${JAR}" ] && [ -f "${JAR}" ] || die "No StorageService jar in ${TARGET}. Build it first:
  (cd ${SRC} && ./mvnw -B -DskipTests package)"

ls "${TARGET}"/lib/*.jar >/dev/null 2>&1 || die "${TARGET}/lib has no jars. It is filled by the build
(maven-dependency-plugin copy-dependencies); rebuild with ./mvnw -B -DskipTests package."

FDB_LIB="${TARGET}/jib-extra/usr/lib/libfdb_c.so"
[ -s "${FDB_LIB}" ] || die "${FDB_LIB} is missing. The fork's build downloads it at prepare-package
(download-maven-plugin, since the FoundationDB backend); rebuild a current checkout with
./mvnw -B -DskipTests package."
echo "${FDB_CLIENT_SHA256}  ${FDB_LIB}" | sha256sum -c --quiet - \
  || die "${FDB_LIB} does not have the pinned SHA-256 ${FDB_CLIENT_SHA256}."

rm -rf build
mkdir -p build/lib
cp -f "${JAR}" build/storage-service.jar
cp -f "${TARGET}"/lib/*.jar build/lib/
cp -f "${FDB_LIB}" build/libfdb_c.so

commit="$(git -C "${SRC}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
cat <<EOF
staged into $(pwd)/build from ${SRC} (commit ${commit}):
  storage-service.jar  <- $(basename "${JAR}")  sha256 $(sha256sum build/storage-service.jar | cut -d' ' -f1)
  lib/                 <- $(ls build/lib | wc -l) runtime dependency jars, $(du -sh build/lib | cut -f1)
  libfdb_c.so          <- FoundationDB client 7.3.76  sha256 $(sha256sum build/libfdb_c.so | cut -d' ' -f1)
next: docker compose build storage
EOF
