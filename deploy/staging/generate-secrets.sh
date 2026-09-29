#!/usr/bin/env bash
# SWARM Messenger — generate this deployment's staging secrets, .env, and the public
# parameters the clients need.
#
# Writes:
#   staging-secrets.yml                     the secrets bundle the server reads   (git-ignored, 600)
#   .env                                    the compose environment               (git-ignored, 600)
#   certs/*                                 internal CA + registration stub cert  (git-ignored)
#   shared/staging-public-params.json       PUBLIC values the clients need        (git-ignored, safe to share)
#
# Refuses to overwrite anything that already exists: rotating the zk parameters or the
# sealed-sender trust root invalidates credentials clients already hold.
#
# Requirements on the host: bash, openssl, python3, and a JDK 26 plus the built jar
#   ./mvnw -DskipTests -Pexclude-spam-filter package
# The jar is needed because the zero-knowledge parameters and the sealed-sender certificate must
# come from libsignal. Nothing here invents cryptography: it calls the server's own
# `certificate` command and zkparams/SwarmZkParams.java, and openssl for the rest.
#
# Usage:
#   ./generate-secrets.sh [path/to/TextSecureServer-<version>.jar]

set -euo pipefail

cd "$(dirname "$0")"

die() { printf '%s\n' "$*" >&2; exit 1; }

JAR="${1:-}"
if [ -z "${JAR}" ]; then
  JAR="$(ls -t ../../service/target/TextSecureServer-*.jar 2>/dev/null \
    | grep -v -- '-tests\.jar$' | grep -v '/original-' | head -1)"
fi

[ -n "${JAR}" ] && [ -f "${JAR}" ] || die "Cannot find the server jar. Build it with:
  ./mvnw -DskipTests -Pexclude-spam-filter package
then pass the path: ./generate-secrets.sh path/to/TextSecureServer-<version>.jar"

command -v openssl >/dev/null || die "openssl is required"
command -v python3 >/dev/null || die "python3 is required"
command -v java    >/dev/null || die "java (26+) is required"

[ -e staging-secrets.yml ] && die "staging-secrets.yml already exists. Move it aside first — regenerating invalidates credentials clients already hold."
[ -e .env ] && die ".env already exists. Move it aside first."

JAR_ABS="$(cd "$(dirname "${JAR}")" && pwd)/$(basename "${JAR}")"

# libsignal loads a native library; Java 26 warns about that unless native access is enabled.
JAVA_FLAGS=(--enable-native-access=ALL-UNNAMED)

rand_b64_32() { openssl rand -base64 32 | tr -d '\n'; }

echo "==> 1/7  internal CA and registration-stub certificate"
./certs/make-certs.sh >/dev/null
CA_PEM_ONELINE="$(python3 -c '
import sys
with open("certs/swarm-staging-ca.crt", encoding="ascii") as fh:
    sys.stdout.write(fh.read().replace("\n", "\\n"))
')"

echo "==> 2/7  random shared secrets"
AWS_KEY="swarm$(openssl rand -hex 8)"
AWS_SECRET="$(rand_b64_32)"
CDN_KEY="swarmcdn$(openssl rand -hex 4)"
CDN_SECRET="$(rand_b64_32)"
MINIO_ROOT_PASSWORD="$(rand_b64_32)"

echo "==> 3/7  throwaway RSA key for the two disabled Google integrations"
# gcpAttachments and FCM are off, but the server parses these keys at startup, so they must be
# syntactically valid. Generated fresh, so no published test key ends up in this deployment.
THROWAWAY_RSA="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)"
THROWAWAY_RSA_INDENTED="$(printf '%s\n' "${THROWAWAY_RSA}" | sed 's/^/  /')"
THROWAWAY_RSA_ONELINE="$(printf '%s' "${THROWAWAY_RSA}" | python3 -c '
import sys
sys.stdout.write(sys.stdin.read().rstrip("\n").replace("\n", "\\n"))
')"

echo "==> 4/7  zero-knowledge server parameters (libsignal, via zkparams/SwarmZkParams.java)"
# Four independent sets. Three of them are GenericServerSecretParams, a different libsignal type
# from what the server's own `zkparams` command produces; see zkparams/SwarmZkParams.java.
ZK_JSON="$(cd zkparams && java "${JAVA_FLAGS[@]}" -cp "${JAR_ABS}" SwarmZkParams.java 2>/dev/null)"
[ -n "${ZK_JSON}" ] || die "SwarmZkParams produced no output. Run it by hand to see why:
  (cd zkparams && java -cp ${JAR_ABS} SwarmZkParams.java)"

