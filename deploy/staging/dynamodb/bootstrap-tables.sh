#!/bin/bash
# SWARM Messenger staging — create every DynamoDB table named in staging.yml.
#
# Runs against DynamoDB Local (or any DynamoDB-compatible endpoint) with the AWS CLI.
# Idempotent: a table that already exists is left alone.
#
# PROVENANCE OF THE SCHEMAS
# ------------------------------------------------------------------------------------
# Key schemas, attribute types, index names and TTL attributes below are taken from
# upstream code, not invented here. For every table the comment names the Java class
# and constant the attribute name comes from. The test fixture that creates the same
# tables for the upstream test suite is
#   service/src/test/java/org/whispersystems/textsecuregcm/storage/DynamoDbExtensionSchema.java
# and the table-name -> role mapping is
#   service/src/main/java/org/whispersystems/textsecuregcm/configuration/DynamoDbTables.java
#
# Attribute types: B = binary, S = string, N = number.
# TTL: upstream's test fixture does not enable TTL (tests do not need expiry). Staging
# does, so rows named "expiration"/TTL in the code actually disappear. The TTL attribute
# name is taken from the class that writes it.
#
# Provisioned throughput is ignored by DynamoDB Local; the values mirror the upstream
# test fixture (20/20) so the same script can be pointed at a real DynamoDB if ever needed.

set -uo pipefail

ENDPOINT="${DYNAMODB_ENDPOINT:-http://dynamodb:8000}"
PREFIX="${SWARM_TABLE_PREFIX:-swarm_}"
THROUGHPUT="ReadCapacityUnits=20,WriteCapacityUnits=20"

created=0
existing=0
failed=0

aws_ddb() { aws dynamodb --endpoint-url "${ENDPOINT}" "$@"; }

table_exists() {
  aws_ddb describe-table --table-name "$1" >/dev/null 2>&1
}

# mk <bare-name> <hash-attr> <hash-type> [<range-attr> <range-type>]
mk() {
  local bare="$1"; shift
  local name="${PREFIX}${bare}"
  local hk="$1" ht="$2"; shift 2

  if table_exists "${name}"; then
    echo "  = ${name} (exists)"
    existing=$((existing + 1))
    return 0
  fi

  local key_schema="AttributeName=${hk},KeyType=HASH"
  local attr_defs="AttributeName=${hk},AttributeType=${ht}"

  if [ "$#" -ge 2 ]; then
    local rk="$1" rt="$2"; shift 2
    key_schema="${key_schema} AttributeName=${rk},KeyType=RANGE"
    attr_defs="${attr_defs} AttributeName=${rk},AttributeType=${rt}"
  fi

  if aws_ddb create-table \
      --table-name "${name}" \
      --key-schema ${key_schema} \
      --attribute-definitions ${attr_defs} \
      --provisioned-throughput "${THROUGHPUT}" >/dev/null; then
    echo "  + ${name}"
    created=$((created + 1))
  else
    echo "  ! ${name} FAILED" >&2
    failed=$((failed + 1))
  fi
}

# mk_json <bare-name> <json>  — for tables that need a global secondary index
mk_json() {
  local bare="$1"; shift
  local name="${PREFIX}${bare}"

  if table_exists "${name}"; then
    echo "  = ${name} (exists)"
    existing=$((existing + 1))
    return 0
  fi

  if printf '%s' "$1" | sed "s/@@TABLE@@/${name}/g" > /tmp/table.json &&
     aws_ddb create-table --cli-input-json "file:///tmp/table.json" >/dev/null; then
    echo "  + ${name} (with GSI)"
    created=$((created + 1))
  else
    echo "  ! ${name} FAILED" >&2
    failed=$((failed + 1))
  fi
}

