#!/usr/bin/env bash
# SWARM Messenger — one command to turn a fresh Ubuntu 24.04 host into the staging server.
#
#   curl -fsSL <raw url of this file> -o bootstrap-host.sh
#   sudo SWARM_ACME_EMAIL=you@example.com bash bootstrap-host.sh
#
# or, if the repository is already cloned:
#
#   sudo SWARM_ACME_EMAIL=you@example.com ./deploy/staging/bootstrap-host.sh
#
# What it does, in order:
#   1. sanity-checks the host (Ubuntu 24.04, x86-64, RAM, disk, DNS)
#   2. installs Docker Engine + the compose plugin from Docker's own apt repository
#   3. installs a JDK 26 (Temurin) and git
#   4. clones or updates Swarm-Official/swarm-messenger-server at a PINNED commit
#   5. builds the shaded server jar
#   6. generates this deployment's secrets, zk parameters and internal CA (never committed)
#      and writes the public halves to deploy/staging/shared/staging-public-params.json
#   7. starts the stack
#   8. starts Caddy, which obtains Let's Encrypt certificates for chat. and cdn.
#   9. verifies the health endpoint and the registration stub
#
# It is idempotent: re-running it updates the checkout and restarts the stack, and it will not
# overwrite secrets that already exist.
#
# It does NOT open a firewall for you beyond ports 80, 443 and 22, and it does not touch DNS.
# Point the A records at this host BEFORE running it, or step 8 will fail on the ACME challenge
# and you will have to re-run `docker compose --profile edge up -d caddy` later.

set -euo pipefail

# ------------------------------------------------------------------ settings

# The commit this host runs. Bump it deliberately; never track a moving branch on a server.
SWARM_REPO="${SWARM_REPO:-https://github.com/Swarm-Official/swarm-messenger-server.git}"
SWARM_REF="${SWARM_REF:-swarm-main}"
SWARM_COMMIT="${SWARM_COMMIT:-}"          # REQUIRED unless SWARM_ALLOW_FLOATING_REF=yes
SWARM_CHECKOUT="${SWARM_CHECKOUT:-/opt/swarm/swarm-messenger-server}"

SWARM_CHAT_DOMAIN="${SWARM_CHAT_DOMAIN:-chat.swarm.green}"
SWARM_CDN_DOMAIN="${SWARM_CDN_DOMAIN:-cdn.chat.swarm.green}"
SWARM_REG_DOMAIN="${SWARM_REG_DOMAIN:-reg.chat.swarm.green}"
SWARM_SFU_DOMAIN="${SWARM_SFU_DOMAIN:-sfu.chat.swarm.green}"
SWARM_ACME_EMAIL="${SWARM_ACME_EMAIL:-}"

SWARM_SKIP_EDGE="${SWARM_SKIP_EDGE:-no}"  # yes = do not start Caddy (no DNS yet)
SWARM_JDK_VERSION="${SWARM_JDK_VERSION:-26}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ 1. host checks

log "1/9  checking the host"

[ "$(id -u)" -eq 0 ] || die "run this with sudo: it installs packages and enables a service"

. /etc/os-release
info "os: ${PRETTY_NAME:-unknown}"
case "${VERSION_ID:-}" in
  24.04) : ;;
  *) info "WARNING: written and tested for Ubuntu 24.04; continuing anyway" ;;
esac

arch="$(uname -m)"
info "arch: ${arch}"
[ "${arch}" = "x86_64" ] || die "x86-64 only: the FoundationDB client library the build downloads is libfdb_c.x86_64.so"

ram_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
info "ram: ${ram_mb} MB"
[ "${ram_mb}" -ge 14000 ] || die "at least 16 GB of RAM is needed (see docs/STAGING.md); found ${ram_mb} MB"

disk_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
info "free disk on /: ${disk_gb} GB"
[ "${disk_gb}" -ge 60 ] || die "at least 60 GB free is needed on / (200 GB recommended); found ${disk_gb} GB"

if [ -z "${SWARM_COMMIT}" ] && [ "${SWARM_ALLOW_FLOATING_REF:-no}" != "yes" ]; then
  die "set SWARM_COMMIT=<full sha> so this host runs a known revision.
To deliberately track ${SWARM_REF} instead, set SWARM_ALLOW_FLOATING_REF=yes."
fi

if [ "${SWARM_SKIP_EDGE}" != "yes" ]; then
  [ -n "${SWARM_ACME_EMAIL}" ] || die "set SWARM_ACME_EMAIL=<address> for Let's Encrypt expiry warnings,