zk() { printf '%s' "${ZK_JSON}" | python3 -c '
import json, sys
print(json.load(sys.stdin)[sys.argv[1]][sys.argv[2]])
' "$1" "$2"; }

GROUPS_PUBLIC="$(zk groups public)";                 GROUPS_SECRET="$(zk groups secret)"
CHAT_PUBLIC="$(zk chat public)";                     CHAT_SECRET="$(zk chat secret)"
CALLING_PUBLIC="$(zk calling public)";               CALLING_SECRET="$(zk calling secret)"
CALLING_PRE_PUBLIC="$(zk callingPreV101 public)";    CALLING_PRE_SECRET="$(zk callingPreV101 secret)"

echo "==> 5/7  sealed-sender trust root and server certificate"
# `initialize()` demands the secrets-bundle property even for a command that never reads it.
TMP_BUNDLE="$(mktemp)"
trap 'rm -f "${TMP_BUNDLE}"' EXIT
printf 'placeholder: unset\n' > "${TMP_BUNDLE}"

CA_OUT="$(java "${JAVA_FLAGS[@]}" -Dsecrets.bundle.filename="${TMP_BUNDLE}" -jar "${JAR_ABS}" certificate --ca 2>/dev/null)"
UD_ROOT_PUBLIC="$(printf '%s\n' "${CA_OUT}" | sed -n 's/^Public key *: //p')"
UD_ROOT_PRIVATE="$(printf '%s\n' "${CA_OUT}" | sed -n 's/^Private key: //p')"
[ -n "${UD_ROOT_PRIVATE}" ] || die "certificate --ca produced no output"

CERT_ID="$(( (RANDOM << 15 | RANDOM) % 1000000 + 1 ))"
CERT_OUT="$(java "${JAVA_FLAGS[@]}" -Dsecrets.bundle.filename="${TMP_BUNDLE}" -jar "${JAR_ABS}" \
  certificate --key "${UD_ROOT_PRIVATE}" --id "${CERT_ID}" 2>/dev/null)"
UD_CERTIFICATE="$(printf '%s\n' "${CERT_OUT}" | sed -n 's/^Certificate: //p')"
UD_PRIVATE_KEY="$(printf '%s\n' "${CERT_OUT}" | sed -n 's/^Private key: //p')"
[ -n "${UD_CERTIFICATE}" ] || die "the certificate command produced no certificate"

echo "==> 6/7  writing staging-secrets.yml and .env"

umask 077

GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > staging-secrets.yml <<YAML
# SWARM Messenger staging secrets — GENERATED by generate-secrets.sh on ${GENERATED_AT}.
# NOT IN GIT. Back this file up off the host: the zk parameters and the sealed-sender trust
# root cannot be rotated without updating every client.

aws.accessKeyId: ${AWS_KEY}
aws.secretAccessKey: ${AWS_SECRET}

cdn.accessKey: ${CDN_KEY}
cdn.accessSecret: ${CDN_SECRET}

# zkgroup (ServerSecretParams). Public half is the clients' serverPublicParams.
groupsZkConfig.serverSecret: ${GROUPS_SECRET}
# GenericServerSecretParams for backup credentials (BackupAuthManager). Public half is the
# clients' backupServerPublicParams.
chatZkConfig.serverSecret: ${CHAT_SECRET}
# GenericServerSecretParams for calling credentials: call-link auth credentials (returned with the
# group auth credentials) and create-call-link credentials. Public half is the clients'
# genericServerPublicParams.
callingZkConfigV101.serverSecret: ${CALLING_SECRET}
callingZkConfigPreV101.serverSecret: ${CALLING_PRE_SECRET}

# Private half of the sealed-sender trust root. The clients must ship the public half,
# ${UD_ROOT_PUBLIC}, as their serverTrustRoot.
unidentifiedDelivery.privateKey: ${UD_PRIVATE_KEY}

foundationDbMessages.versionstampCipherKey.0: $(rand_b64_32)
registrationService.collationKeySalt: $(rand_b64_32)
registrationWebAuthn.userHandleBlindingSecret: $(rand_b64_32)
linkDevice.secret: $(rand_b64_32)
storageService.userAuthenticationTokenSharedSecret: $(rand_b64_32)
paymentsService.userAuthenticationTokenSharedSecret: $(rand_b64_32)
directoryV2.client.userAuthenticationTokenSharedSecret: $(rand_b64_32)
directoryV2.client.userIdTokenSharedSecret: $(rand_b64_32)
svr2.userAuthenticationTokenSharedSecret: $(rand_b64_32)
svr2.userIdTokenSharedSecret: $(rand_b64_32)
svrb.userAuthenticationTokenSharedSecret: $(rand_b64_32)
svrb.userIdTokenSharedSecret: $(rand_b64_32)
tus.userAuthenticationTokenSharedSecret: $(rand_b64_32)
# The chat server's Bearer token for TURN credentials. The turn-credentials service (one-to-one
# call relays, docs/STAGING.md section 5d) accepts only this token; coturn/make-turn-env.sh copies it
# into turn.env.
turn.cloudflare.apiToken: $(openssl rand -hex 32)

tlsKeyStore.password: $(rand_b64_32)

# ---- placeholders for features that are OFF (see docs/STAGING.md) --------------------
stripe.apiKey: unset
stripe.idempotencyKeyGenerator: $(rand_b64_32)
braintree.publicKey: unset
braintree.privateKey: unset
cdn3StorageManager.clientSecret: unset
paymentsService.fixerApiKey: unset
paymentsService.coinGeckoApiKey: unset
hlrLookup.apiKey: unset
hlrLookup.apiSecret: unset

apn.teamId: disabled
apn.keyId: disabled
apn.signingKey: |
$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null | sed 's/^/  /')

