#!/bin/bash
# SWARM Messenger staging: create the DynamoDB table of the calling frontend (group calls).
# docs/STAGING.md, section 5d. Idempotent: an existing table is left alone.
#
# The frontend keeps one row per active group call (which backend, which era, who created it) and,
# for call links, one row per link. The schema is upstream's own, from Signal-Calling-Service's
# docker/bootstrap/src/main.rs (the table its local docker-compose.yml creates as "Rooms"):
#   key          roomId (S, HASH) + recordType (S, RANGE)
#   index        region-index: region (S, HASH) + recordType (S, RANGE), projection ALL
#   throughput   5/1, index 10/1 (ignored by DynamoDB Local)
# plus a TTL on deleteAt, the attribute upstream's call-link records carry for their deletion time
# (frontend/src/storage.rs), so expired call links actually go away.
#
# Runs against the stack's DynamoDB Local (-sharedDb: every key and region see the same tables),
# in the same image as dynamodb-bootstrap.

set -uo pipefail

ENDPOINT="${DYNAMODB_ENDPOINT:-http://dynamodb:8000}"
TABLE="${CALLING_TABLE:-swarm_calling_rooms}"

aws_ddb() { aws dynamodb --endpoint-url "${ENDPOINT}" "$@"; }

echo "waiting for DynamoDB at ${ENDPOINT} ..."
for i in $(seq 1 60); do
  if aws_ddb list-tables >/dev/null 2>&1; then
    break
  fi
  if [ "${i}" = 60 ]; then
    echo "DynamoDB did not answer" >&2
    exit 1
  fi
  sleep 2
done

if aws_ddb describe-table --table-name "${TABLE}" >/dev/null 2>&1; then
  echo "  = ${TABLE} (exists)"
else
  aws_ddb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions \
      AttributeName=roomId,AttributeType=S \
      AttributeName=recordType,AttributeType=S \
      AttributeName=region,AttributeType=S \
    --key-schema \
      AttributeName=roomId,KeyType=HASH \
      AttributeName=recordType,KeyType=RANGE \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=1 \
    --global-secondary-indexes '[{"IndexName":"region-index","KeySchema":[{"AttributeName":"region","KeyType":"HASH"},{"AttributeName":"recordType","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"},"ProvisionedThroughput":{"ReadCapacityUnits":10,"WriteCapacityUnits":1}}]' \
    >/dev/null || { echo "  ! ${TABLE}: create-table failed" >&2; exit 1; }
  echo "  + ${TABLE}"
fi

ttl="$(aws_ddb describe-time-to-live --table-name "${TABLE}" \
  --query 'TimeToLiveDescription.TimeToLiveStatus' --output text 2>/dev/null || true)"
if [ "${ttl}" = "ENABLED" ]; then
  echo "  = ${TABLE}: TTL on deleteAt (enabled)"
else
  aws_ddb update-time-to-live --table-name "${TABLE}" \
    --time-to-live-specification Enabled=true,AttributeName=deleteAt >/dev/null \
    || { echo "  ! ${TABLE}: update-time-to-live failed" >&2; exit 1; }
  echo "  + ${TABLE}: TTL on deleteAt"
fi
echo "calling table ready"