or set SWARM_SKIP_EDGE=yes to bring the stack up without the public TLS edge."

  public_ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  info "this host's public IP: ${public_ip:-<could not determine>}"
  for name in "${SWARM_CHAT_DOMAIN}" "${SWARM_CDN_DOMAIN}"; do
    resolved="$(getent ahostsv4 "${name}" 2>/dev/null | awk '{print $1; exit}' || true)"
    if [ -z "${resolved}" ]; then
      info "WARNING: ${name} does not resolve. Let's Encrypt will fail until it does."
    elif [ -n "${public_ip}" ] && [ "${resolved}" != "${public_ip}" ]; then
      info "WARNING: ${name} resolves to ${resolved}, not ${public_ip}. Let's Encrypt will fail."
    else
      info "${name} -> ${resolved}  ok"
    fi
  done
fi

# ------------------------------------------------------------------ 2. docker

log "2/9  installing Docker Engine and the compose plugin"

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  info "already present: $(docker --version), $(docker compose version --short)"
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -s /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  info "installed: $(docker --version), $(docker compose version --short)"
fi

# ------------------------------------------------------------------ 3. jdk, git, tools

log "3/9  installing a JDK ${SWARM_JDK_VERSION}, git and openssl"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq git openssl python3 jq >/dev/null

if java -version 2>&1 | grep -qE "\"${SWARM_JDK_VERSION}\\."; then
  info "already present: $(java -version 2>&1 | head -1)"
else
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -s /etc/apt/keyrings/adoptium.asc ]; then
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public -o /etc/apt/keyrings/adoptium.asc
    chmod a+r /etc/apt/keyrings/adoptium.asc
  fi
  cat > /etc/apt/sources.list.d/adoptium.list <<EOF