# ttl <bare-name> <attribute>
ttl() {
  local name="${PREFIX}$1"
  local attr="$2"
  local enabled
  enabled="$(aws_ddb describe-time-to-live --table-name "${name}" \
    --query 'TimeToLiveDescription.TimeToLiveStatus' --output text 2>/dev/null)"
  if [ "${enabled}" = "ENABLED" ]; then
    echo "  = ttl ${name}.${attr} (enabled)"
    return 0
  fi
  if aws_ddb update-time-to-live --table-name "${name}" \
      --time-to-live-specification "Enabled=true,AttributeName=${attr}" >/dev/null 2>&1; then
    echo "  + ttl ${name}.${attr}"
  else
    echo "  ~ ttl ${name}.${attr} could not be enabled (harmless: rows simply do not expire)"
  fi
}

echo "[ddb-bootstrap] endpoint=${ENDPOINT} prefix=${PREFIX}"
echo "[ddb-bootstrap] waiting for DynamoDB"
for _ in $(seq 1 60); do
  aws_ddb list-tables >/dev/null 2>&1 && break
  sleep 2
done
if ! aws_ddb list-tables >/dev/null 2>&1; then
  echo "[ddb-bootstrap] FAILED: ${ENDPOINT} did not answer" >&2
  exit 1
fi

echo "[ddb-bootstrap] creating tables"

# ---------------------------------------------------------------- accounts family
# accounts.tableName — Accounts.KEY_ACCOUNT_UUID "U" (B);
#   GSI "ul_to_u" (Accounts.USERNAME_LINK_TO_UUID_INDEX) on Accounts.ATTR_USERNAME_LINK_UUID "UL" (B)
mk_json accounts '{
  "TableName": "@@TABLE@@",
  "KeySchema": [{"AttributeName": "U", "KeyType": "HASH"}],
  "AttributeDefinitions": [
    {"AttributeName": "U", "AttributeType": "B"},
    {"AttributeName": "UL", "AttributeType": "B"}
  ],
  "GlobalSecondaryIndexes": [{
    "IndexName": "ul_to_u",
    "KeySchema": [{"AttributeName": "UL", "KeyType": "HASH"}],
    "Projection": {"ProjectionType": "KEYS_ONLY"},
    "ProvisionedThroughput": {"ReadCapacityUnits": 10, "WriteCapacityUnits": 10}
  }],
  "ProvisionedThroughput": {"ReadCapacityUnits": 20, "WriteCapacityUnits": 20}
}'

# accounts.phoneNumberTableName — Accounts.ATTR_ACCOUNT_E164 "P" (S)
mk numbers P S

# accounts.phoneNumberIdentifierTableName — Accounts.ATTR_PNI_UUID "PNI" (B)
mk pni_assignment PNI B

# accounts.usernamesTableName — Accounts.ATTR_USERNAME_HASH "N" (B); ttl Accounts.UsernameTable.ATTR_TTL "TTL"
mk usernames N B

# accounts.usedLinkDeviceTokensTableName — Accounts.KEY_LINK_DEVICE_TOKEN_HASH "H" (B);
#   ttl Accounts.ATTR_LINK_DEVICE_TOKEN_TTL "E"
mk used_link_device_tokens H B

# deletedAccounts — Accounts.DELETED_ACCOUNTS_KEY_ACCOUNT_PNI "P" (S);
#   GSI "u_to_p" on Accounts.DELETED_ACCOUNTS_ATTR_ACCOUNT_UUID "U" (B);
#   ttl Accounts.DELETED_ACCOUNTS_ATTR_EXPIRES "E"
mk_json deleted_accounts '{
  "TableName": "@@TABLE@@",
  "KeySchema": [{"AttributeName": "P", "KeyType": "HASH"}],
  "AttributeDefinitions": [
    {"AttributeName": "P", "AttributeType": "S"},
    {"AttributeName": "U", "AttributeType": "B"}
  ],
  "GlobalSecondaryIndexes": [{
    "IndexName": "u_to_p",
    "KeySchema": [{"AttributeName": "U", "KeyType": "HASH"}],
    "Projection": {"ProjectionType": "KEYS_ONLY"},
    "ProvisionedThroughput": {"ReadCapacityUnits": 10, "WriteCapacityUnits": 10}
  }],
  "ProvisionedThroughput": {"ReadCapacityUnits": 20, "WriteCapacityUnits": 20}
}'

