# SWARM Messenger staging server — runbook

A self-hosted Signal-Server derivative on one Linux host. Registration, accounts, prekeys,
profiles and messaging work. Every cloud dependency is replaced by a container on the same
host, and every feature that needs an SGX enclave or a commercial account is switched off.

Everything described here lives in [`deploy/staging/`](../deploy/staging). Deviations from
upstream code are in [`SWARM-CHANGES.md`](SWARM-CHANGES.md). What was and was not verified on
the machine this was built on is in
[`STAGING-PROOF-2026-09-26.md`](STAGING-PROOF-2026-09-26.md).

---

## 1. Host

| | |
|---|---|
| OS | Debian 12 or Ubuntu 24.04, x86-64. FoundationDB 7.3 has no ARM client in the pinned release, and `libfdb_c.x86_64.so` is what the build downloads |
| CPU | 8 vCPU (4 is enough while idle; FoundationDB and the JVM both want cores under load) |
| RAM | **16 GB.** Budget: JVM 6 GB, FoundationDB 4 GB, DynamoDB Local (a JVM too) 1.5 GB, five Redis ~0.5 GB, MinIO 0.5 GB, Caddy 0.1 GB, headroom 3 GB |
| Disk | 200 GB SSD. FoundationDB's `ssd` engine wants real SSD latency. Messages are deleted on delivery, but undelivered messages and attachments accumulate |
| Docker | Engine 24+ with the Compose v2 plugin. **Not** Docker Desktop |
| Swap | at least 2 GB, so a JVM spike does not OOM-kill FoundationDB |
| Outbound | only for pulling images and Let's Encrypt. The stack contacts no third party at runtime |

Do not put this on the same host as the SWARM mainnet node or the explorer: FoundationDB and
zebrad will fight over disk I/O.

### Kernel and limits

FoundationDB and a busy Netty server both want file descriptors:

```sh
# /etc/security/limits.d/swarm.conf
*  soft  nofile  65536
*  hard  nofile  65536
```

```sh
# /etc/sysctl.d/99-swarm.conf
vm.max_map_count = 262144
net.core.somaxconn = 4096
```

---

## 2. Ports

Published on the host:

| Port | Bind | Service | Purpose |
|---|---|---|---|
| 443 (tcp+udp) | `0.0.0.0` | Caddy | public HTTPS / HTTP-3 for `chat.` and `cdn.` |
| 80 | `0.0.0.0` | Caddy | ACME challenge and HTTP→HTTPS redirect |
| 8080 | `127.0.0.1` | chat | h2c REST + websocket. Loopback only; Caddy reaches it over the Docker network |
| 8081 | `127.0.0.1` | chat | Dropwizard admin: `/healthcheck`, `/metrics`. **Never publish this** |
| 50051 | `127.0.0.1` | chat | the gRPC "omnibus" listener. Publish it only when a client actually needs gRPC, and put it behind TLS |

Internal to the Docker network `swarm-staging` (10.77.0.0/24), never published:

| Address | Service |
|---|---|
| `10.77.0.11:4500` | FoundationDB |
| `dynamodb:8000` | DynamoDB Local |
| `10.77.0.21-24:6379` | the four Redis clusters (cache, push scheduler, rate limiters, message cache) |
| `10.77.0.25:6379` | the standalone Redis for `pubsub` |
| `minio:9000`, `minio:9001` | MinIO S3 API and console |
| `registration-stub:8443` | the fixed-code registration stub, gRPC over TLS with a private CA |

The Redis clusters have static IPs on purpose: a Redis cluster advertises the address it
believes it has, and Lettuce connects to whatever `CLUSTER SLOTS` returns. With dynamic
container IPs the advertised address can go stale after a restart.

### Firewall

```sh
ufw default deny incoming
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443
ufw enable
```

---

## 3. DNS

Four names, all `A` (and `AAAA` if the host has IPv6) to the staging host:

| Name | Answered by | Status |
|---|---|---|
| `chat.swarm.green` | Caddy → chat:8080 | **required.** The API and the websocket. This is the only endpoint clients talk to |
| `cdn.chat.swarm.green` | Caddy → MinIO, read-only | **required for attachments.** GET/HEAD only; uploads go through the chat server's signed-URL flow |
| `reg.chat.swarm.green` | Caddy, returns 404 | **reserved, deliberately not proxied.** The registration stub accepts one fixed code for every phone number; publishing it would let anyone register any number. The name exists so a misconfigured client fails loudly instead of silently reaching something else |
| `sfu.chat.swarm.green` | nothing yet | **reserved.** Named in the TURN configuration because `CloudflareTurnConfiguration.urls` is `@NotEmpty` and cannot be left empty. No SFU or TURN server is deployed, so calling does not work |