deb [signed-by=/etc/apt/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb ${VERSION_CODENAME} main
EOF
  apt-get update -qq
  apt-get install -y -qq "temurin-${SWARM_JDK_VERSION}-jdk"
  info "installed: $(java -version 2>&1 | head -1)"
fi

# ------------------------------------------------------------------ 4. checkout

log "4/9  checking out the server at a pinned revision"

mkdir -p "$(dirname "${SWARM_CHECKOUT}")"

if [ -d "${SWARM_CHECKOUT}/.git" ]; then
  info "updating ${SWARM_CHECKOUT}"
  git -C "${SWARM_CHECKOUT}" fetch --tags origin
else
  info "cloning ${SWARM_REPO}"
  git clone --no-checkout "${SWARM_REPO}" "${SWARM_CHECKOUT}"
fi

if [ -n "${SWARM_COMMIT}" ]; then
  git -C "${SWARM_CHECKOUT}" checkout --detach "${SWARM_COMMIT}"
else
  git -C "${SWARM_CHECKOUT}" checkout "${SWARM_REF}"
  git -C "${SWARM_CHECKOUT}" pull --ff-only origin "${SWARM_REF}"
fi
info "HEAD is now $(git -C "${SWARM_CHECKOUT}" rev-parse HEAD)"

STAGING="${SWARM_CHECKOUT}/deploy/staging"
[ -d "${STAGING}" ] || die "${STAGING} is missing: is ${SWARM_COMMIT:-${SWARM_REF}} really a swarm-main revision?"

# ------------------------------------------------------------------ 5. build

log "5/9  building the shaded server jar"

# -Pexclude-spam-filter is upstream's profile and is REQUIRED: it runs the shade plugin and
# downloads the matching FoundationDB client library into target/jib-extra/usr/lib/libfdb_c.so.
cd "${SWARM_CHECKOUT}"
MAVEN_OPTS="${MAVEN_OPTS:--Xmx3g}" ./mvnw -B -DskipTests -Pexclude-spam-filter package

JAR="$(ls -t service/target/TextSecureServer-*.jar | grep -v -- '-tests\.jar$' | grep -v '/original-' | head -1)"
[ -n "${JAR}" ] || die "the build produced no jar"
info "jar:    ${JAR}"
info "sha256: $(sha256sum "${JAR}" | cut -d' ' -f1)"
[ -s service/target/jib-extra/usr/lib/libfdb_c.so ] || die "libfdb_c.so was not downloaded; was -Pexclude-spam-filter active?"

# ------------------------------------------------------------------ 6. secrets

log "6/9  generating this deployment's secrets and public parameters"

cd "${STAGING}"

if [ -e staging-secrets.yml ] && [ -e .env ]; then
  info "staging-secrets.yml and .env already exist; leaving them alone"
  info "(regenerating would invalidate credentials the clients already hold)"
else
  [ -e staging-secrets.yml ] || [ -e .env ] || true
  if [ -e staging-secrets.yml ] || [ -e .env ]; then
    die "one of staging-secrets.yml / .env exists and the other does not. Move both aside and re-run."
  fi
  SWARM_CHAT_DOMAIN="${SWARM_CHAT_DOMAIN}" \
  SWARM_CDN_DOMAIN="${SWARM_CDN_DOMAIN}" \
  SWARM_REG_DOMAIN="${SWARM_REG_DOMAIN}" \
  SWARM_SFU_DOMAIN="${SWARM_SFU_DOMAIN}" \
  SWARM_ACME_EMAIL="${SWARM_ACME_EMAIL:-REPLACE_ME_BEFORE_STARTING_CADDY}" \
    ./generate-secrets.sh "${SWARM_CHECKOUT}/${JAR}"
fi

[ -s shared/staging-public-params.json ] || die "shared/staging-public-params.json was not written"
info "public parameters: ${STAGING}/shared/staging-public-params.json"

# ------------------------------------------------------------------ 7. start the stack

log "7/9  building images and starting the stack"

docker compose build
docker compose up -d

info "waiting for the chat server to answer its health endpoint (this takes 1-3 minutes)"
ok=no
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 http://127.0.0.1:8081/healthcheck >/dev/null 2>&1; then
    ok=yes
    break
  fi
  sleep 5
done

if [ "${ok}" != "yes" ]; then
  printf '\n'
  docker compose ps
  printf '\n--- last 80 lines of the chat log ---\n'
  docker compose logs --tail 80 chat || true
  die "the chat server did not become healthy. docs/STAGING.md section 10 lists the usual causes;
the most common one is a missing dynamic-config.yaml object, which makes startup block silently."
fi
info "health endpoint answered"

# ------------------------------------------------------------------ 8. tls edge

if [ "${SWARM_SKIP_EDGE}" = "yes" ]; then
  log "8/9  skipping the TLS edge (SWARM_SKIP_EDGE=yes)"
  info "start it later with: cd ${STAGING} && docker compose --profile edge up -d caddy"
else
  log "8/9  starting Caddy and obtaining Let's Encrypt certificates"
  docker compose --profile edge up -d caddy

  info "waiting for a certificate for ${SWARM_CHAT_DOMAIN}"
  got=no
  for _ in $(seq 1 36); do
    if curl -fsS --max-time 10 "https://${SWARM_CHAT_DOMAIN}/v1/config" -o /dev/null 2>/dev/null; then
      got=yes
      break
    fi
    sleep 5
  done
  if [ "${got}" = "yes" ]; then
    info "https://${SWARM_CHAT_DOMAIN} is serving with a trusted certificate"
  else
    info "WARNING: no trusted certificate yet. Check DNS and ports 80/443, then:"
    info "  docker compose logs caddy"
  fi
fi

# ------------------------------------------------------------------ 9. verify

log "9/9  verifying"

printf '\n'
docker compose ps

printf '\nchat health:            '
curl -fsS --max-time 5 http://127.0.0.1:8081/healthcheck >/dev/null && echo "ok" || echo "FAILED"

printf 'client config:          '
curl -fsS --max-time 5 http://127.0.0.1:8080/v1/config >/dev/null && echo "ok" || echo "FAILED"

printf 'registration stub:      '
docker compose exec -T registration-stub python /app/healthcheck.py >/dev/null 2>&1 && echo "ok" || echo "FAILED"

printf 'foundationdb:           '
docker compose exec -T foundationdb fdbcli --exec 'status minimal' 2>/dev/null | head -1

for r in cache pushscheduler ratelimiters messages; do
  printf 'redis-%-16s ' "${r}:"
  docker compose exec -T "redis-${r}" redis-cli cluster info 2>/dev/null | grep -o 'cluster_state:[a-z]*' || echo "FAILED"
done

printf 'redis-pubsub:           '
docker compose exec -T redis-pubsub redis-cli ping 2>/dev/null || echo "FAILED"

cat <<EOF

$(printf '\033[1m==> the staging server is up\033[0m')

  revision            $(git -C "${SWARM_CHECKOUT}" rev-parse HEAD)
  checkout            ${SWARM_CHECKOUT}
  jar                 ${SWARM_CHECKOUT}/${JAR}
  chat API            https://${SWARM_CHAT_DOMAIN}
  attachments         https://${SWARM_CDN_DOMAIN}
  admin (loopback)    http://127.0.0.1:8081/healthcheck

  PUBLIC parameters for the client builds:
      ${STAGING}/shared/staging-public-params.json
  PRIVATE, back these up off this host:
      ${STAGING}/staging-secrets.yml
      ${STAGING}/.env
      ${STAGING}/certs/

  The fixed verification code every phone number accepts:
      $(grep '^SWARM_STAGING_VERIFICATION_CODE=' "${STAGING}/.env" | cut -d= -f2)
  This host must not be advertised as a real service. docs/STAGING.md section 8
  explains what is switched off and why that matters.
EOF
