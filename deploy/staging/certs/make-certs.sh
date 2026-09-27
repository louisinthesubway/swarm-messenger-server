#!/usr/bin/env bash
# SWARM Messenger staging — TLS material for the internal gRPC hop to the registration stub.
#
# Upstream's RegistrationServiceClient always opens a TLS channel and trusts exactly the CA
# certificate given in `registrationService.registrationCaCertificate`. So the staging stack
# needs its own tiny CA: one root, one server certificate for the stub.
#
# This is *internal* TLS between two containers. It is not the public edge — the public
# certificates for chat.swarm.green / cdn.chat.swarm.green / reg.chat.swarm.green come from
# Caddy's ACME client (see ../caddy/Caddyfile).
#
# Outputs in this directory (all git-ignored):
#   swarm-staging-ca.key        CA private key            keep off the server if you can
#   swarm-staging-ca.crt        CA certificate            pasted into staging.yml
#   registration-stub.key       stub server private key
#   registration-stub.crt       stub server certificate   (chain: leaf + CA)
#
# Usage:  ./make-certs.sh [extra-dns-name ...]
set -euo pipefail

# Git Bash / MSYS2 rewrites arguments that look like absolute paths, which mangles openssl's
# "/O=.../CN=..." subject strings into "C:/Program Files/Git/O=...". Harmless on Linux, where
# this script is meant to run; this keeps it working if someone tries it on Windows.
export MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")"

CA_DAYS=3650
LEAF_DAYS=825

DNS_NAMES=(registration-stub reg.chat.swarm.green localhost "$@")

if [ -f registration-stub.crt ] && [ -f swarm-staging-ca.crt ]; then
  echo "Certificates already exist in $(pwd). Delete them first to regenerate:"
  openssl x509 -in registration-stub.crt -noout -subject -dates -ext subjectAltName
  exit 0
fi

echo "==> CA"
openssl req -x509 -newkey rsa:4096 -sha256 -days "${CA_DAYS}" -nodes \
  -keyout swarm-staging-ca.key -out swarm-staging-ca.crt \
  -subj "/O=SWARM Messenger staging/CN=SWARM Messenger staging internal CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

echo "==> registration stub key and CSR"
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout registration-stub.key -out registration-stub.csr \
  -subj "/O=SWARM Messenger staging/CN=registration-stub"

san="subjectAltName=$(printf 'DNS:%s,' "${DNS_NAMES[@]}" | sed 's/,$//')"
echo "==> signing with ${san}"

cat > registration-stub.ext <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
${san}
EOF

openssl x509 -req -in registration-stub.csr -sha256 -days "${LEAF_DAYS}" \
  -CA swarm-staging-ca.crt -CAkey swarm-staging-ca.key -CAcreateserial \
  -extfile registration-stub.ext -out registration-stub-leaf.crt

# gRPC wants the full chain in the server certificate file.
cat registration-stub-leaf.crt swarm-staging-ca.crt > registration-stub.crt
rm -f registration-stub.csr registration-stub.ext registration-stub-leaf.crt

chmod 600 swarm-staging-ca.key registration-stub.key
chmod 644 swarm-staging-ca.crt registration-stub.crt

echo
echo "==> done"
openssl x509 -in registration-stub.crt -noout -subject -issuer -dates -ext subjectAltName

echo
echo "Paste swarm-staging-ca.crt into staging-secrets.yml as"
echo "  registrationService.caCertificate: |"
sed 's/^/    /' swarm-staging-ca.crt