appleAppStore.encodedKey: |
$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null | sed 's/^/  /')

keyTransparencyService.clientPrivateKey: |
$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null | sed 's/^/  /')

gcpAttachments.rsaSigningKey: |
${THROWAWAY_RSA_INDENTED}

fcm.credentials: |
  { "type": "service_account", "client_id": "disabled", "client_email": "disabled@swarm.invalid",
    "private_key_id": "disabled",
    "private_key": "${THROWAWAY_RSA_ONELINE}" }
YAML

cat > .env <<ENV
# SWARM Messenger staging environment — GENERATED by generate-secrets.sh on ${GENERATED_AT}.
# NOT IN GIT.

SWARM_STAGING_FIXED_CODE=true
SWARM_STAGING_VERIFICATION_CODE=${SWARM_STAGING_VERIFICATION_CODE:-123456}

SWARM_CHAT_DOMAIN=${SWARM_CHAT_DOMAIN:-chat.swarm.green}
SWARM_CDN_DOMAIN=${SWARM_CDN_DOMAIN:-cdn.chat.swarm.green}
SWARM_REG_DOMAIN=${SWARM_REG_DOMAIN:-reg.chat.swarm.green}
SWARM_SFU_DOMAIN=${SWARM_SFU_DOMAIN:-sfu.chat.swarm.green}
SWARM_ACME_EMAIL=${SWARM_ACME_EMAIL:-REPLACE_ME_BEFORE_STARTING_CADDY}

SWARM_AWS_REGION=us-east-1
SWARM_AWS_ACCESS_KEY_ID=${AWS_KEY}
SWARM_AWS_SECRET_ACCESS_KEY=${AWS_SECRET}

SWARM_MINIO_ROOT_USER=swarmstaging
SWARM_MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
SWARM_CDN_ACCESS_KEY=${CDN_KEY}
SWARM_CDN_SECRET_KEY=${CDN_SECRET}

SWARM_REGISTRATION_CA_PEM=${CA_PEM_ONELINE}
SWARM_GROUPS_ZK_SERVER_PUBLIC=${GROUPS_PUBLIC}
SWARM_UNIDENTIFIED_DELIVERY_CERTIFICATE=${UD_CERTIFICATE}

SWARM_LOG_LEVEL=INFO
SWARM_TABLE_PREFIX=swarm_
SWARM_CDN_BUCKET=swarm-cdn
SWARM_PREKEY_BUCKET=swarm-prekeys
SWARM_CONFIG_BUCKET=swarm-config
ENV

echo "==> 7/7  writing shared/staging-public-params.json"
# Everything in this file is PUBLIC and is meant to be handed to whoever builds the clients.
# Format is documented in docs/STAGING.md ("Public parameters for the clients").
mkdir -p shared
export ZK_GROUPS_PUBLIC="${GROUPS_PUBLIC}"
export ZK_CHAT_PUBLIC="${CHAT_PUBLIC}"
export ZK_CALLING_PUBLIC="${CALLING_PUBLIC}"
export ZK_CALLING_PRE_PUBLIC="${CALLING_PRE_PUBLIC}"
export UD_ROOT_PUBLIC
export SWARM_CHAT_DOMAIN="${SWARM_CHAT_DOMAIN:-chat.swarm.green}"
export SWARM_CDN_DOMAIN="${SWARM_CDN_DOMAIN:-cdn.chat.swarm.green}"
export SWARM_SFU_DOMAIN="${SWARM_SFU_DOMAIN:-sfu.chat.swarm.green}"
python3 - "${GENERATED_AT}" > shared/staging-public-params.json <<'PY'
import json, os, sys