# deletedAccountsLock — AccountLockManager.KEY_ACCOUNT_PNI "P" (S)
mk deleted_accounts_lock P S

# changeNumberWaitingPeriods — ChangeNumberWaitingPeriods.KEY_ACCOUNT_UUID "U" (B); ttl ATTR_TTL "E"
mk change_number_waiting_periods U B

# phoneNumberIdentifiers — PhoneNumberIdentifiers.KEY_E164 "P" (S);
#   GSI "pni_to_p" on ATTR_PHONE_NUMBER_IDENTIFIER "PNI" (B)
mk_json pni '{
  "TableName": "@@TABLE@@",
  "KeySchema": [{"AttributeName": "P", "KeyType": "HASH"}],
  "AttributeDefinitions": [
    {"AttributeName": "P", "AttributeType": "S"},
    {"AttributeName": "PNI", "AttributeType": "B"}
  ],
  "GlobalSecondaryIndexes": [{
    "IndexName": "pni_to_p",
    "KeySchema": [{"AttributeName": "PNI", "KeyType": "HASH"}],
    "Projection": {"ProjectionType": "KEYS_ONLY"},
    "ProvisionedThroughput": {"ReadCapacityUnits": 10, "WriteCapacityUnits": 10}
  }],
  "ProvisionedThroughput": {"ReadCapacityUnits": 20, "WriteCapacityUnits": 20}
}'

# ---------------------------------------------------------------- keys
# ecKeys — SingleUseECPreKeyStore KEY_ACCOUNT_UUID "U" (B) / KEY_DEVICE_ID_KEY_ID "DK" (B)
mk keys U B DK B
# ecSignedPreKeys — RepeatedUseSignedPreKeyStore KEY_ACCOUNT_UUID "U" (B) / KEY_DEVICE_ID "D" (N)
mk repeated_use_signed_ec_pre_keys U B D N
# pqLastResortKeys — same shape as ecSignedPreKeys
mk repeated_use_signed_kem_pre_keys U B D N
# pagedPqKeys — PagedSingleUseKEMPreKeyStore KEY_ACCOUNT_UUID "U" (B) / KEY_DEVICE_ID "D" (N)
mk paged_pq_keys U B D N

# ---------------------------------------------------------------- messages and profiles
# messages — MessagesDynamoDb KEY_PARTITION "H" (B) / KEY_SORT "S" (B); ttl KEY_TTL "E"
mk messages H B S B
# profiles (v1) — Profiles KEY_ACCOUNT_UUID "U" (B) / ATTR_VERSION "V" (S)
mk profiles U B V S
# profilesV2 — ProfilesV2 KEY_ACCOUNT_UUID "U" (B) / KEY_VERSION "V" (B)
mk profiles_v2 U B V B
# profileAvatars — ProfileAvatars KEY_IDENTITY "I" (B); ttl ATTR_TTL "E"
mk profile_avatars I B
# reportMessage — ReportMessageDynamoDb KEY_HASH "H" (B); ttl ATTR_TTL "E"
mk report_messages H B

# ---------------------------------------------------------------- registration and sessions
# verificationSessions — SerializedExpireableJsonDynamoStore KEY_KEY "K" (S); ttl ATTR_TTL "E"
mk verification_sessions K S
# registrationRecovery — PhoneNumberRecoveryPasswords KEY_PNI "P" (S); ttl ATTR_EXP "E"
mk registration_recovery_passwords P S
# pushChallenge — PushChallengeDynamoDb KEY_ACCOUNT_UUID "U" (B); ttl ATTR_TTL "T"
mk push_challenge U B