Point DNS at the host **before** starting the `edge` profile: Caddy's ACME client fails
(and backs off) if the names do not resolve to it yet.

---

## 4. TLS

Two independent layers.

**Public edge — Caddy, the default.** `deploy/staging/caddy/Caddyfile` gets certificates from
Let's Encrypt automatically and proxies to the chat server over cleartext h2c inside the
Docker network. The chat server's `server.applicationConnectors` is a `h2c` connector with
`useForwardedHeaders: true`, so `X-Forwarded-For` from Caddy is what rate limiting sees.
Uncomment `acme_ca` in the Caddyfile to use Let's Encrypt staging while testing DNS, then
comment it out again — a staging certificate is not trusted by clients.

**Alternative — the JVM terminates TLS.** Replace the `h2c` connector in `staging.yml` with a
`type: h2` connector carrying `keyStorePath` / `keyStorePassword`, put the matching PKCS#12
keystore path in `tlsKeyStore.path`, and do not start the `edge` profile. You then own renewal.
Caddy is the default because renewal is the part that breaks at 3am.

**Internal — the registration hop.** Upstream's `RegistrationServiceClient` always opens a TLS
channel and trusts exactly the CA in `registrationService.registrationCaCertificate`. That is a
private CA created by `deploy/staging/certs/make-certs.sh`, valid for `registration-stub`,
`reg.chat.swarm.green` and `localhost`. It has nothing to do with the public certificates.

---

## 5. First install

### One command, on a fresh Ubuntu 24.04 host

```sh
curl -fsSL <raw url of deploy/staging/bootstrap-host.sh> -o bootstrap-host.sh
sudo SWARM_ACME_EMAIL=you@example.com SWARM_COMMIT=<full sha of the revision to run> \
     bash bootstrap-host.sh
```

`deploy/staging/bootstrap-host.sh` checks the host, installs Docker Engine and the compose
plugin from Docker's apt repository, installs Temurin JDK 26, clones
`Swarm-Official/swarm-messenger-server` at the commit you name, builds the shaded jar,
generates this deployment's secrets and public parameters, starts the stack, starts Caddy so
Let's Encrypt issues certificates for `chat.` and `cdn.`, and then verifies every component.
It is idempotent and will not overwrite secrets that already exist.

`SWARM_COMMIT` is required: a server should run a revision somebody chose, not whatever
`swarm-main` happens to be. Set `SWARM_ALLOW_FLOATING_REF=yes` to override that deliberately.
Set `SWARM_SKIP_EDGE=yes` to bring the stack up before DNS points here, then run
`docker compose --profile edge up -d caddy` afterwards.

Point the A records at the host **before** running it with the edge enabled; the script warns
if `chat.` and `cdn.` do not resolve to this host's public IP, because Let's Encrypt will fail.

### By hand

```sh
git clone <this repo> swarm-messenger-server && cd swarm-messenger-server
git checkout swarm-main

# 1. Build the shaded jar. -Pexclude-spam-filter is upstream's profile and is REQUIRED:
#    it is what runs the shade plugin and downloads libfdb_c.so. Needs JDK 26.
./mvnw -DskipTests -Pexclude-spam-filter package

cd deploy/staging

# 2. Stage exactly what the chat image needs (one jar, one libfdb_c.so) into build/.
./prepare-image.sh

# 3. Generate this deployment's secrets, internal CA, .env and staging-secrets.yml.
#    Uses the server's own certificate command and zkparams/SwarmZkParams.java, i.e. libsignal.
./generate-secrets.sh

# 4. One value the script cannot know.
$EDITOR .env          # set SWARM_ACME_EMAIL

# 5. Bring it up. Compose ordering is in the file: the bootstrap one-shots must finish
#    before `chat` starts.
docker compose up -d

# 6. Watch the server come up. Expect 60-150s before /healthcheck answers.
docker compose logs -f chat
```

Then, once DNS resolves to this host:

