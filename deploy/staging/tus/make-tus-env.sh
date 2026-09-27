#!/bin/sh
# SWARM Messenger staging: write deploy/staging/tus.env for the CDN3 upload service, once.
#
#   SWARM_TUS_TOKEN_SECRET   the service's copy of tus.userAuthenticationTokenSharedSecret from
#                            staging-secrets.yml. The chat server signs upload tokens with it and
#                            the service verifies them with it, so the two must stay equal.
#   SWARM_TUS_S3_ACCESS_KEY  the service's own MinIO user. minio-bootstrap creates it with a
#   SWARM_TUS_S3_SECRET_KEY  policy that allows PutObject/GetObject under swarm-cdn/attachments/
#                            and nothing else.
#
# A separate file rather than more lines in .env, so the chat container's environment (it reads
# the whole .env) does not change. Idempotent: an existing tus.env is left alone. Prints no secret.
# generate-secrets.sh runs this; on an existing host run it by hand, from deploy/staging:
#
#   ./tus/make-tus-env.sh
set -eu

cd "$(dirname "$0")/.."

die() { echo "make-tus-env: $*" >&2; exit 1; }

if [ -e tus.env ]; then
  echo "make-tus-env: tus.env exists, leaving it alone"
  exit 0
fi
[ -r staging-secrets.yml ] || die "staging-secrets.yml not found; run generate-secrets.sh first"
command -v openssl >/dev/null || die "openssl is required"

secret="$(sed -n 's/^tus\.userAuthenticationTokenSharedSecret:[[:space:]]*//p' staging-secrets.yml \
  | tr -d "\"' \r")"
[ -n "${secret}" ] || die "tus.userAuthenticationTokenSharedSecret is missing from staging-secrets.yml"
bytes="$(printf '%s' "${secret}" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')"
[ "${bytes}" = "32" ] || die "tus.userAuthenticationTokenSharedSecret is not the base64 of 32 bytes"

umask 077
{
  echo "# SWARM Messenger staging: CDN3 upload service credentials. PRIVATE, NOT IN GIT."
  echo "# Written by tus/make-tus-env.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). See docs/STAGING.md, 8a."
  echo "# SWARM_TUS_TOKEN_SECRET must equal tus.userAuthenticationTokenSharedSecret in staging-secrets.yml."
  echo "SWARM_TUS_TOKEN_SECRET=${secret}"
  echo "SWARM_TUS_S3_ACCESS_KEY=swarmtus$(openssl rand -hex 4)"
  echo "SWARM_TUS_S3_SECRET_KEY=$(openssl rand -hex 20)"
} > tus.env.tmp
mv tus.env.tmp tus.env
chmod 600 tus.env
echo "make-tus-env: wrote tus.env (mode 600)"
