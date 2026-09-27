#!/usr/bin/env bash
# SWARM Messenger staging — stage exactly what the chat image needs into build/.
#
# Run this after `./mvnw -DskipTests -Pexclude-spam-filter package` and before
# `docker compose build chat`. bootstrap-host.sh does it for you.
#
# WHY IT EXISTS
# ------------------------------------------------------------------------------------------
# Two reasons, both about being exact rather than lucky.
#
# 1. The build produces several jars whose names all begin with TextSecureServer-: the shaded
#    one, a -tests one, and shade's original- copy. A wildcard COPY in a Dockerfile that
#    matches more than one source and names a single file as its destination is an error, and
#    which jar a glob picks is not something to leave to chance. This script resolves the
#    shaded jar by exclusion, prints its name and sha256, and copies it to one fixed name.
#
# 2. It keeps the Docker build context to two files. The alternative, using the repository root
#    as the context, ships every target/ directory to the daemon — over a gigabyte, most of it
#    irrelevant.
#
# Usage:  ./prepare-image.sh [path/to/TextSecureServer-<version>.jar]

set -euo pipefail

cd "$(dirname "$0")"

die() { printf '%s\n' "$*" >&2; exit 1; }

TARGET_DIR="../../service/target"

JAR="${1:-}"
if [ -z "${JAR}" ]; then
  JAR="$(ls -t "${TARGET_DIR}"/TextSecureServer-*.jar 2>/dev/null \
    | grep -v -- '-tests\.jar$' | grep -v '/original-' | head -1)"
fi

[ -n "${JAR}" ] && [ -f "${JAR}" ] || die "No server jar found. Build it from the repository root with:
  ./mvnw -DskipTests -Pexclude-spam-filter package
The -Pexclude-spam-filter profile is required: it runs the shade plugin and downloads
libfdb_c.so. Without it you get only the thin jar."

FDB_LIB="${TARGET_DIR}/jib-extra/usr/lib/libfdb_c.so"
[ -s "${FDB_LIB}" ] || die "${FDB_LIB} is missing. It is downloaded during prepare-package by the
exclude-spam-filter profile; rebuild with -Pexclude-spam-filter."

# A shaded jar is tens to hundreds of megabytes; the thin one is under ten. Catch the case where
# the profile was forgotten but an old libfdb_c.so happens to be lying around.
jar_bytes="$(wc -c < "${JAR}")"
if [ "${jar_bytes}" -lt 50000000 ]; then
  die "$(basename "${JAR}") is only ${jar_bytes} bytes, which is the thin jar, not the shaded one.
Rebuild with -Pexclude-spam-filter."
fi

mkdir -p build
cp -f "${JAR}" build/chat.jar
cp -f "${FDB_LIB}" build/libfdb_c.so

cat <<EOF
staged into $(pwd)/build:

  chat.jar        from $(basename "${JAR}")
                  $(wc -c < build/chat.jar) bytes
                  sha256 $(sha256sum build/chat.jar | cut -d' ' -f1)
  libfdb_c.so     FoundationDB client library
                  $(wc -c < build/libfdb_c.so) bytes
                  sha256 $(sha256sum build/libfdb_c.so | cut -d' ' -f1)

next: docker compose build chat
EOF