```sh
docker compose --profile edge up -d caddy
```

`generate-secrets.sh` writes `deploy/staging/shared/staging-public-params.json`. That file is
what the client builds need — see the next section. Hand it over and record it in the vault.

---

## 5a. Public parameters for the clients

Every SWARM Messenger client is compiled against values that must match this server exactly.
Get one wrong and the failure is confusing rather than obvious: sealed-sender messages are
rejected, or profile fetches fail with a zero-knowledge verification error instead of an HTTP
error.

`generate-secrets.sh` writes them all to `deploy/staging/shared/staging-public-params.json`.
Everything in it is public; the matching private halves exist only in
`deploy/staging/staging-secrets.yml`. `shared/` is git-ignored, because the values are
per-deployment, not per-repository.

```json
{
  "schema": "swarm-messenger/staging-public-params/1",
  "generatedAt": "2026-09-26T17:22:00Z",
  "environment": "staging",
  "endpoints": {
    "chat": "https://chat.swarm.green",
    "chatWebsocket": "wss://chat.swarm.green/v1/websocket",
    "cdn": "https://cdn.chat.swarm.green",
    "registration": null,
    "sfu": null
  },
  "serverPublicParams": "<900 base64 chars>",
  "genericServerPublicParams": "<300 base64 chars>",
  "backupServerPublicParams": "<300 base64 chars>",
  "callingServerPublicParams": "<300 base64 chars>",
  "callingServerPublicParamsPreV101": "<300 base64 chars>",
  "serverTrustRoots": ["<44 base64 chars>"],
  "registrationCaCertificatePem": "-----BEGIN CERTIFICATE-----\n…",
  "comments": { "…": "one line per field, restating what is in the table below" }
}
```

| Field | What it is | Where it comes from |
|---|---|---|
| `serverPublicParams` | libsignal zkgroup `ServerPublicParams`: groups, profile keys, auth credentials | public half of `groupsZkConfig.serverSecret` |
| `genericServerPublicParams` | libsignal `GenericServerPublicParams` | public half of `chatZkConfig.serverSecret` |
| `backupServerPublicParams` | the same value as `genericServerPublicParams` in this upstream revision, because `BackupAuthManager` is constructed with the chat generic params. Kept as a separate field because upstream may split them, and then clients need both | public half of `chatZkConfig.serverSecret` |
| `callingServerPublicParams`, `…PreV101` | calling credentials, current and legacy | public halves of `callingZkConfig` / `callingZkConfigPreV101` |
| `serverTrustRoots` | sealed-sender trust roots, base64 public keys. A **list**, so a future rotation can publish the new root beside the old one and clients accept both during the overlap | public half of `unidentifiedDelivery.privateKey`; the server's `unidentifiedDelivery.certificate` is signed by it |
| `registrationCaCertificatePem` | the stack's **internal** CA, used only for the chat server's gRPC hop to the registration stub. **Clients do not need it**; public HTTPS uses Let's Encrypt | `certs/swarm-staging-ca.crt`, also in `.env` as `SWARM_REGISTRATION_CA_PEM` |
| `endpoints.registration` | `null` on purpose: `reg.chat.swarm.green` is not published | — |
| `endpoints.sfu` | `null` on purpose: no SFU or TURN server exists | — |

The zk parameter sets are **not** interchangeable types. `serverPublicParams` is a zkgroup
`ServerPublicParams` (900 base64 characters); the other three are `GenericServerPublicParams`
(300). The server's own `zkparams` command generates only the first kind, which is why
`deploy/staging/zkparams/SwarmZkParams.java` exists: it calls libsignal's
`GenericServerSecretParams.generate()` for the other three. Putting a `ServerSecretParams` blob
in `chatZkConfig` passes the configuration check and then throws at startup.

`zkparams` also prints base64 **without** padding, while the server reads these values as
`byte[]`/`SecretBytes` and rejects unpadded base64 with a misleading
`is of type: String, expected: byte[]`. `SwarmZkParams` and `generate-secrets.sh` pad.

### How a client actually reaches this server

This is the current bottleneck for end-to-end testing, and it is not a server problem.

libsignal's `Net` / `ChatConnection` layer does not take an arbitrary hostname. It takes an
**environment** — production or staging — and each environment carries Signal's own hostnames
and its own pinned certificate authority, compiled into the Rust library. Pointing a client at
`chat.swarm.green` is therefore not a configuration change in the client; it is a change in
libsignal.