# ---------------------------------------------------------------- operational
# clientReleases — ClientReleases ATTR_PLATFORM "P" (S) / ATTR_VERSION "V" (S); ttl ATTR_EXPIRATION "E"
mk client_releases P S V S
# remoteConfig — RemoteConfigs KEY_NAME "N" (S)
mk remote_config N S
# scheduledJobs — JobScheduler KEY_SCHEDULER_NAME "S" (S) / ATTR_RUN_AT "T" (B); ttl ATTR_TTL "E"
mk scheduled_jobs S S T B
# pushNotificationExperimentSamples — PushNotificationExperimentSamples
#   KEY_EXPERIMENT_NAME "N" (S) / ATTR_ACI_AND_DEVICE_ID "AD" (B); ttl ATTR_TTL "E"
mk push_notification_experiment_samples N S AD B
# backups — BackupsDb KEY_BACKUP_ID_HASH "U" (B)
mk backups U B

# ---------------------------------------------------------------- device check (feature off, tables still required)
# appleDeviceChecks — AppleDeviceChecks KEY_ACCOUNT_UUID "U" (B) / KEY_PUBLIC_KEY_ID "KID" (B)
mk apple_device_check U B KID B
# appleDeviceCheckPublicKeys — AppleDeviceChecks KEY_PUBLIC_KEY "PK" (B)
mk apple_device_check_key_constraint PK B

# ---------------------------------------------------------------- donations and subscriptions
# (billing is disabled in staging — see docs/STAGING.md — but the tables are still named by
#  the configuration, and the server creates the managers unconditionally at startup.)
# donationPermits — DonationPermits KEY_SPEND_ID "I" (B); ttl KEY_EXPIRATION "E"
mk donation_permits I B
# issuedReceipts — IssuedReceiptsManager KEY_PROCESSOR_ITEM_ID "A" (S); ttl KEY_EXPIRATION "E"
mk issued_receipts A S
# onetimeDonations — OneTimeDonationsManager KEY_PAYMENT_ID "P" (S); ttl ATTR_TTL "E"
mk onetime_donations P S
# redeemedReceipts — RedeemedReceiptsManager KEY_SERIAL "S" (B); ttl ATTR_TTL "E"
mk redeemed_receipts S B
# subscriptions — Subscriptions KEY_USER "U" (B);
#   GSI "pc_to_u" on KEY_PROCESSOR_ID_CUSTOMER_ID "PC" (B)
mk_json subscriptions '{
  "TableName": "@@TABLE@@",
  "KeySchema": [{"AttributeName": "U", "KeyType": "HASH"}],
  "AttributeDefinitions": [
    {"AttributeName": "U", "AttributeType": "B"},
    {"AttributeName": "PC", "AttributeType": "B"}
  ],
  "GlobalSecondaryIndexes": [{
    "IndexName": "pc_to_u",
    "KeySchema": [{"AttributeName": "PC", "KeyType": "HASH"}],
    "Projection": {"ProjectionType": "KEYS_ONLY"},
    "ProvisionedThroughput": {"ReadCapacityUnits": 20, "WriteCapacityUnits": 20}
  }],
  "ProvisionedThroughput": {"ReadCapacityUnits": 20, "WriteCapacityUnits": 20}
}'

echo "[ddb-bootstrap] enabling TTL"
ttl usernames TTL
ttl used_link_device_tokens E
ttl deleted_accounts E
ttl change_number_waiting_periods E
ttl messages E
ttl profile_avatars E
ttl report_messages E
ttl verification_sessions E
ttl registration_recovery_passwords E
ttl push_challenge T
ttl client_releases E
ttl scheduled_jobs E
ttl push_notification_experiment_samples E
ttl donation_permits E
ttl issued_receipts E
ttl onetime_donations E
ttl redeemed_receipts E

echo "[ddb-bootstrap] tables now present:"
aws_ddb list-tables --output text | tr '\t' '\n' | grep -v '^TABLENAMES$' | sort | sed 's/^/  /'

echo "[ddb-bootstrap] created=${created} already-present=${existing} failed=${failed}"
[ "${failed}" -eq 0 ] || exit 1
