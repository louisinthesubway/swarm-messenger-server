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

## 5b. gRPC / HTTP/2 — what libsignal's "H2 connection" is

Written 2026-09-27 by Opus M-H, from the code, **before** the edge was changed. The status of
each step is at the end of this section.

The desktop panicked with `AuthenticatedChatConnection_reserve_username_hash: requires an H2
connection` when a user set a username. This section records what that connection is on both
sides, and what the staging edge has to do to carry it.

### The client: libsignal 0.101.2 (`rust/net`)

The chat route has an HTTP version (`ConnectionConfig.http_version` in `rust/net/src/env.rs`).
With `Http1_1` the chat websocket is an ordinary HTTP/1.1 `Upgrade` and **no HTTP/2 connection
exists**. With `Http2`:

* **Same host, same port.** TLS to the chat host (`chat.swarm.green:443`), minimum TLS 1.3, ALPN
  offering exactly `h2` — there is no HTTP/1.1 fallback on that route
  (`rust/net/infra/src/route/http.rs`).
* **The websocket is an RFC 8441 extended CONNECT**: `:method CONNECT`, `:protocol websocket`,
  `:path /v1/websocket/` (or `/v1/websocket/provisioning/`), `sec-websocket-version: 13`, plus the
  headers the HTTP/1.1 handshake carries (`Authorization: Basic {aci}.{deviceId}:{password}` on
  the authenticated socket, `User-Agent`, `Accept-Language`, `X-Signal-Receive-Stories`). Any 2xx
  answer opens it (`connect_http2` in `rust/net/infra/src/ws.rs`). The server must advertise
  `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`, or the request is refused.
* **gRPC rides the same HTTP/2 connection.** libsignal keeps it next to the websocket stream
  (`shared_h2_connection`) and sends plain gRPC on it:
  `POST /org.signal.chat.<package>.<Service>/<Method>`, `content-type: application/grpc`,
  `te: trailers`, authority = the chat host, no path prefix. Every gRPC request carries the
  websocket's headers except `X-Signal-Receive-Stories` (`start_connect_with_transport` in
  `rust/net/src/chat.rs`): calls on the authenticated socket authenticate with the same Basic
  credentials, calls on the unauthenticated socket carry none.
* **gRPC-only calls.** In 0.101.2 these exist *only* over gRPC (`require_grpc` in
  `rust/bridge/shared/src/net/chat.rs`) and panic without an H2 connection: username reserve /
  confirm / delete, username link set / delete, device name, remove device, list devices,
  registration lock, registration recovery password, phone-number discoverability, push token,
  all backup calls, the call-quality survey and backup-receipt redemption. Everything else
  (messages, keys, profiles, username *lookup*) uses the websocket unless the server's remote
  config switches a call to gRPC (`grpc.*` keys, `chat_grpc_overrides`).
* **Upstream production** (`DOMAIN_CONFIG_CHAT`): host `grpc.chat.signal.org`, TLS 1.3 minimum,
  `Http2`, confirmation header `x-signal-timestamp`, plus domain-fronting proxies that use
  HTTP/1.1 (SWARM has none).

### The server: `OmnibusH2Server` (the `grpc:` block, port 50051)

* A Netty HTTP/2 server. TLS with SNI from `tlsKeyStore`, or — with `grpc.h2c: true`, as on
  staging — cleartext h2c with prior knowledge. It accepts an optional PROXY protocol v1/v2
  header and sets `x-forwarded-for` from it (from the TCP peer otherwise); upstream expects a
  PPv2 load balancer in front (comment in `RequestAttributesInterceptor`). It advertises
  `SETTINGS_ENABLE_CONNECT_PROTOCOL`.
