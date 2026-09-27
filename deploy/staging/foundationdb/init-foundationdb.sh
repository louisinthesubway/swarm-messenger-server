#!/bin/bash
# SWARM Messenger staging — one-shot FoundationDB database creation.
#
# The foundationdb/foundationdb image starts fdbserver but does not create a database;
# a new cluster has no database until "configure new" is run once. This script is
# idempotent: if a database already exists, "configure new" fails and we exit 0.
set -u

CLUSTER_FILE="${FDB_CLUSTER_FILE:-/var/fdb/etc/fdb.cluster}"
export FDB_CLUSTER_FILE="${CLUSTER_FILE}"

echo "[fdb-init] waiting for cluster file ${CLUSTER_FILE}"
for _ in $(seq 1 60); do
  [ -s "${CLUSTER_FILE}" ] && break
  sleep 1
done

if [ ! -s "${CLUSTER_FILE}" ]; then
  echo "[fdb-init] FAILED: no cluster file at ${CLUSTER_FILE} after 60s" >&2
  exit 1
fi

echo "[fdb-init] cluster file: $(cat "${CLUSTER_FILE}")"

echo "[fdb-init] waiting for a coordinator to answer"
for _ in $(seq 1 60); do
  if fdbcli --exec "status minimal" --timeout 5 2>&1 | grep -qE "available|unavailable"; then
    break
  fi
  sleep 2
done

if fdbcli --exec "status minimal" --timeout 10 2>&1 | grep -q "The database is available"; then
  echo "[fdb-init] database already exists and is available; nothing to do"
  exit 0
fi

# Single process, ssd storage engine. Correct for one staging host. A production
# deployment wants "double" or "triple" redundancy across separate machines.
echo "[fdb-init] creating database: configure new single ssd"
fdbcli --exec "configure new single ssd" --timeout 60 || true

echo "[fdb-init] waiting for the database to become available"
for _ in $(seq 1 60); do
  if fdbcli --exec "status minimal" --timeout 10 2>&1 | grep -q "The database is available"; then
    echo "[fdb-init] database is available"
    fdbcli --exec "status" --timeout 20 | head -30
    exit 0
  fi
  sleep 2
done

echo "[fdb-init] FAILED: database did not become available" >&2
fdbcli --exec "status" --timeout 20 >&2 || true
exit 1
