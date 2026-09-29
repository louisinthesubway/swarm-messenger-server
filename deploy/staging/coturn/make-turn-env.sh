#!/bin/sh
# SWARM Messenger staging: write deploy/staging/turn.env for one-to-one calls, once. Prints no
# secret. docs/STAGING.md, section 5d.
#
#   SWARM_TURN_API_TOKEN            = turn.cloudflare.apiToken in staging-secrets.yml. The chat
#                                     server sends it as "Authorization: Bearer ..." when it asks
#                                     the turn-credentials service for TURN credentials; that
#                                     service refuses every other token (401).
#   SWARM_TURN_STATIC_AUTH_SECRET   32 fresh random bytes (hex), shared by coturn
#                                     (static-auth-secret) and turn-credentials, which signs the
#                                     TURN REST credentials with it. Shared with nothing else.
#
# generate-secrets.sh wrote `turn.cloudflare.apiToken: unset` into staging-secrets.yml while no
# TURN server existed. If the value is still that placeholder (or missing, or shorter than 32
# characters), this script generates a real token (32 random bytes, hex) and writes it into
# staging-secrets.yml IN PLACE: the same file (inode) with its mode unchanged, because
# docker-compose.yml bind-mounts that single file into the chat container. The chat server reads
# its secrets only at start, so `docker compose restart chat` afterwards.
#
# A separate file, not more lines in .env: the chat container reads the whole .env.
# Idempotent: an existing turn.env is left alone. To rotate: delete turn.env (and, for a new API
# token, set turn.cloudflare.apiToken back to `unset`), run this again, then
# `docker compose up -d --no-deps coturn turn-credentials` and restart chat.
#
# From deploy/staging:   ./coturn/make-turn-env.sh
set -eu

cd "$(dirname "$0")/.."

die() { echo "make-turn-env: $*" >&2; exit 1; }

if [ -e turn.env ]; then
  echo "make-turn-env: turn.env exists, leaving it alone"
  exit 0
fi
[ -r staging-secrets.yml ] || die "staging-secrets.yml not found; run generate-secrets.sh first"
[ -w staging-secrets.yml ] || die "staging-secrets.yml is not writable"
command -v openssl >/dev/null || die "openssl is required"

key='turn.cloudflare.apiToken'
key_re='turn\.cloudflare\.apiToken'
lines="$(grep -c "^${key_re}:" staging-secrets.yml || true)"
[ "${lines}" -le 1 ] || die "${key} appears ${lines} times in staging-secrets.yml"

token="$(sed -n "s/^${key_re}:[[:space:]]*//p" staging-secrets.yml | head -1 | tr -d "\"' \r")"
if [ -z "${token}" ] || [ "${token}" = "unset" ] || [ "${#token}" -lt 32 ]; then
  token="$(openssl rand -hex 32)"
  umask 077
  tmp="$(mktemp staging-secrets.yml.XXXXXX)"
  trap 'rm -f "${tmp}"' EXIT
  if [ "${lines}" = "1" ]; then
    sed "s/^${key_re}:.*/${key}: ${token}/" staging-secrets.yml > "${tmp}"
  else
    { cat staging-secrets.yml; echo "${key}: ${token}"; } > "${tmp}"
  fi
  [ "$(grep -c "^${key_re}: ${token}\$" "${tmp}")" = "1" ] || { rm -f "${tmp}"; die "could not set ${key}"; }
  # Rewrite the existing file instead of moving the new one over it: same inode, same mode.
  cat "${tmp}" > staging-secrets.yml
  rm -f "${tmp}"
  trap - EXIT
  echo "make-turn-env: replaced the placeholder ${key} in staging-secrets.yml with a new 32-byte token (restart chat)"
else
  echo "make-turn-env: keeping the existing ${key} from staging-secrets.yml"
fi

umask 077
{
  echo "# SWARM Messenger staging: one-to-one call relay (TURN) secrets. PRIVATE, NOT IN GIT, mode 600."
  echo "# Written by coturn/make-turn-env.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). docs/STAGING.md, section 5d."
  echo "# = turn.cloudflare.apiToken (staging-secrets.yml)"
  echo "SWARM_TURN_API_TOKEN=${token}"
  echo "# coturn's static-auth-secret; turn-credentials signs TURN credentials with it"
  echo "SWARM_TURN_STATIC_AUTH_SECRET=$(openssl rand -hex 32)"
} > turn.env.tmp
chmod 600 turn.env.tmp
mv turn.env.tmp turn.env
echo "make-turn-env: wrote turn.env (mode 600): API token 32 bytes, new static auth secret 32 bytes"
