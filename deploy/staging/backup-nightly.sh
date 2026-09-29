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
# data in FoundationDB (fdb-data). DynamoDB Local is copied through sqlite3's
# online backup; the other volumes are tarred. Whichever of the two was running
# before (both, if that cannot be told) is started again whatever happens, also
# from an EXIT trap; one an operator had stopped stays stopped.
#
# Usage:  bash /opt/swarm/swarm-messenger-server/deploy/staging/backup-nightly.sh
# Cron:   10 4 * * * root bash /opt/swarm/swarm-messenger-server/deploy/staging/backup-nightly.sh >> /root/backups/backup.log 2>&1
set -u
STAGING=/opt/swarm/swarm-messenger-server/deploy/staging
DEST=/root/backups
KEEP_DAYS=7
PROJECT=swarm-messenger-staging
ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$DEST/$ts"
mkdir -p "$out"
echo "[$ts] snapshot start"
cd "$STAGING" || { echo "no $STAGING"; exit 1; }

# chat and storage both write to FoundationDB; stop both, start again what ran.
running=$(docker compose ps --status running --services 2>/dev/null) || running=$'chat\nstorage'
to_start=""
for s in storage chat; do
  printf '%s\n' "$running" | grep -qx "$s" && to_start="$to_start $s"
done
started_again=0
start_again() {
  [ "$started_again" = 1 ] && return
  started_again=1
  [ -n "$to_start" ] || return 0
  docker compose start $to_start >/dev/null 2>&1 && echo "started again:$to_start"
}
trap start_again EXIT

docker compose stop -t 30 chat storage >/dev/null 2>&1 && echo "chat and storage stopped (were running:${to_start:- none})"

vol() { docker volume inspect "${PROJECT}_$1" --format '{{.Mountpoint}}'; }

# DynamoDB Local: sqlite databases, copied with the online backup API.
dyn=$(vol dynamodb-data)
mkdir -p "$out/dynamodb"
for db in "$dyn"/*.db; do
  [ -e "$db" ] || continue
  docker run --rm -v "$dyn":/src:ro -v "$out/dynamodb":/dst alpine/sqlite:latest \
    sqlite3 "/src/$(basename "$db")" ".backup /dst/$(basename "$db")" 2>/dev/null \
  || cp -a "$db" "$out/dynamodb/"
done
echo "dynamodb: $(ls "$out/dynamodb" | wc -l) file(s)"

# FoundationDB, MinIO, redis-messages: plain tars while chat and storage are stopped.
# tar exits 1 when a file changed while it was read: fdbserver keeps writing its own files.
for v in fdb-data minio-data redis-messages-data; do
  src=$(vol "$v")
  tar -C "$src" -czf "$out/$v.tgz" .
  rc=$?
  echo "$v: $(du -h "$out/$v.tgz" 2>/dev/null | cut -f1)$([ "$rc" -ne 0 ] && echo " (tar exit $rc)")"
done

# Bigtable emulator (the storage service's data until its switch to FoundationDB,
# kept until the emulator is removed): LevelDB files, so the emulator is stopped
# for the copy (a few seconds) and started again whatever happens.
if docker volume inspect "${PROJECT}_bigtable-data" >/dev/null 2>&1; then
  docker compose stop -t 10 bigtable >/dev/null 2>&1 && echo "bigtable stopped"
  src=$(vol bigtable-data)
  tar -C "$src" -czf "$out/bigtable-data.tgz" . && echo "bigtable-data: $(du -h "$out/bigtable-data.tgz" | cut -f1)"
  docker compose start bigtable >/dev/null 2>&1 && echo "bigtable started"
fi

start_again

# Keep the last KEEP_DAYS days.
find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +$KEEP_DAYS -exec rm -rf {} + 2>/dev/null
echo "[$ts] snapshot done: $out ($(du -sh "$out" | cut -f1))"
