#!/bin/sh
# SWARM Messenger staging: write deploy/staging/storage.env for the storage service
# (groups + settings/contacts sync), once. Prints no secret.
#
#   SWARM_STORAGE_AUTH_KEY_HEX           the same 32 bytes as this repository's
#                                        storageService.userAuthenticationTokenSharedSecret
#                                        (staging-secrets.yml, base64), written as hex because the
#                                        storage service reads authentication.key as hex. The chat
#                                        server signs the GET /v1/storage/auth credentials with it;
#                                        the storage service checks them. Same secret, two text
#                                        encodings. Wrong value: every /v1/storage call answers 401.
#   SWARM_STORAGE_ZK_SERVER_SECRET       this repository's groupsZkConfig.serverSecret
#                                        (staging-secrets.yml), copied verbatim: both services read
#                                        it as base64 ServerSecretParams. The chat server issues
#                                        group auth and profile key credentials with it and checks
#                                        group send endorsements; the storage service checks the
#                                        credentials and issues the endorsements. Wrong value: no
#                                        group call is authorised.
#   SWARM_STORAGE_GROUP_CALL_SECRET_HEX  32 fresh random bytes (hex), for the storage service alone:
#                                        it mints and checks the group-call join token
#                                        (GET /v2/groups/token) itself. Shared with nothing.
#
# A separate file, not more lines in .env or staging-secrets.yml: the chat container reads the
# whole .env, and the secrets bundle has its own format; the storage service is a second
# application that substitutes ${VAR} from its environment (storage.yml). Mode 600, git-ignored,
# on the host only.
#
# Idempotent: an existing storage.env is left alone. After rotating either shared secret in
# staging-secrets.yml, delete storage.env, run this again and `docker compose up -d storage`
# (the new group-call secret only invalidates group-call tokens already handed out).
#
# From deploy/staging:   ./storage/make-storage-env.sh
set -eu

cd "$(dirname "$0")/.."

die() { echo "make-storage-env: $*" >&2; exit 1; }

if [ -e storage.env ]; then
  echo "make-storage-env: storage.env exists, leaving it alone"
  exit 0
fi
[ -r staging-secrets.yml ] || die "staging-secrets.yml not found; run generate-secrets.sh first"
command -v openssl >/dev/null || die "openssl is required"
command -v od >/dev/null || die "od is required"

read_secret() {
  # $1: a staging-secrets.yml key such as storageService.userAuthenticationTokenSharedSecret.
  # The key is matched literally (its dots escaped); quotes, spaces and CR are stripped.
  sed -n "s/^$(printf '%s' "$1" | sed 's/[.[\*^$/]/\\&/g'):[[:space:]]*//p" staging-secrets.yml \
    | head -1 | tr -d "\"' \r"
}

auth_b64="$(read_secret 'storageService.userAuthenticationTokenSharedSecret')"
[ -n "${auth_b64}" ] || die "storageService.userAuthenticationTokenSharedSecret is missing from staging-secrets.yml"
auth_hex="$(printf '%s' "${auth_b64}" | openssl base64 -d -A 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
auth_bytes=$(( ${#auth_hex} / 2 ))
[ "${auth_bytes}" = "32" ] || die "storageService.userAuthenticationTokenSharedSecret is not the base64 of 32 bytes (decoded ${auth_bytes})"

zk_secret="$(read_secret 'groupsZkConfig.serverSecret')"
[ -n "${zk_secret}" ] || die "groupsZkConfig.serverSecret is missing from staging-secrets.yml"
zk_bytes="$(printf '%s' "${zk_secret}" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"
[ "${zk_bytes}" -gt 0 ] || die "groupsZkConfig.serverSecret does not decode as base64"

group_call_secret_hex="$(openssl rand -hex 32)"

umask 077
{
  echo "# SWARM Messenger staging: storage service credentials. PRIVATE, NOT IN GIT, mode 600."
  echo "# Written by storage/make-storage-env.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). docs/STAGING.md, section 5c."
  echo "# = storageService.userAuthenticationTokenSharedSecret (staging-secrets.yml), hex instead of base64"
  echo "SWARM_STORAGE_AUTH_KEY_HEX=${auth_hex}"
  echo "# = groupsZkConfig.serverSecret (staging-secrets.yml), verbatim"
  echo "SWARM_STORAGE_ZK_SERVER_SECRET=${zk_secret}"
  echo "# the storage service's own group-call token secret"
  echo "SWARM_STORAGE_GROUP_CALL_SECRET_HEX=${group_call_secret_hex}"
} > storage.env.tmp
chmod 600 storage.env.tmp
mv storage.env.tmp storage.env
echo "make-storage-env: wrote storage.env (mode 600): auth key 32 bytes, zk secret ${zk_bytes} bytes, new group-call secret 32 bytes"
