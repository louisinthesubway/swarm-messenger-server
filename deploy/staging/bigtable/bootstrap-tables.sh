#!/bin/sh
# SWARM Messenger staging - create the storage service's four Bigtable tables in the emulator.
#
# Runs as the `bigtable-bootstrap` one-shot (docker-compose.yml) with the emulator image, which
# carries Google's `cbt` tool. cbt honours BIGTABLE_EMULATOR_HOST: no credentials, no Google
# Cloud project. Idempotent: a table or column family that exists is left alone, so it is safe
# to run on every `docker compose up` (the emulator keeps its tables on the bigtable-data volume).
#
# Where the names come from (keep all three in step):
#   table ids      deploy/staging/storage.yml, `bigtable:` block (contactManifestsTableId,
#                  contactsTableId, groupsTableId, groupLogsTableId)
#   column family  the FAMILY constant of each table class in swarm-storage-service
#                  (src/main/java/org/signal/storageservice/storage/):
#                    GroupsTable "g", GroupLogTable "l", StorageItemsTable "c",
#                    StorageManifestsTable "m"
#   GC rule        none, as in upstream's own test fixture (BigtableEmulatorExtension). Every
#                  write uses cell timestamp 0, so a cell is overwritten, never versioned.
#
# The project and instance ids are labels the emulator does not check; they must equal
# bigtable.projectId / bigtable.instanceId in storage.yml.
set -eu

: "${BIGTABLE_EMULATOR_HOST:?must name the emulator (bigtable:8086); refusing to run against real Bigtable}"
PROJECT="${SWARM_BIGTABLE_PROJECT_ID:-swarm-staging}"
INSTANCE="${SWARM_BIGTABLE_INSTANCE_ID:-swarm-staging}"

cbt_() { cbt -project "${PROJECT}" -instance "${INSTANCE}" "$@"; }

echo "[bigtable-bootstrap] emulator ${BIGTABLE_EMULATOR_HOST}, project ${PROJECT}, instance ${INSTANCE}"

tries=0
until cbt_ ls >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "${tries}" -ge 60 ]; then
    echo "[bigtable-bootstrap] the emulator did not answer within 60 s" >&2
    cbt_ ls >&2 || true
    exit 1
  fi
  sleep 1
done

tables="$(cbt_ ls)"

for spec in \
  swarm_storage_groups:g \
  swarm_storage_group_logs:l \
  swarm_storage_contacts:c \
  swarm_storage_manifests:m
do
  table="${spec%%:*}"
  family="${spec##*:}"

  if printf '%s\n' "${tables}" | grep -qx "${table}"; then
    echo "  = ${table}"
  else
    cbt_ createtable "${table}"
    echo "  + ${table}"
  fi

  # `cbt ls <table>` prints a two-line header, then one "<family> <gc policy>" line per family.
  if cbt_ ls "${table}" | awk '{ print $1 }' | grep -qx "${family}"; then
    echo "      = family ${family}"
  else
    cbt_ createfamily "${table}" "${family}"
    echo "      + family ${family}"
  fi
done

echo "[bigtable-bootstrap] done: $(cbt_ ls | wc -l) table(s)"