generated_at = sys.argv[1]

with open("certs/swarm-staging-ca.crt", encoding="ascii") as fh:
    ca_pem = fh.read()

doc = {
    "schema": "swarm-messenger/staging-public-params/1",
    "generatedAt": generated_at,
    "environment": "staging",
    "note": "Every value here is public. Hand this file to whoever builds the SWARM Messenger "
            "clients. The matching private halves live only in deploy/staging/staging-secrets.yml.",
    "endpoints": {
        "chat": "https://" + os.environ["SWARM_CHAT_DOMAIN"],
        "chatWebsocket": "wss://" + os.environ["SWARM_CHAT_DOMAIN"] + "/v1/websocket",
        "cdn": "https://" + os.environ["SWARM_CDN_DOMAIN"],
        "registration": None,
        "sfu": "https://" + os.environ["SWARM_SFU_DOMAIN"],
    },
    "serverPublicParams": os.environ["ZK_GROUPS_PUBLIC"],
    "genericServerPublicParams": os.environ["ZK_CALLING_PUBLIC"],
    "backupServerPublicParams": os.environ["ZK_CHAT_PUBLIC"],
    "callingServerPublicParams": os.environ["ZK_CALLING_PUBLIC"],
    "callingServerPublicParamsPreV101": os.environ["ZK_CALLING_PRE_PUBLIC"],
    "serverTrustRoots": [os.environ["UD_ROOT_PUBLIC"]],
    "registrationCaCertificatePem": ca_pem,
    "comments": {
        "serverPublicParams": "zkgroup ServerPublicParams. Pairs with groupsZkConfig.serverSecret.",
        "genericServerPublicParams": "GenericServerPublicParams for calling credentials (call-link "
                                     "auth, create call link). Pairs with callingZkConfig "
                                     "(callingZkConfigV101.serverSecret); same value as "
                                     "callingServerPublicParams.",
        "backupServerPublicParams": "GenericServerPublicParams for backup credentials. Pairs with "
                                    "chatZkConfig.serverSecret (BackupAuthManager).",
        "serverTrustRoots": "Sealed-sender trust roots, base64 public keys. A list so a future "
                            "rotation can publish the new root alongside the old one.",
        "registrationCaCertificatePem": "The staging stack's INTERNAL CA, for the chat server's "
                                        "gRPC hop to the registration stub. Clients do not need it. "
                                        "Public HTTPS uses Let's Encrypt.",
        "registration": "Deliberately null: reg.chat.swarm.green is not published. Clients "
                        "register through the chat endpoint.",
        "sfu": "The group-call server (calling frontend). Clients take it from their own sfuUrl "
               "setting; one-to-one call relays come from the chat server (/v2/calling/relays).",
    },
}

json.dump(doc, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

chmod 600 staging-secrets.yml .env
chmod 644 shared/staging-public-params.json

# The CDN3 upload service's own file: its copy of tus.userAuthenticationTokenSharedSecret and its
# MinIO key (docs/STAGING.md, section 8a). Separate from .env on purpose.
./tus/make-tus-env.sh >/dev/null
# The one-to-one call relay's file: the chat server's TURN token and coturn's secret (section 5d).
./coturn/make-turn-env.sh >/dev/null

cat <<EOF

==> done

  staging-secrets.yml                $(wc -l < staging-secrets.yml) lines, mode 600   PRIVATE, back it up
  .env                               $(wc -l < .env) lines, mode 600   PRIVATE
  tus.env                            the CDN3 upload service's credentials, mode 600   PRIVATE
  turn.env                           the call relay's (coturn) secrets, mode 600       PRIVATE
  certs/                             internal CA + registration-stub certificate
  shared/staging-public-params.json  PUBLIC — give this to whoever builds the clients

NEXT
  1. Set SWARM_ACME_EMAIL in .env before starting the caddy profile.
  2. Hand shared/staging-public-params.json to the client builds. The sealed-sender trust root
     in it is:

       ${UD_ROOT_PUBLIC}

     Nothing else needs it, and the private half is only in staging-secrets.yml.
  3. Back up staging-secrets.yml and certs/ somewhere off this host.
  4. docker compose up -d   (see docs/STAGING.md for start order and health checks)
EOF
