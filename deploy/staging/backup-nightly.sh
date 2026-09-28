#!/bin/bash
# SWARM Messenger chat host - nightly snapshot of the data volumes.
#
# Written 2026-09-28 (Messenger planner) for the first public desktop release.
# Data at stake, all small today: DynamoDB Local (accounts, keys, profiles,
# usernames), FoundationDB (messages and the rest of the chat state), MinIO
# (encrypted attachments and profile photos), redis-messages (the message
# cache), and since 2026-09-28 the Bigtable emulator's volume (groups, group
# change logs, settings/contacts sync records of the storage service). It is
# a LOCAL snapshot on the same disk: it protects against an operator mistake
# or a bad deploy, not against losing the host. Copying it off the host needs
# a destination the owner chooses (see docs/STAGING.md).
#
# Consistency: the chat server is stopped for the copy (about one minute,
# users reconnect by themselves), so nothing writes while the volumes are
# read. DynamoDB Local is copied through sqlite3's online backup; the other
# volumes are tarred. The chat container is started again whatever happens.
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

docker compose stop -t 30 chat >/dev/null 2>&1 && echo "chat stopped"

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

# FoundationDB, MinIO, redis-messages: plain tars while the chat server is stopped.
for v in fdb-data minio-data redis-messages-data; do
  src=$(vol "$v")
  tar -C "$src" -czf "$out/$v.tgz" . && echo "$v: $(du -h "$out/$v.tgz" | cut -f1)"
done

# Bigtable emulator (storage service: groups, group logs, sync records): LevelDB
# files, so the emulator is stopped for the copy (a few seconds; the storage
# service reconnects by itself) and started again whatever happens.
if docker volume inspect "${PROJECT}_bigtable-data" >/dev/null 2>&1; then
  docker compose stop -t 10 bigtable >/dev/null 2>&1 && echo "bigtable stopped"
  src=$(vol bigtable-data)
  tar -C "$src" -czf "$out/bigtable-data.tgz" . && echo "bigtable-data: $(du -h "$out/bigtable-data.tgz" | cut -f1)"
  docker compose start bigtable >/dev/null 2>&1 && echo "bigtable started"
fi

docker compose start chat >/dev/null 2>&1 && echo "chat started"

# Keep the last KEEP_DAYS days.
find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +$KEEP_DAYS -exec rm -rf {} + 2>/dev/null
echo "[$ts] snapshot done: $out ($(du -sh "$out" | cut -f1))"