Two ways out, in the order they become available:

1. **libsignal's loopback / local-testing environment.** libsignal exposes a local environment
   used by its own integration tests, which takes a host, a port and a supplied trust root
   instead of the compiled-in Signal ones. That is how the desktop client can talk to this
   staging server today — fine for development on one machine or over a tunnel, not a shipping
   configuration.
2. **A SWARM environment in the `swarm-libsignal` fork** (Opus M-D's work). It adds an
   environment whose hostnames are the `swarm.green` names and whose trust anchors are the
   public Web PKI roots that Let's Encrypt chains to, plus our own CA if we ever want it. Once
   that lands, a client selects the SWARM environment and needs no loopback and no
   per-developer setup.

Until (2) lands, treat "two desktop clients exchanging a message through this server" as
blocked on libsignal, not on the server. The REST and websocket surfaces are reachable with
ordinary HTTP tooling in the meantime, which is what the walk-through in section 7 uses.

---

## 6. Start order

Compose enforces this with `depends_on` conditions, but know it for debugging:

```
foundationdb            (healthy: fdbcli reports "The database is available")
  └─ foundationdb-init  (runs "configure new single ssd" once, then exits 0)
dynamodb                (healthy: answers HTTP)
  └─ dynamodb-bootstrap (creates 34 tables + TTLs, then exits 0)
minio                   (healthy: mc ready)
  └─ minio-bootstrap    (3 buckets, scoped CDN key, uploads the 2 polled objects, exits 0)
redis-cache, redis-pushscheduler, redis-ratelimiters, redis-messages
                        (healthy: cluster_state:ok)
redis-pubsub            (healthy: PONG)
registration-stub       (healthy: a CreateSession round trip over its own TLS)
  └─ chat               (healthy: GET :8081/healthcheck is 200)
       └─ caddy         (profile: edge)
```

Two of those one-shots are not optional in a subtle way:

* **`foundationdb-init`.** A fresh FoundationDB cluster has *no database* until
  `configure new` is run. Without it the chat server blocks on its first transaction.
* **`minio-bootstrap`.** `DynamicConfigurationManager.getConfiguration()` blocks on a latch
  until the first successful read of `s3://swarm-config/dynamic-config.yaml`. If that object is
  missing, the server hangs part-way through startup with no error — it does not crash. If
  `chat` sits silent, check that object first.

### Shutdown and restart

```sh
docker compose stop chat        # drain the server first
docker compose down             # keeps volumes
docker compose down -v          # DESTROYS accounts, messages, attachments
```

`health.delayedShutdownHandlerEnabled` is `false` in `staging.yml`, so the server does not hold
the port open draining connections. Set it to `true` before anyone real uses the host.

---

## 7. Health checks

```sh
# the server itself
curl -sf http://127.0.0.1:8081/healthcheck && echo OK

# metrics (Prometheus format is not exposed; this is Dropwizard's JSON)
curl -s http://127.0.0.1:8081/metrics | head

# what clients get
curl -s http://127.0.0.1:8080/v1/config

# FoundationDB
docker compose exec foundationdb fdbcli --exec 'status minimal'
docker compose exec foundationdb fdbcli --exec 'status details'

# DynamoDB tables
docker compose run --rm --entrypoint sh dynamodb-bootstrap -c \
  'aws dynamodb list-tables --endpoint-url http://dynamodb:8000'

# each Redis cluster
for r in cache pushscheduler ratelimiters messages; do
  echo -n "$r: "; docker compose exec "redis-$r" redis-cli cluster info | grep cluster_state
done
docker compose exec redis-pubsub redis-cli ping

# MinIO
docker compose exec minio mc ready local

# the registration stub
docker compose exec registration-stub python /app/healthcheck.py && echo STUB-OK

# everything at a glance
docker compose ps
```

### Registering a test account by hand

The captcha requirement is satisfied by the literal token `noop.noop.registration.noop`,
because the private `spam-filter` submodule is not part of this fork and upstream's own no-op
captcha client takes over (see `SWARM-CHANGES.md` §3).

```sh
# 1. open a session
curl -s -X POST http://127.0.0.1:8080/v1/verification/session \
  -H 'Content-Type: application/json' \
  -d '{"number":"+15555550123"}'
# -> {"id":"<base64url session id>", "allowedToRequestCode":true, ...}

# 2. ask for the code (the stub logs it; it is always SWARM_STAGING_VERIFICATION_CODE)
curl -s -X POST "http://127.0.0.1:8080/v1/verification/session/<id>/code" \
  -H 'Content-Type: application/json' \
  -d '{"transport":"sms","client":"android-without-fcm"}'

# 3. submit it
curl -s -X PUT "http://127.0.0.1:8080/v1/verification/session/<id>/code" \
  -H 'Content-Type: application/json' \
  -d '{"code":"123456"}'
# -> "verified": true

# 4. POST /v1/registration needs a full set of generated keys (identity key, signed prekey,
#    PQ last-resort prekey, registration ids, an account password). Do not hand-roll them:
#    use @signalapp/libsignal-client, or drive it from the SWARM Messenger desktop client's
#    standalone registration path, which is exactly what it is for.
```

`docker compose logs registration-stub` shows the code on every `SendVerificationCode`.

---

## 8. What is disabled, and what it costs

Everything in this section is switched off by **configuration only** —
`deploy/staging/staging.yml`. No code was removed. Blocks for disabled features keep upstream's
own placeholder values from `service/src/test/resources/config/test.yml`, because upstream
demonstrably boots a server with them (`./mvnw integration-test -Ptest-server`).

| Feature | How it is off | Consequence for clients |
|---|---|---|
| **SVR2 / SVRB** (PIN recovery) | hostnames `svr2.disabled.swarm.invalid` / `svrb.disabled.swarm.invalid`, which do not resolve | No PIN-based account recovery and no registration lock. Losing a device loses the account. Needs SGX hardware and Signal's enclave build; not achievable on a VPS |
| **CDSI / `directoryV2`** (contact discovery) | no CDSI cluster is deployed; only the token-minting secrets are configured | Clients cannot ask "which of my contacts are on SWARM?". Usernames and manually exchanged addresses still work. Also an SGX enclave service |
| **Key transparency** | host `kt.disabled.swarm.invalid` | No transparency log for identity keys. Safety-number verification still works client-to-client |
| **Stripe / Braintree / Google Play / App Store** | placeholder credentials that cannot authenticate; no merchant account exists | Donations, badges and paid backup tiers do not work. The server still constructs all four managers at startup — upstream does so unconditionally — so the blocks must parse |
| **APNs** | `disabled` team/key id and a freshly generated throwaway EC key | iOS devices do not wake on new messages |
| **FCM** | a service-account JSON that points at nothing | Android devices do not wake on new messages |
| **Push in general** | consequence of the two above | **Desktop is unaffected**: it holds a websocket open and receives messages in real time. This is why desktop is phase 1 |
| **GCP attachments (CDN0/CDN2)** | `gcs.disabled.swarm.invalid`, throwaway RSA signing key | The CDN0/CDN2 upload-form endpoints return unusable URLs. Attachments go through the `cdn` block (MinIO) instead |
| **Cloudflare TURN / calling** | `urls` names `sfu.chat.swarm.green`, which has no server; API endpoint is `turn.disabled.swarm.invalid` | Voice and video calling does not work. `urls` and `urlsWithIps` are `@NotEmpty` upstream, so they could not simply be emptied |
| **MobileCoin payments** | `paymentCurrencies: [MOB]` kept only because it is `@NotEmpty`; conversion API keys are `unset` | Upstream's payment feature is dead. Irrelevant: the SWARM wallet is on-device and does not use it |
| **Spam filtering, registration fraud checks, captcha** | the private `spam-filter` submodule is not part of this fork | Upstream's no-op implementations apply. **Captcha accepts the token `noop.noop.registration.noop`** — that is what makes manual registration possible, and it is also why this stack must never be exposed as a real service |
| **OpenTelemetry** | `enabled: false` | No traces. Turn it on and point `url` at a collector if you want them |

### The three that matter for a production decision

1. **No captcha and a fixed verification code.** Anyone who can reach this server can register
   any phone number. It is a staging stack. Do not advertise the host, and consider an IP
   allow-list at the edge until real registration exists.
2. **No push.** Mobile clients will look broken. Desktop will not.
3. **No PIN recovery.** By design for phase 1 (project decision 4: no server-side recovery
   enclave), and it is also the honest privacy position — but it means device loss is account
   loss, and users must be told.

---

## 9. Backup and recovery

| What | Where | How |
|---|---|---|
| **`deploy/staging/staging-secrets.yml`** | host filesystem, mode 600 | **Back this up off the host.** The four zk secrets and the sealed-sender trust root are baked into credentials clients already hold; rotating them means updating every client |
| **`deploy/staging/certs/`** | host filesystem | back up. Regenerating means editing `SWARM_REGISTRATION_CA_PEM` in `.env` and restarting `chat` |
| **`deploy/staging/.env`** | host filesystem, mode 600 | back up. Contains the public zk half and the sealed-sender certificate, which must stay paired with the secrets |
| `deploy/staging/shared/staging-public-params.json` | host filesystem | public, but regenerate-or-back-up: it is the record of what the clients were built against |
| Accounts, keys, profiles, sessions | Docker volume `dynamodb-data` | `docker compose stop chat dynamodb && tar` the volume. DynamoDB Local is a single SQLite-ish file per table set |
| Undelivered and stored messages | Docker volume `fdb-data` + `redis-messages-data` | `fdbbackup` for a consistent copy. For staging, stopping `chat` and tarring the volume is acceptable |
| Attachments | Docker volume `minio-data` | `mc mirror` to another location |

Nothing here is a supported disaster-recovery story. It is a staging stack: assume you can
lose it and re-register the test accounts.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `chat` logs stop after "Initial request for s3://swarm-config/dynamic-config.yaml" and nothing else happens | the dynamic-config object is missing; `getConfiguration()` is blocked on a latch | `docker compose up minio-bootstrap` and restart `chat` |
| `chat` exits with "registrationService type \"swarm-staging\" is a staging-only …" | `SWARM_STAGING_FIXED_CODE` is not exactly `true` in the environment | fix `.env`, `docker compose up -d chat` |
| `registration-stub` exits 78 immediately | same variable, same fix | |
| `chat` logs `UnknownHostException: swarm-cdn.minio.swarm.local` | the MinIO network aliases are missing, or `MINIO_DOMAIN` is not set | check the `minio` service's `networks.swarm.aliases` in `docker-compose.yml` |
| `chat` logs Lettuce "Connection refused" to an address that is not a container name | a Redis cluster is advertising a stale IP | `docker compose down redis-<role>` and up again; the static IPs must match `REDIS_CLUSTER_ANNOUNCE_IP` |
| `fdbcli` says "The database is unavailable" | `configure new` never ran | `docker compose up foundationdb-init` |
| `java.lang.UnsatisfiedLinkError: no fdb_c` | `libfdb_c.so` is missing from the image | rebuild with `-Pexclude-spam-filter`, which downloads it, then `docker compose build chat` |
| DynamoDB `ResourceNotFoundException` naming a `swarm_*` table | the bootstrap one-shot did not finish | `docker compose up dynamodb-bootstrap` and read its output |
| Caddy cannot get a certificate | DNS does not point here yet, or 80/443 are blocked | fix DNS/firewall; use `acme_ca` staging while testing to avoid rate limits |
| Registration returns 402 or 428 | a captcha or push challenge is required | send the captcha token `noop.noop.registration.noop` |

Logs:

```sh
docker compose logs -f chat | grep -v 'DEBUG'
docker compose logs registration-stub          # the verification code is here
docker compose logs foundationdb-init dynamodb-bootstrap minio-bootstrap
```

---

## 11. Before this becomes anything more than staging

- [ ] Real registration: an SMS provider and the real `registration-service`, replacing the
      stub, and `registrationService.type: default` with a working identity token.
- [ ] A real captcha provider (the `spam-filter` module is Signal-private; a replacement has to
      be written).
- [ ] Push: an Apple developer account for APNs and a Firebase project for FCM, or a
      push-free mobile design.
- [ ] FoundationDB with `double` or `triple` redundancy across separate machines, and a real
      DynamoDB (or a DynamoDB-compatible cluster) instead of DynamoDB Local, which is a
      single-process test tool with no durability guarantees.
- [ ] Three nodes per Redis cluster instead of one.
- [ ] `health.delayedShutdownHandlerEnabled: true`.
- [ ] Off-host backups of `staging-secrets.yml`, `certs/` and the data volumes.
- [ ] A decision on PIN recovery: SVR needs SGX hardware, which a normal VPS does not have.
