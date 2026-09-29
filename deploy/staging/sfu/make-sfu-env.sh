#!/bin/sh
# SWARM Messenger staging: write deploy/staging/sfu.env for the calling frontend (group calls),
# once. Prints no secret. docs/STAGING.md, section 5d.
#
#   CALLING_AUTH_KEY   = SWARM_STORAGE_GROUP_CALL_SECRET_HEX in storage.env, verbatim (hex, 32
#                        bytes). The storage service signs the group-call token it hands a member
#                        (GET /v2/groups/token) with it: "2:<sha256 of the member's encrypted id>:
#                        <group id>:<time>:<0|1>:<first 10 bytes of HMAC-SHA256>". The frontend
#                        checks that HMAC (--authentication-key, hex) before anyone may join or
#                        start a group call. Wrong value: every group call answers 401/403.
#   CALLING_ZKPARAMS   = callingZkConfigV101.serverSecret in staging-secrets.yml, verbatim (base64
#                        GenericServerSecretParams). The chat server issues call-link credentials
#                        with it; the frontend verifies their presentations with it (--zkparams).
#                        The frontend refuses to start without it, call links or not.
#
# Both variables are read by the frontend from its environment (the swarm-calling-service fork's
# one change), so neither appears on a command line. A separate file, mode 600, git-ignored, on the
# host only. Idempotent: an existing sfu.env is left alone. After rotating either source secret:
# delete sfu.env, run this again, `docker compose up -d --no-deps calling-frontend`.
#
# From deploy/staging:   ./sfu/make-sfu-env.sh
set -eu

cd "$(dirname "$0")/.."

die() { echo "make-sfu-env: $*" >&2; exit 1; }

if [ -e sfu.env ]; then
  echo "make-sfu-env: sfu.env exists, leaving it alone"
  exit 0
fi
[ -r storage.env ] || die "storage.env not found; run storage/make-storage-env.sh first (section 5c)"
[ -r staging-secrets.yml ] || die "staging-secrets.yml not found; run generate-secrets.sh first"
command -v openssl >/dev/null || die "openssl is required"

auth_hex="$(sed -n 's/^SWARM_STORAGE_GROUP_CALL_SECRET_HEX=//p' storage.env | head -1 | tr -d "\"' \r")"
printf '%s' "${auth_hex}" | grep -Eq '^[0-9a-fA-F]{64}$' \
  || die "SWARM_STORAGE_GROUP_CALL_SECRET_HEX in storage.env is not 32 bytes of hex"

zk="$(sed -n 's/^callingZkConfigV101\.serverSecret:[[:space:]]*//p' staging-secrets.yml | head -1 | tr -d "\"' \r")"
[ -n "${zk}" ] || die "callingZkConfigV101.serverSecret is missing from staging-secrets.yml"
zk_bytes="$(printf '%s' "${zk}" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"
[ "${zk_bytes}" -gt 0 ] || die "callingZkConfigV101.serverSecret does not decode as base64"

umask 077
{
  echo "# SWARM Messenger staging: calling frontend (group calls) secrets. PRIVATE, NOT IN GIT, mode 600."
  echo "# Written by sfu/make-sfu-env.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). docs/STAGING.md, section 5d."
  echo "# = SWARM_STORAGE_GROUP_CALL_SECRET_HEX (storage.env)"
  echo "CALLING_AUTH_KEY=${auth_hex}"
  echo "# = callingZkConfigV101.serverSecret (staging-secrets.yml)"
  echo "CALLING_ZKPARAMS=${zk}"
} > sfu.env.tmp
chmod 600 sfu.env.tmp
mv sfu.env.tmp sfu.env
echo "make-sfu-env: wrote sfu.env (mode 600): group-call key 32 bytes, calling zk secret ${zk_bytes} bytes"
