#!/bin/sh
# SWARM Messenger staging — run ONE Redis node in cluster mode and own every hash slot.
#
# The chat server talks to Redis through Lettuce's cluster client, so each of the four
# "clusters" must answer CLUSTER commands and report cluster_state:ok. `redis-cli --cluster
# create` refuses anything under three masters, so this script does the one thing the
# creator would have done: start the node with cluster mode on and assign slots 0-16383 to
# it. Idempotent: on restart the node reads nodes.conf and already owns the slots.
#
# Env: REDIS_ANNOUNCE_IP (required) — the fixed compose-network address of this node.
#      REDIS_PERSIST=yes  — keep an append-only file on the data volume (messages cache);
#                           anything else runs fully in memory (cache, rate limiters, push scheduler).
set -eu
: "${REDIS_ANNOUNCE_IP:?set REDIS_ANNOUNCE_IP}"
mkdir -p /data
cd /data

set -- redis-server \
  --port 6379 \
  --bind 0.0.0.0 \
  --protected-mode no \
  --cluster-enabled yes \
  --cluster-config-file nodes.conf \
  --cluster-node-timeout 5000 \
  --cluster-announce-ip "${REDIS_ANNOUNCE_IP}" \
  --dir /data

if [ "${REDIS_PERSIST:-no}" = "yes" ]; then
  set -- "$@" --appendonly yes --save "60 1000"
else
  set -- "$@" --appendonly no --save ""
fi

"$@" &
pid=$!

i=0
until redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -q PONG; do
  i=$((i + 1))
  [ "${i}" -lt 60 ] || { echo "[redis-single] redis-server did not answer in 60s" >&2; exit 1; }
  sleep 1
done

if redis-cli -h 127.0.0.1 cluster info | grep -q 'cluster_state:ok'; then
  echo "[redis-single] slots already assigned (cluster_state:ok)"
else
  # ADDSLOTSRANGE exists since Redis 7.0. "Slot already busy" only means a partial earlier run.
  redis-cli -h 127.0.0.1 cluster addslotsrange 0 16383 >/dev/null 2>&1 || true
  j=0
  until redis-cli -h 127.0.0.1 cluster info | grep -q 'cluster_state:ok'; do
    j=$((j + 1))
    [ "${j}" -lt 30 ] || { echo "[redis-single] cluster_state never became ok" >&2; redis-cli -h 127.0.0.1 cluster info; exit 1; }
    sleep 1
  done
  echo "[redis-single] assigned slots 0-16383 to this node"
fi

wait "${pid}"