* It routes each HTTP/2 stream by its exact `:path`: `/v1/websocket/` and
  `/v1/websocket/provisioning/` are forwarded frame by frame to
  `grpc.websocketAddress:websocketPort` (Jetty's h2c connector on 8080); **every other path goes
  to the in-process gRPC server** (Netty `LocalAddress("grpc")`). There is no other network entry
  to gRPC.
* Authentication is per service: Accounts, Calling, Credentials, Keys, Profile, Messages,
  Backups, Devices, Attachments, Payments, Challenge, Donations, ProductConfiguration and
  RemoteConfiguration require `Authorization: Basic` (the same account authenticator as REST and
  the websocket); the `*Anonymous` services, CallQualitySurvey, KeyTransparency, LoginPurchase,
  Subscriptions and OneTimeDonations reject any `Authorization` header.
* `GrpcAllowListInterceptor` answers `UNIMPLEMENTED` unless the dynamic configuration allows the
  call. Staging's `minio/dynamic-config.yaml` sets `grpcAllowList.enableAll: true`.
* Staging: `bindAddress 0.0.0.0`, `port 50051`, `websocketAddress localhost`,
  `websocketPort 8080`, `h2c: true`, published on the host as `127.0.0.1:50051` only. Checked on
  the host at 2026-09-27 18:0x UTC with `curl --http2-prior-knowledge`:
  `AccountsAnonymous/CheckAccountExistence` with an empty message answers `grpc-status: 3`
  ("invalid service identifier"), `Accounts/ReserveUsernameHash` without credentials answers
  `grpc-status: 16` ("missing authorization header").

### The edge before the change

* Caddy v2.10.2 (built with Go 1.25.0) negotiates `h2` over TLS 1.3 but advertises
  `ENABLE_CONNECT_PROTOCOL = 0`: Go's HTTP/2 server switches RFC 8441 off unless the process runs
  with `GODEBUG=http2xconnect=1` (golang/go#71128). An extended CONNECT is reset with
  `PROTOCOL_ERROR`, so a libsignal build that selects `Http2` could not open its websocket at
  all, and would lose the whole chat connection.
* `application/grpc` requests fell through to `chat:8080` (Jetty REST) and got HTTP 404.

### The change

1. **Caddy runs with `GODEBUG=http2xconnect=1`** (`docker-compose.yml`, service `caddy`). Caddy
   2.10's `reverse_proxy` already turns an HTTP/2 extended-CONNECT websocket into an HTTP/1.1
   upgrade toward the upstream (`h2_websocket_body` in `reverseproxy.go` / `streaming.go`), so
   the existing `@websocket` route (HTTP/1.1 to `chat:8080`) serves HTTP/1.1 clients (libsignal
   up to `0.101.2-swarm.1`) and HTTP/2 clients (`0.101.2-swarm.2` and later) alike. The
   `x-signal-timestamp` header of Jetty's `101` is copied onto the HTTP/2 `200`.
2. **A `@grpc` route** (`protocol grpc`, i.e. `Content-Type: application/grpc…`) proxies to
   `chat:50051` over h2c with `proxy_protocol v2`, so the omnibus sees the client's address the
   way upstream intends instead of Caddy's. PROXY protocol makes Caddy open one upstream
   connection per request (Caddy turns keep-alive off for it); that is fine at staging volume.
   The omnibus hands the request to the in-process gRPC server; authentication is unchanged.
3. Nothing new is published: `50051` stays bound to `127.0.0.1` on the host, and Caddy reaches
   it over the compose network.
4. **Client:** the `swarm-libsignal` fork sets `http_version: Some(HttpVersion::Http2)` for
   `DOMAIN_CONFIG_CHAT_SWARM` (TLS 1.3 minimum and the `x-signal-timestamp` confirmation header
   stay), released as `swarm-libsignal-0.101.2-swarm.2`.

Considered and rejected: publishing the omnibus directly (`h2c: false`, TLS in the JVM). It needs
a second public port or host name, a PKCS#12 keystore and its renewals, while libsignal dials
exactly one chat host.

Consequences to know:

* A client that selects `Http2` has **no fallback**. If the edge stops advertising extended
  CONNECT (for example Caddy recreated without the `GODEBUG` setting), such a client cannot
  connect at all. Check with any HTTP/2 client that prints the peer's settings
  (`enableConnectProtocol` must be `true`).
* Browsers may now also open WebSockets over HTTP/2 to `chat.swarm.green`; Caddy converts those
  the same way.

Status: **proposed** at the time of writing; the Live Log in the project vault ("Opus M-H
discovery") records when each step was implemented and what was tested.

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

## 8a. Attachments and avatars

Contract written 2026-09-27 (Opus M-J) from this revision's code and the desktop client's, before
the implementation. What is implemented and what was tested on the host is recorded at the end
of this section and in the vault Live Log.

Every byte that reaches the CDN is **ciphertext**. The client encrypts an attachment with a
random per-attachment key (AES-256-CBC + HMAC-SHA256) that travels only inside the end-to-end
encrypted message, and an avatar with the profile key. Neither the chat server, the upload
service nor MinIO ever sees a key. Object names are random, and anyone who knows one can fetch
the ciphertext, exactly as on Signal's own CDNs.

| What | Upload | Stored in MinIO bucket `swarm-cdn` as | Read with |
|---|---|---|---|
| message attachments (images, files, voice notes, link-preview images) | **CDN3**: TUS to `https://cdn.chat.swarm.green/upload/attachments`, served by the `tus` service | `attachments/<key>` | `GET https://cdn.chat.swarm.green/attachments/<key>` |
| profile avatars | **CDN0**: S3 POST-policy form to `https://cdn.chat.swarm.green/`, checked by MinIO | `profiles/<name>` | `GET https://cdn.chat.swarm.green/profiles/<name>` |

CDN2 (Google Cloud Storage resumable uploads) cannot work here and is never handed out once the
`cdn3` experiment below is on. Upload forms that still said CDN2 are what made the first
attachment on 2026-09-27 spin forever (`POST https://gcs.disabled.swarm.invalid/...`, DNS failure).

### CDN3: the upload form

`GET /v4/attachments/form/upload?uploadLength=<bytes>` (REST or the chat websocket; the gRPC
`AttachmentsGrpcService.getUploadForm` does the same). `AttachmentControllerV4` returns a CDN3
form only to accounts enrolled in the **dynamic-configuration experiment `cdn3`**, and a CDN2 form
to everyone else. Staging enrols everyone, in `minio/dynamic-config.yaml`:

```yaml
experiments:
  cdn3:
    enrollmentPercentage: 100
```

There is no weight table in `staging.yml`; that experiment is the switch. The form:

```json
{
  "cdn": 3,
  "key": "<20 characters: base64url of 15 random bytes>",
  "headers": {
    "Authorization": "Bearer <JWT>",
    "Upload-Metadata": "filename <standard base64 of the key>"
  },
  "signedUploadLocation": "https://cdn.chat.swarm.green/upload/attachments"
}
```

`signedUploadLocation` is `tus.uploadUri` from `staging.yml`
(`https://` + the CDN domain + `/upload`) followed by `/attachments`.

### CDN3: the token

`TusAttachmentGenerator` signs a JWT with `JwtGenerator`: **HS256**, HMAC key = the 32 bytes that
`tus.userAuthenticationTokenSharedSecret` in `staging-secrets.yml` decodes to (base64). Header
`{"alg":"HS256","typ":"JWT"}`. Claims:

| Claim | Value |
|---|---|
| `aud` | `"attachments"` |
| `sub` | the key |
| `iat` | issue time, seconds |
| `maxLen` | the `uploadLength` the form was requested for |

There is no `exp`. The upload service follows Signal's own tus-server
(`github.com/signalapp/tus-server`, `src/index.ts`): the token is accepted for **7 days** after
`iat`, `aud` must be `attachments`, `sub` must equal the key being written (taken from
`Upload-Metadata` on POST and from the path on HEAD/PATCH), and `maxLen` must be present. One token
therefore writes one key, at most `maxLen` bytes, and never more than
`attachments.maxAttachmentUploadSizeInBytes` (100 MiB). Older upstream revisions used HTTP Basic
credentials derived from the same secret by HMAC; this revision does not.

### CDN3: upload, resume, download

What the desktop does (`ts/util/uploadAttachment.preload.ts`, `ts/util/uploads/tusProtocol.node.ts`):

```
POST /upload/attachments                              creation-with-upload, one request
  Authorization: Bearer <JWT>                         (from the form)
  Upload-Metadata: filename <base64(key)>
  Tus-Resumable: 1.0.0
  Upload-Length: <ciphertext bytes>
  Content-Type: application/offset+octet-stream
  <the ciphertext, usually Transfer-Encoding: chunked>

-> 201 Created
   Location: https://cdn.chat.swarm.green/upload/attachments/<key>
   Upload-Offset: <bytes stored>
   Upload-Expires: <RFC 9110 date>
   Tus-Resumable: 1.0.0
```

When `Upload-Offset` equals `Upload-Length`, the object is already in MinIO at
`attachments/<key>` before the 201 is sent, so the recipient can download it the moment the
message arrives. The client only needs a 2xx.

Only if that connection breaks does the client resume, and it does **not** follow `Location`: it
builds `<signedUploadLocation>/<key>` itself.

```
HEAD  /upload/attachments/<key>    Authorization, Tus-Resumable
-> 200  Upload-Offset, Upload-Length, Cache-Control: no-store

PATCH /upload/attachments/<key>    Authorization, Tus-Resumable,
                                   Upload-Offset: <offset from HEAD>,
                                   Content-Type: application/offset+octet-stream, the rest
-> 204  Upload-Offset
```

A HEAD for an upload that already finished answers from the stored object (offset = length),
so a client that lost the 201 stops instead of re-sending. That fixed resume address is why the
upload service is purpose-built rather than `tusd`: tusd's S3 store names every upload
`<object-id>+<multipart-id>`, so `<signedUploadLocation>/<key>` would never find it.

| Status | When |
|---|---|
| 201 / 200 / 204 | POST / HEAD / PATCH succeeded |
| 204 | `OPTIONS /upload/attachments`: `Tus-Version: 1.0.0`, `Tus-Extension: creation,creation-with-upload`, `Tus-Max-Size`. No token needed |
| 400 | `Authorization` is not `Bearer …`; `Upload-Length` or `Upload-Offset` missing or not a number; unreadable `Upload-Metadata`; a key that is not base64url |
| 401 | no token, bad signature, not HS256, `aud` is not `attachments`, older than 7 days, no `maxLen`, or `sub` is not this key |
| 404 | HEAD/PATCH for an upload that does not exist (never created, expired, or failed) |
| 409 | PATCH `Upload-Offset` is not the stored offset; a second POST for a key that already holds bytes (the partial upload is discarded, as upstream does) |
| 412 | `Tus-Resumable` missing or not `1.0.0` |
| 413 | `Upload-Length` above `maxLen` or above 100 MiB; a body running past `Upload-Length` (the upload is discarded) |
| 415 | a body without `Content-Type: application/offset+octet-stream`; an `X-Signal-Checksum-Sha256` that does not match |
| 500 | MinIO refused or failed the write. The bytes are kept; the next HEAD retries the write. The desktop retries the whole send with a new form anyway |

Partial uploads are kept for 7 days (`Upload-Expires`), then deleted.

**Download.** `GET /attachments/<key>` and `HEAD /attachments/<key>`, no credentials; `Range:
bytes=<n>-` answers 206 for resumed downloads. The desktop refuses a full download without
`Content-Length`, which is why the CDN site does not compress (Caddy's encoder would drop it;
ciphertext does not compress anyway).

### CDN0: avatars

1. `PUT /v1/profile` with `"avatar": true` answers with an upload form made by `PostPolicyGenerator`
   from the `cdn` block of `staging.yml` (MinIO bucket `swarm-cdn`, region `us-east-1`, the scoped
   `cdn.accessKey` / `cdn.accessSecret`): `key` (`profiles/` + base64url of 16 random bytes),
   `credential` (`<cdn.accessKey>/<yyyymmdd>/us-east-1/s3/aws4_request`), `acl` (`private`),
   `algorithm` (`AWS4-HMAC-SHA256`), `date`, `policy` (base64 JSON: this bucket, this key, 1 to
   10 MiB, any `Content-Type`, expires in 30 minutes) and `signature` (SigV4 over the policy).
2. The client `POST`s `multipart/form-data` to `https://cdn.chat.swarm.green/` with the fields
   `key`, `x-amz-credential`, `acl`, `x-amz-algorithm`, `x-amz-date`, `policy`, `x-amz-signature`,
   `Content-Type`, then `file` (the encrypted avatar). The edge hands it to MinIO's bucket
   endpoint; **MinIO** checks the policy and its signature against the scoped CDN key, which may
   write only to `swarm-cdn`. Success is 204.
3. Readers fetch `GET https://cdn.chat.swarm.green/profiles/<name>` without credentials and decrypt
   with the profile key they received in a message.

### The edge for `cdn.chat.swarm.green`

| Method | Path | Goes to | Who checks what |
|---|---|---|---|
| POST, PATCH, HEAD, OPTIONS | `/upload/attachments`, `/upload/attachments/*` | `tus:1080` | the service verifies the JWT on every POST, HEAD and PATCH |
| POST, `Content-Type: multipart/form-data` | `/` | MinIO, bucket `swarm-cdn` | MinIO verifies the POST policy and its SigV4 signature |
| GET, HEAD | `/attachments/*`, `/profiles/*` | MinIO, bucket `swarm-cdn` | bucket policy: anonymous `s3:GetObject` on exactly these two prefixes; no listing, nothing else |
| anything else | | 404 | |

Nothing published accepts an unauthenticated write: a TUS write needs the chat server's token, a
POST-policy write needs a policy signed with the CDN key.

### The upload service: `deploy/staging/tus/`

Node 22, standard library only (`server.mjs`), about the size of the registration stub. It
stages the bytes of an upload in the volume `tus-data` and, when the last byte arrives, writes the
object to MinIO with one SigV4 `PutObject`, using its **own** MinIO user, which may only put and
get objects under `swarm-cdn/attachments/`. Its credentials live in `deploy/staging/tus.env`
(mode 600, git-ignored), written once by `tus/make-tus-env.sh`: its copy of
`tus.userAuthenticationTokenSharedSecret` (it must stay equal to the one in
`staging-secrets.yml`) and its MinIO key. A separate file, so the chat container's environment
does not change.

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
