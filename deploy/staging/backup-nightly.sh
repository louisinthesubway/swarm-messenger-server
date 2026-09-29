#!/bin/bash
# SWARM Messenger chat host - nightly snapshot of the data volumes.
#
# Written 2026-09-28 (Messenger planner) for the first public desktop release.
# Data at stake, all small today: DynamoDB Local (accounts, keys, profiles,
# usernames), FoundationDB (messages and the rest of the chat state, and since
# 2026-09-29 the storage service's groups, group change logs and settings/
# contacts sync records), MinIO (encrypted attachments and profile photos),
# redis-messages (the message cache), and the Bigtable emulator's volume (the
# storage service's data until 2026-09-29, kept until the emulator goes). It is
# a LOCAL snapshot on the same disk: it protects against an operator mistake
# or a bad deploy, not against losing the host. Copying it off the host needs
# a destination the owner chooses (see docs/STAGING.md).
#
# Consistency: the chat server and the storage service are stopped for the
# copy (about one minute; users reconnect by themselves, groups and settings
# sync pause), so nothing writes while the volumes are read: both keep their
# data in FoundationDB (fdb-data). FoundationDB itself keeps writing its own
# files even with no client, so the foundationdb container is stopped too
# while fdb-data is tarred and started again right after (since 2026-09-29):
# a copy of a stopped fdbserver's files is what FoundationDB recovers from
# after any stop, so it is consistent. DynamoDB Local is copied through
# sqlite3's online backup; the other volumes are tarred. Whatever ran before
# (all of them, if that cannot be told) is started again whatever happens, also
# from an EXIT trap, FoundationDB first; one an operator had stopped stays
# stopped.
#
# Usage:  bash /opt/swarm/swarm-messenger-server/deploy/staging/backup-nightly.sh
# Cron:   10 4 * * * root bash /opt/swarm/swarm-messenger-server/deploy/staging/backup-nightly.sh >> /root/backups/backup.log 2>&1
set -u
STAGING=/opt/swarm/swarm-messenger-server/deploy/staging
DEST=/root/backups
KEEP_DAYS=7
PROJECT=swarm-messenger-staging
FDB_START_TIMEOUT=180
ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$DEST/$ts"
mkdir -p "$out"
echo "[$ts] snapshot start"
cd "$STAGING" || { echo "no $STAGING"; exit 1; }

now() { date -u +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }
stamp() { date -u +%T; }

# What ran before: chat and storage write to FoundationDB; foundationdb is the database.
running=$(docker compose ps --status running --services 2>/dev/null) \
  || running=$'chat\nstorage\nfoundationdb'
was_running() { printf '%s\n' "$running" | grep -qx "$1"; }
to_start=""
for s in storage chat; do
  was_running "$s" && to_start="$to_start $s"
done

fdb_available() {
  docker compose exec -T foundationdb fdbcli --exec 'status minimal' --timeout 5 2>/dev/null \
    | grep -q 'The database is available'
}

fdb_stopped=0
fdb_started_again=0
fdb_start_again() {
  [ "$fdb_stopped" = 1 ] && [ "$fdb_started_again" = 0 ] || return 0
  fdb_started_again=1
  local t0
  t0=$(now)
  docker compose start foundationdb >/dev/null 2>&1 || echo "$(stamp) foundationdb: start FAILED"
  while ! fdb_available; do
    if awk -v s="$(since "$t0")" -v m="$FDB_START_TIMEOUT" 'BEGIN { exit !(s > m) }'; then
      echo "$(stamp) foundationdb NOT available after ${FDB_START_TIMEOUT} s; starting the rest anyway"
      return 0
    fi
    sleep 1
  done
  echo "$(stamp) foundationdb started again, database available after $(since "$t0") s"
}

started_again=0
start_again() {
  [ "$started_again" = 1 ] && return
  started_again=1
  fdb_start_again
  [ -n "$to_start" ] || return 0
  docker compose start $to_start >/dev/null 2>&1 && echo "$(stamp) started again:$to_start"
}
trap start_again EXIT

docker compose stop -t 30 chat storage >/dev/null 2>&1 \
  && echo "$(stamp) chat and storage stopped (were running:${to_start:- none})"

vol() { docker volume inspect "${PROJECT}_$1" --format '{{.Mountpoint}}'; }

# tar exits 1 when a file changed while it was read; its warnings go to this log too.
archive() { # volume
  local src rc
  src=$(vol "$1")
  tar -C "$src" -czf "$out/$1.tgz" .
  rc=$?
  echo "$1.tgz: $(du -h "$out/$1.tgz" 2>/dev/null | cut -f1)$([ "$rc" -ne 0 ] && echo " (tar exit $rc)")"
}

# DynamoDB Local: sqlite databases, copied with the online backup API.
dyn=$(vol dynamodb-data)
mkdir -p "$out/dynamodb"
for db in "$dyn"/*.db; do
  [ -e "$db" ] || continue
  docker run --rm -v "$dyn":/src:ro -v "$out/dynamodb":/dst alpine/sqlite:latest \
    sqlite3 "/src/$(basename "$db")" ".backup /dst/$(basename "$db")" 2>/dev/null \
  || cp -a "$db" "$out/dynamodb/"
done
echo "dynamodb/: $(ls "$out/dynamodb" | wc -l) file(s), $(du -sh "$out/dynamodb" | cut -f1)"

# FoundationDB: its files only hold still while fdbserver is stopped (no client runs now).
if was_running foundationdb; then
  t_fdb=$(now)
  docker compose stop -t 60 foundationdb >/dev/null 2>&1 && fdb_stopped=1 \
    && echo "$(stamp) foundationdb stopped in $(since "$t_fdb") s"
fi
archive fdb-data
fdb_start_again

# MinIO and redis-messages: plain tars while their servers run (with chat stopped no client
# writes; a change by the server itself would show up as a tar warning and exit status here).
archive minio-data
archive redis-messages-data

# Bigtable emulator (the storage service's data until its switch to FoundationDB,
# kept until the emulator is removed): LevelDB files, so the emulator is stopped
# for the copy (a few seconds) and started again whatever happens.
if docker volume inspect "${PROJECT}_bigtable-data" >/dev/null 2>&1; then
  docker compose stop -t 10 bigtable >/dev/null 2>&1 && echo "$(stamp) bigtable stopped"
  archive bigtable-data
  docker compose start bigtable >/dev/null 2>&1 && echo "$(stamp) bigtable started"
fi

start_again

# Keep the last KEEP_DAYS days.
find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +$KEEP_DAYS -exec rm -rf {} + 2>/dev/null
echo "[$ts] snapshot done: $out ($(du -sh "$out" | cut -f1))"
