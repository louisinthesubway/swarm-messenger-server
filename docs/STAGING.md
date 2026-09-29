# SWARM Messenger staging server — runbook

A self-hosted Signal-Server derivative on one Linux host. Registration, accounts, prekeys,
profiles and messaging work, since 2026-09-28 groups and settings sync (Signal's separate
storage service, section 5c), and since 2026-09-29 voice and video calls, one-to-one and in groups,
and call links (a TURN relay and Signal's calling service, section 5d). Every cloud dependency is
replaced by a container on the same host, and every feature that needs an SGX enclave or a
commercial account is switched off.

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
| 443 (tcp+udp) | `0.0.0.0` | Caddy | public HTTPS / HTTP-3 for `chat.`, `cdn.` and `sfu.` |
| 3478 (udp+tcp) | `64.95.11.180` | coturn (host network) | TURN for one-to-one calls (section 5d) |
| 49160-49259/udp | `64.95.11.180` | coturn | TURN relay ports, one per allocation |
| 10000 (udp+tcp) | `0.0.0.0` | calling-backend | group-call media (ICE/SRTP), UDP first, TCP for networks that block UDP |
| 80 | `0.0.0.0` | Caddy | ACME challenge and HTTP→HTTPS redirect |
| 8080 | `127.0.0.1` | chat | h2c REST + websocket. Loopback only; Caddy reaches it over the Docker network |
| 8081 | `127.0.0.1` | chat | Dropwizard admin: `/healthcheck`, `/metrics`. **Never publish this** |
| 50051 | `127.0.0.1` | chat | the gRPC "omnibus" listener (h2c). Not published: Caddy carries `application/grpc` requests from `chat.swarm.green` to it over the Docker network, with PROXY protocol v2 (section 5b) |

Internal to the Docker network `swarm-staging` (10.77.0.0/24), never published:

| Address | Service |
|---|---|
| `10.77.0.11:4500` | FoundationDB |
| `dynamodb:8000` | DynamoDB Local |
| `10.77.0.21-24:6379` | the four Redis clusters (cache, push scheduler, rate limiters, message cache) |
| `10.77.0.25:6379` | the standalone Redis for `pubsub` |
| `minio:9000`, `minio:9001` | MinIO S3 API and console |
| `tus:1080` | the CDN3 (TUS) upload service for attachments. Caddy publishes only `/upload/attachments` on it (section 8a) |
| `registration-stub:8443` | the fixed-code registration stub, gRPC over TLS with a private CA |
| `storage:8080`, `storage:8081` | the storage service (groups, settings sync) and its Dropwizard admin. Caddy publishes only `/v1/storage*` and `/v2/groups*` on it (section 5c) |
| `bigtable:8086` | the Bigtable emulator (gRPC): the storage service's tables until its switch to FoundationDB (section 5c), then only the migration's source |
| `turn-credentials:8080` | TURN credentials in Cloudflare's API shape, for the chat server only (section 5d) |
| `calling-frontend:8080`, `:8100` | the calling service's client API (Caddy publishes `/v2/conference/participants` and `/v1/call-link` on `sfu.`) and its internal API for the backend |
| `10.77.0.31:8080` | `calling-backend`'s signaling API, for the frontend (fixed address: the frontend stores it in each call record) |

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
./ufw-calls.sh     # calls (section 5d): 3478/udp+tcp, 49160:49259/udp, 10000/udp+tcp
```

coturn runs in the host's network namespace, so UFW decides whether it is reachable. Ports that
Docker publishes (443, 80, 10000) are forwarded by Docker's own iptables chains before UFW's rules are
consulted; their UFW rules document the opening rather than create it.

---

## 3. DNS

Four names, all `A` (and `AAAA` if the host has IPv6) to the staging host:

| Name | Answered by | Status |
|---|---|---|
| `chat.swarm.green` | Caddy → chat:8080 (REST, websocket), chat:50051 (gRPC) | **required.** The API, the websocket and gRPC. This is the only endpoint clients talk to |
| `cdn.chat.swarm.green` | Caddy → MinIO and the `tus` service | **required for attachments and avatars.** Anonymous GET/HEAD of `attachments/*`, `profiles/*` and `groups/*`, TUS uploads under `/upload/attachments` (token from the chat server), avatar POST forms (signed by the chat server for profile photos, by the storage service for group photos). Nothing else; see sections 8a and 5c |
| `reg.chat.swarm.green` | Caddy, returns 404 | **reserved, deliberately not proxied.** The registration stub accepts one fixed code for every phone number; publishing it would let anyone register any number. The name exists so a misconfigured client fails loudly instead of silently reaching something else |
| `sfu.chat.swarm.green` | Caddy → calling-frontend:8080 (HTTPS); coturn on 3478 (TURN); calling-backend on 10000 (media) | **required for calls** (since 2026-09-29, section 5d). The clients' `sfuUrl` for group calls and call links, and the host name in the TURN URLs the chat server hands out for one-to-one calls |

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

# 3. Generate this deployment's secrets, internal CA, .env, staging-secrets.yml and tus.env
#    (the attachment upload service's credentials, section 8a). Uses the server's own
#    certificate command and zkparams/SwarmZkParams.java, i.e. libsignal.
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
| `genericServerPublicParams` | libsignal `GenericServerPublicParams` for **calling** credentials: the call-link auth credentials that `GET /v1/certificate/auth/group?v101=true` returns next to the group auth credentials, and the create-call-link credentials. This is what Signal-Desktop's `genericServerPublicParams` (Android `GENERIC_SERVER_PUBLIC_PARAMS`) verifies. Same value as `callingServerPublicParams` | public half of `callingZkConfig.serverSecret` (`callingZkConfigV101.serverSecret` in the bundle) |
| `backupServerPublicParams` | libsignal `GenericServerPublicParams` for **backup** credentials (`BackupAuthManager` is built with the chat generic params) | public half of `chatZkConfig.serverSecret` |
| `callingServerPublicParams`, `…PreV101` | calling credentials, current and legacy (`v101=false`). The current one is repeated under the client's name, `genericServerPublicParams` | public halves of `callingZkConfig` / `callingZkConfigPreV101` |
| `serverTrustRoots` | sealed-sender trust roots, base64 public keys. A **list**, so a future rotation can publish the new root beside the old one and clients accept both during the overlap | public half of `unidentifiedDelivery.privateKey`; the server's `unidentifiedDelivery.certificate` is signed by it |
| `registrationCaCertificatePem` | the stack's **internal** CA, used only for the chat server's gRPC hop to the registration stub. **Clients do not need it**; public HTTPS uses Let's Encrypt | `certs/swarm-staging-ca.crt`, also in `.env` as `SWARM_REGISTRATION_CA_PEM` |
| `endpoints.registration` | `null` on purpose: `reg.chat.swarm.green` is not published | — |
| `endpoints.sfu` | `https://sfu.chat.swarm.green` since 2026-09-29 (files generated before say `null`; the clients never read it: they carry the SFU URL in their own `sfuUrl` setting) | the calling service, section 5d |

**Correction, 2026-09-27 (Opus M-H).** Until then this table and `generate-secrets.sh` gave
`genericServerPublicParams` the chat set. Signal's own clients use the chat set only for backups
(`backupServerPublicParams`); `genericServerPublicParams` is the calling set. With the chat set
in that slot the desktop rejected every call-link credential (`Verification failure in zkgroup`
in `CallLinkAuthCredentialResponse.receive`), and since those credentials arrive in the same
response as the group auth credentials, `groupCredentialFetcher` retried forever and no group
could be created. No secret was wrong and none changed: a deployment generated before the fix
corrects its `shared/staging-public-params.json` by copying `callingServerPublicParams` into
`genericServerPublicParams`, and the clients re-import it (desktop:
`node scripts/swarm-import-params.mjs`). Upstream Signal-Desktop ships different values for the
two fields in both of its environments, which is the same split.

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

Status (2026-09-27): steps 1-3 **live** on the staging host since 18:25 UTC (swarm-main
`885ec3aa6`). Tested from outside through `https://chat.swarm.green` with an HTTP/2 client: the
peer's settings carry `enableConnectProtocol = true`; an extended CONNECT to `/v1/websocket/`
answers `200` with `x-signal-timestamp` and echoes a websocket ping; `/v1/websocket/provisioning/`
answers `200` and delivers the provisioning address; gRPC to
`AccountsAnonymous/CheckAccountExistence` answers `grpc-status 3`, `Accounts/ReserveUsernameHash`
without credentials `16`. HTTP/1.1 clients are unchanged (`101` on the websocket upgrade). A packet
capture on the compose bridge shows Caddy's PROXY v2 header with the client's public address in
front of the h2c preface. Step 4 is `swarm-libsignal-0.101.2-swarm.2`. The Live Log in the project
vault ("Opus M-H discovery") has the details.

---

## 5c. Storage service and groups

**Status 2026-09-28 (Opus M6b): IMPLEMENTED and TESTED on the chat host.** Deployed 21:35-21:37
UTC (`648786144` the services, `cd82a1619` the Caddy route and `storageService.uri`; service
`louisinthesubway/swarm-storage-service` `08d0460`, docs `be6bbcf`). Tested 21:56-22:07 UTC
with two desktop instances (swarm-main `e01c737c0`, fresh wallet accounts) against
`chat.swarm.green`: settings sync writes its manifest
(`PUT /v1/storage/ 200`), B set a username and A found it, A created a group with B
(`PUT /v2/groups 200`), B saw it, one message each way in the group, both apps and the Bigtable
emulator restarted, the group and its history were still there and one more message went each way.
Proposed on 2026-09-27 by Opus M-H; the three options he listed are at the end of this section.

**Group photos: IMPLEMENTED and TESTED 2026-09-29 (Opus M6d)**; see "Group photos" below.

**Durable backend, FoundationDB: DEPLOYED 2026-09-29 04:12 UTC (Opus M6c), verified.**
The service keeps groups, group logs and the settings/contacts sync records in the stack's
FoundationDB cluster (`storage.backend: foundationdb`; fork `swarm-main` `316f78484`, PRs #1
and #2 there; its `docs/SWARM-CHANGES.md` section 3), in the directory `swarm-storage-service`.
The Bigtable emulator still runs, untouched since the switch, as the pre-switch copy; the planner
removes it after the owner's test (step 9 of "Switching to FoundationDB").
Tested: the fork's whole suite against a real FoundationDB 7.3.76 (CI and throwaway containers on
the chat host), and the whole switch-over rehearsed in throwaway containers on the chat host with
an image built from these files (details in that subsection).

### What it is

Signal keeps groups and the settings/contacts sync out of the chat server, in a second
application: [`signalapp/storage-service`](https://github.com/signalapp/storage-service)
(AGPL-3.0). SWARM runs a fork,
[`louisinthesubway/swarm-storage-service`](https://github.com/louisinthesubway/swarm-storage-service)
(branch `swarm-main`). Its changes are listed in its `docs/SWARM-CHANGES.md`: the config file
may use `${VAR}` placeholders filled from the environment, the Bigtable client targets an
emulator when `BIGTABLE_EMULATOR_HOST` is set, and a FoundationDB backend (below). **No
cryptography and no protocol code is changed**: group credentials are verified by upstream code
with the chat server's own zkgroup secret.

Upstream's only storage backend is Google Cloud Bigtable. This stack has no Google Cloud account
and talks to no third party at runtime, so the service first ran on a Bigtable **emulator** whose
tables are kept on disk: `cbtemulator` from
[fullstorydev/emulators](https://github.com/fullstorydev/emulators) (MIT), a fork of Google's own
`bttest` emulator with a LevelDB storage layer (`-dir`). Google's emulator
(`gcloud beta emulators bigtable start`) keeps everything in memory and was not used for that
reason. An emulator is a test tool, so the fork has a third change: a **FoundationDB backend**
(`storage.backend: foundationdb`), on the FoundationDB cluster the chat server already uses, in a
Directory-layer directory of its own (`swarm-storage-service`, four subdirectories: `groups`,
`group-logs`, `storage-manifests`, `storage-items`). Same records, same bytes, the same
conditional writes as FoundationDB transactions. `storage.yml` here selects it; the emulator
stays until the migration below has been done and checked.

### The pieces

| Piece | Where | Port | What it does |
|---|---|---|---|
| `foundationdb` | the chat server's FoundationDB 7.3.76 (`docker-compose.yml`, `fdb-data` volume) | `4500`, not published | since the switch: the four data sets, in the directory `swarm-storage-service` |
| `bigtable` | image `swarm-messenger/bigtable:staging`, built by `bigtable/Dockerfile` from pinned sources (cbtemulator `5e109b8`, Google's `cbt` `fe593de`, base images by digest) | `bigtable:8086` (gRPC), not published | before the switch: the four tables, as LevelDB files on the volume `bigtable-data`; after it only the migration's source, removed once the migration is checked |
| `bigtable-bootstrap` | same image, runs `bigtable/bootstrap-tables.sh` | one-shot | creates the tables and their column families with `cbt`; idempotent |
| `storage` | image `swarm-messenger/storage-service:staging`, built by `storage/Dockerfile` from the fork's jar, its runtime jars and the FoundationDB client library `libfdb_c.so` 7.3.76 | `storage:8080` API, `storage:8081` Dropwizard admin, not published | the storage service; reads the cluster file from `fdb-etc` (read-only, like `chat`) |
| Caddy | chat site block, `@storage` | `https://chat.swarm.green/v1/storage`, `/v1/storage/*`, `/v2/groups`, `/v2/groups/*`, **except** `GET /v1/storage/auth` | the public route (HTTP/1.1 to `storage:8080`) |
| Caddy | `cdn.` site block, `@read` | `GET`/`HEAD` `https://cdn.chat.swarm.green/groups/*` | group photos, read anonymously from MinIO (see "Group photos") |
| chat | `staging.yml` `storageService.uri: http://storage:8080` | | calls `DELETE /v1/storage` when an account is deleted; hands out the `/v1/storage` credentials on `GET /v1/storage/auth` |

`GET /v1/storage/auth` stays with the chat server: it is the chat server's own endpoint
(`SecureStorageController`) and issues the credentials the storage service then checks.

### Configuration and secrets

`deploy/staging/storage.yml` is the service's configuration (its own schema,
`StorageServiceConfiguration`, not the chat server's). No secret is written in it: three values
come from `storage.env`, which `storage/make-storage-env.sh` writes once on the host (mode 600,
git-ignored, prints no secret), and the CDN key comes from `.env` through `docker-compose.yml`.

| Key | Value | Why |
|---|---|---|
| `storage.backend` | `foundationdb` | the FoundationDB backend; `bigtable` switches back to the emulator |
| `storage.foundationdb.clusterFile` | `/etc/foundationdb/fdb.cluster` | the `fdb-etc` volume, mounted read-only as for `chat` |
| `storage.foundationdb.directory` | `[swarm-storage-service]` | the service's Directory-layer directory; it touches nothing else in the cluster |
| `bigtable.*` (the six rows below) | | since the switch read only by `migrate-bigtable-to-foundationdb`; removed with the emulator |
| `bigtable.projectId`, `bigtable.instanceId` | `swarm-staging` | labels; the emulator does not check them |
| `bigtable.contactManifestsTableId` | `swarm_storage_manifests` (column family `m`) | settings/contacts sync manifests |
| `bigtable.contactsTableId` | `swarm_storage_contacts` (family `c`) | settings/contacts sync records |
| `bigtable.groupsTableId` | `swarm_storage_groups` (family `g`) | group state |
| `bigtable.groupLogsTableId` | `swarm_storage_group_logs` (family `l`) | group change history |
| `authentication.key` | `SWARM_STORAGE_AUTH_KEY_HEX` | the chat server's `storageService.userAuthenticationTokenSharedSecret`, the same 32 bytes written as hex (the chat server reads it as base64, this service as hex) |
| `zkConfig.serverSecret` | `SWARM_STORAGE_ZK_SERVER_SECRET` | the chat server's `groupsZkConfig.serverSecret`, verbatim. The chat server issues group auth and profile key credentials with it and checks group send endorsements; this service checks the credentials and issues the endorsements |
| `group.externalServiceSecret` | `SWARM_STORAGE_GROUP_CALL_SECRET_HEX` | 32 fresh random bytes, this service's own (group-call tokens) |
| `group.maxGroupSize` | `1001` | = `groupsv2.groupSizeHardLimit` in `staging.yml` |
| `group.maxGroupTitleLengthBytes` / `...DescriptionLengthBytes` | `1024` / `8192` | upstream's test-suite values |
| `cdn.*` | `SWARM_CDN_ACCESS_KEY`, `SWARM_CDN_SECRET_KEY`, `SWARM_CDN_BUCKET`, `SWARM_AWS_REGION` from `.env` | group avatars: an S3 POST policy for `groups/<group id>/<random>`, signed with the CDN0 key |
| `openTelemetry.enabled` | `false` | nothing is exported |
| `BIGTABLE_EMULATOR_HOST` (environment, not a key) | `bigtable:8086` | set in `docker-compose.yml`; the migration's source |
| `JAVA_TOOL_OPTIONS` | `-Xmx1g` | upstream's image asks for 8 GiB |

A wrong `authentication.key` makes every `/v1/storage` call answer 401; a wrong
`zkConfig.serverSecret` makes every group call answer 401. After rotating either secret in
`staging-secrets.yml`: delete `storage.env`, run `./storage/make-storage-env.sh` again and
`docker compose up -d storage`.

### First install, and updating the service

On the chat host, JDK 25 or newer on the PATH (the host has 26):

```sh
git clone https://github.com/louisinthesubway/swarm-storage-service /opt/swarm/swarm-storage-service
(cd /opt/swarm/swarm-storage-service && ./mvnw -B -DskipTests package)   # about a minute

cd /opt/swarm/swarm-messenger-server/deploy/staging
./storage/make-storage-env.sh                     # once; leaves an existing storage.env alone
./storage/prepare-image.sh /opt/swarm/swarm-storage-service   # jar + 181 runtime jars + libfdb_c.so -> storage/build/
docker compose build bigtable storage
docker compose up -d storage                      # needs foundationdb (+ init) healthy; still starts bigtable
```

Then, once: `storageService.uri: http://storage:8080` in `staging.yml` and
`docker compose restart chat`; the `@storage` route in `caddy/Caddyfile`, validated in a one-off
container and reloaded:

```sh
docker compose --profile edge run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile
docker compose --profile edge exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Updating the service later touches only `storage`:

```sh
(cd /opt/swarm/swarm-storage-service && git pull --ff-only && ./mvnw -B -DskipTests package)
./storage/prepare-image.sh /opt/swarm/swarm-storage-service
docker compose build storage && docker compose up -d storage
```

### Checking it

```sh
docker compose ps bigtable storage            # both "healthy"
docker compose logs bigtable-bootstrap        # "+ <table>" the first time, "= <table>" after
curl -s -o /dev/null -w '%{http_code}\n' https://chat.swarm.green/v1/storage/manifest   # 401
curl -s -o /dev/null -w '%{http_code}\n' https://chat.swarm.green/v2/groups             # 401
# row counts, never contents:
docker run --rm --network swarm-staging -e BIGTABLE_EMULATOR_HOST=bigtable:8086 \
  --entrypoint cbt swarm-messenger/bigtable:staging \
  -project swarm-staging -instance swarm-staging count swarm_storage_groups
```

`404` instead of `401` means the Caddy route is missing. The storage container's health check
calls `/_ready`, which reads one row (FoundationDB: one key-value) from each of its four tables on
its first calls, so "healthy" also means it reaches its data. On FoundationDB the start log says
`FoundationDB storage backend: cluster file /etc/foundationdb/fdb.cluster, directory
[swarm-storage-service], client 7.3.76 (API 730)`. While the emulator still exists, a dry run of the
migration prints the record counts on both sides:
`docker compose run --rm --no-deps storage migrate-bigtable-to-foundationdb /config/storage.yml`.
It never writes to the emulator; on FoundationDB see the note under step 3 below.

In the desktop's log a working setup looks like this: `PUT (REST) https://chat.swarm.green/v2/groups
200 Success`, `GET (REST) .../v2/groups/logs/0?... 200 Success`, `[groupSendEndorsements] ...
Received endorsements`, `PUT (REST) https://chat.swarm.green/v1/storage/ 200 Success`,
`[storage] upload(N): upload complete`. A brand-new account's first `GET /v1/storage/manifest`
answers **404** and the app logs `sync(0): missing`: correct, it writes the first manifest right
after.

### What persists

- On FoundationDB (since 2026-09-29 04:12 UTC): the records are in the chat server's cluster, volume
  `fdb-data`, with FoundationDB's own durability (storage engine `ssd`, every commit on disk
  before it is acknowledged; redundancy `single`, one process on one disk, as for the chat
  server's messages). They survive restarts of `storage` and `foundationdb`
  (rehearsed 2026-09-29 in throwaway containers: the data read back after a service restart).
  The nightly snapshot contains them in `fdb-data.tgz`, copied with `foundationdb` stopped
  (section 12).
- On the emulator (before the switch): the tables are LevelDB files on the Docker volume
  `swarm-messenger-staging_bigtable-data`. They survive restarts of `bigtable` and `storage`, and
  `docker compose down` (not `down -v`). Tested 2026-09-28: row counts identical before and after
  `docker compose restart bigtable`, and both desktops read the group back afterwards.
- The nightly snapshot (section 12) includes `bigtable-data.tgz` since 2026-09-28 (the emulator
  is stopped for about a second while it is copied).
- `storage` itself keeps nothing. `storage.env` holds the three secrets (section 9).
- Caveat: an emulator is a test tool. One process, no replication, and LevelDB does not flush
  every write to disk, so a crash of the host can lose the last few seconds. Fine for staging;
  see "Towards something durable" below.

### Reset: delete every group and every synced setting on the server

```sh
docker compose stop storage bigtable
docker compose rm -f storage bigtable bigtable-bootstrap
docker volume rm swarm-messenger-staging_bigtable-data
docker compose up -d storage                      # empty tables again
```

Clients keep their local copies: every existing group becomes unusable (changes and endorsement
refreshes fail) and has to be created again; settings sync uploads a fresh manifest by itself.

That is the emulator. On FoundationDB, never clear key ranges with `fdbcli`: the cluster also
holds the chat server's messages. To start empty, point `storage.foundationdb.directory` at a new
path (for example `[swarm-storage-service-2]`) and `docker compose up -d storage`; the old
directory stays in the cluster, untouched, until someone removes it with the Directory layer
(no command for that yet).

### Switching to FoundationDB

**Status: EXECUTED on the live stack 2026-09-29 (Opus M6c)**, after the first nightly snapshot
(04:10 UTC, whose `bigtable-data.tgz` is the pre-switch copy). Image
`swarm-messenger/storage-service:staging` = `sha256:16f8aa7b0184...` (fork `316f78484`; the old
image stays tagged `pre-fdb-be6bbcf`). Step 3, dry run against the live cluster, read-only:
groups 1, group-logs 2, storage-manifests 2, storage-items 11 rows, all "would copy"; the
cluster had no Directory-layer keys before or after. Step 4 stopped storage at 04:12:10.9;
step 5 `--apply` copied 1 / 2 / 2 / 11 (target after the same), a second `--apply` found all
identical; step 6 healthy at 04:12:43.6 on FoundationDB. **Groups and settings sync were
unavailable 04:12:10.9-04:12:43.6 UTC (about 33 s); chat was not affected.** Step 7 with the
hidden test instances m6b-a/m6b-b: from outside `/v2/groups` and `/v1/storage/manifest` 401 with
`X-Signal-Timestamp`; both apps read their manifests (`GET .../manifest/version/7` and `/5` 204),
the group and its log (`GET /v2/groups/logs/1?includeFirstState=true... 200`, `GET
/v2/groups/token 200`) with its history and photo, one message each way (delivered), two group
changes (`PATCH /v2/groups 200`, description set and cleared, B followed), a settings change
(pin, unpin: `PUT /v1/storage/ 200`, manifest 7 -> 8). Screens
`D:/swarm-work/smoke/messenger-m6c-01..05-*.png` on the M6c workstation. From step 6 on the
emulator is stale: **do not run `--apply` again** (it would copy back what clients have deleted
since, e.g. a replaced settings record); a dry run now reports the newer FoundationDB records
as conflicts, which is expected.

Before that, rehearsed 2026-09-29 (Opus M6c) in throwaway
containers on the chat host (own Docker network, nothing published, all removed afterwards): an
image built with this `storage/Dockerfile` and `storage/prepare-image.sh` from the fork branch,
the stack's own emulator image as the source. The service on the emulator wrote two 120 KB
manifests and ten items through the HTTP API; the dry run reported the 2 manifests and 10 items
it would copy and wrote nothing; `--apply` copied them; a second `--apply` found them identical;
after upstream's own `GroupsManager` had written two groups (1001 and 4 members, versions 0 to 2)
into the emulator, a third `--apply` copied the 2 groups and their 6 log entries and left the rest
alone; both groups read identically through both backends; the service started on FoundationDB
(`/_ready` 200 after 5 s, this compose file's health check passing), read the settings back byte
for byte, accepted the next manifest version, refused a stale one with 409, and still had
everything after a restart.

A first step 1 on 2026-09-29 03:03 UTC built `3f3b61b23` (`sha256:a379a3dc2c7a...`, unused, and
the old image got its `pre-fdb-be6bbcf` tag then); its dry run against the live emulator, with a
throwaway FoundationDB as the target, reported the same counts as step 3 later did.

Groups and settings sync are unavailable from step 4 to step 6 (a minute or two); chat and
messages are not affected.

1. **Build** the fork at the reviewed commit and stage the image; this does not touch the running
   container:

   ```sh
   cd /opt/swarm/swarm-storage-service && git pull --ff-only && git log --oneline -1   # 3f3b61b23 or a later reviewed commit
   ./mvnw -B -DskipTests package                    # downloads libfdb_c.so 7.3.76, checks its SHA-256
   cd /opt/swarm/swarm-messenger-server/deploy/staging
   ./storage/prepare-image.sh /opt/swarm/swarm-storage-service   # prints the libfdb_c.so sha256: af099848...
   docker compose build storage
   ```

2. **Bring the host's `docker-compose.yml`, `storage.yml` and `storage/` to this branch's
   version** (the host's working tree carries local changes: check `git status` and `git diff`
   for these files first). Nothing restarts yet.
3. **Dry run** while the old service still serves (it never writes to the emulator):
   `docker compose run --rm --no-deps storage migrate-bigtable-to-foundationdb /config/storage.yml`.
   Expect `target before` 0 everywhere, `would copy` equal to `source rows`, no conflicts, no
   unreadable rows, and `OK:` at the end. On FoundationDB: from fork
   [PR #2](https://github.com/louisinthesubway/swarm-storage-service/pull/2) on, the dry run opens
   its directory read-only and writes nothing; at `3f3b61b23` it opens it with `createOrOpen`, so
   the first dry run creates the
   service's empty directory in the chat server's cluster (the service creates it at start anyway,
   and nothing else in the cluster is touched). The live cluster had no Directory-layer data at all
   on 2026-09-29 (`fdbcli --exec 'getrangekeys \xfe \xff 10'` lists nothing).
4. **Stop** the service: `docker compose stop storage`.
5. **Migrate**:
   `docker compose run --rm --no-deps storage migrate-bigtable-to-foundationdb --apply /config/storage.yml`.
   Expect `copied` = `source rows` = `target after` and `OK:`. Run the same command once more:
   everything `identical`, nothing copied. The command never writes to the emulator, never
   overwrites a record that differs in FoundationDB (it counts it as a conflict, prints
   `ATTENTION` and exits non-zero), and prints counts only, never identifiers or contents.
6. **Start on FoundationDB**: `docker compose up -d storage`. Check `docker compose ps storage`
   (healthy) and the start log line quoted under "Checking it".
7. **Verify** with the owner's desktop: an existing group opens, a message goes both ways, a
   group change (title) goes through (`PATCH /v2/groups 200`), settings sync uploads
   (`PUT /v1/storage/ 200`); the two `401` checks under "Checking it".
8. **Rollback**, if step 7 fails: `storage.backend: bigtable` in `storage.yml`, then
   `docker compose up -d storage`. The emulator still holds everything up to step 4; whatever was
   written on FoundationDB after step 6 is not copied back.
9. **Later**, once the planner has checked it: take a last snapshot of `bigtable-data`, then
   remove the `bigtable` block of `storage.yml`, the `bigtable` and `bigtable-bootstrap` services,
   `BIGTABLE_EMULATOR_HOST` and the `bigtable-bootstrap` dependency of `storage` from
   `docker-compose.yml`, the Bigtable part of `backup-nightly.sh` and the volume. Not part of this
   change.

### Group photos

**Status 2026-09-29 (Opus M6d): IMPLEMENTED and TESTED on the chat host.** Deployed 01:09-01:10
UTC (swarm-main `2d8aa9f6f`). Until then a group photo could be uploaded but nobody could
read it: the edge published reads only for `/attachments/*` and `/profiles/*`, and the bucket's
anonymous policy covered only those two prefixes.

A group photo takes the same CDN0 path as a profile photo (section 8a), except that the storage
service, not the chat server, signs the upload form:

1. A member allowed to change the group's attributes asks for a form,
   `GET https://chat.swarm.green/v2/groups/avatar/form` (group auth). The storage service answers
   with an S3 POST policy for `groups/<group id>/<random>` in the bucket `swarm-cdn`: the group id
   in base64url (43 characters), `<random>` the base64url of 16 random bytes (22 characters), 1 byte
   to 3 MiB, signed with the CDN key (`cdn.*` in `storage.yml`).
2. The client encrypts the photo with the group's key (a zkgroup `GroupAttributeBlob`, like the
   group title) and `POST`s it as `multipart/form-data` to `https://cdn.chat.swarm.green/`, where
   MinIO checks the policy and its signature (`204`). Then it records the object name in the group
   with `PATCH /v2/groups`; the storage service accepts only `groups/<this group's id>/<16 bytes>`.
3. The other members apply the change, download
   `https://cdn.chat.swarm.green/groups/<group id>/<random>` without credentials and decrypt it with
   the group's key. The desktop percent-encodes the slashes (`/groups%2F<id>%2F<random>`,
   `encodeURIComponent` in `getGroupAvatar`); Caddy's `path` matcher compares the decoded path and
   MinIO decodes the object name, so both spellings reach the same object.

What is served anonymously: `s3:GetObject` on `swarm-cdn/groups/*`, the bucket policy that
`minio/bootstrap-buckets.sh` sets, reachable only with `GET` or `HEAD` on `/groups/*` (the `@read`
matcher of the `cdn.` block in `caddy/Caddyfile`). No listing, no other method, no query string.
That is acceptable for the same reason as for attachments and profile photos: fetching an object
needs its name, whose last part alone is 128 random bits (the middle part is the group's 256-bit
identifier, which only its members and the storage service know), and what comes back is
ciphertext that only a member can decrypt. The CDN key's own policy (`swarm-cdn-rw`) already lets
it write anywhere in `swarm-cdn`, so uploads needed no change.

Applying it to a running stack, as on 2026-09-29: `caddy/Caddyfile` replaced in place, validated
and reloaded (commands in "First install, and updating the service" above), then

```sh
docker compose up --no-deps minio-bootstrap   # sets the new anonymous policy; the rest of the
                                              # script finds everything in place and re-uploads the
                                              # two swarm-config objects unchanged
docker compose run --rm --no-deps -T --entrypoint /bin/sh minio-bootstrap -c \
  'mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc anonymous get-json local/swarm-cdn'
# ..."Resource":["arn:aws:s3:::swarm-cdn/attachments/*","arn:aws:s3:::swarm-cdn/groups/*","arn:aws:s3:::swarm-cdn/profiles/*"]...
```

Checks from anywhere:

```sh
curl -sI https://cdn.chat.swarm.green/groups/<group id>/<random>   # 200, Content-Length of the object
curl -sI https://cdn.chat.swarm.green/groups/<made-up>/<made-up>   # 404 NoSuchKey, Server: MinIO
```

A made-up name answers 404 from MinIO because anonymous `GetObject` is allowed on the prefix. A 403
with `Server: MinIO` means the bucket policy lacks `groups/*`; a 404 with `Server: Caddy` means the
running Caddy configuration lacks `/groups/*`.

Tested 2026-09-29, 01:13-01:17 UTC, with the two hidden desktop instances of the groups test
above (swarm-main `e01c737c0`, the group they share): A set a 256x256 PNG as the group photo in
*Edit group*; A's log shows `GET /v2/groups/avatar/form 200`,
`POST https://cdn.chat.swarm.green/ 204` and `PATCH /v2/groups 200`. B applied the change (group
version 0 to 1), downloaded the photo
(`GET (REST) https://cdn.chat.swarm.green/[REDACTED]... 200 Success`; the edge logged
`GET /groups%2F... 200`, 16,563 bytes) and showed it in the chat list, the conversation header and
the group details, and still after a restart. From outside, that object answered 200 with
`Content-Length: 16563` under both spellings, made-up names under `/groups/` 404 from MinIO, an
existing `/profiles/` object still 200, and paths outside the three prefixes 404 from Caddy.

### Known gaps

- **One host name for two services.** The desktop treats a 401 from `chat.swarm.green` as "we
  might be unlinked" and reconnects its websocket, so a storage-service 401 (an expired
  credential) causes one harmless reconnect. Upstream Signal uses a separate storage host.
- **Group calls** work since 2026-09-29: the calling frontend checks the token from
  `GET /v2/groups/token` with this service's `group.externalServiceSecret` (section 5d).
- `/v1/groups` (groups v1) is not routed; no current client uses it.
- **Nightly snapshot on FoundationDB: consistent since 2026-09-29.** The first nightly run
  (04:10 UTC) tarred `fdb-data` while `fdbserver` ran, and tar reported `file changed as we read
  it`: FoundationDB keeps writing its own files even with no client. `backup-nightly.sh` now
  stops `chat` and `storage`, then `foundationdb` for the `fdb-data` tar only, and starts
  everything again (FoundationDB first, waiting until the database is available) whatever
  happens; see section 12. Groups and settings sync pause for the same minute as chat.
- **Size ceiling on FoundationDB.** One record (a group state, a log entry, a manifest, an item)
  can be at most about 9.9 MB, FoundationDB's 10 MB transaction limit; the largest group the
  validators allow is about 0.96 MB and its largest log entry about 1.7 MB (fork's
  `docs/SWARM-CHANGES.md`, section 3.6). Bigtable would take up to 100 MB per cell.

### What the desktop calls on `storageUrl`

From `STORAGE_CALLS` in `ts/textsecure/WebAPI.preload.ts`:

| Path | Method | What for | Authentication |
|---|---|---|---|
| `v2/groups` | `PUT` / `GET` / `PATCH` | create / fetch / change a group | group auth: `Basic` with the group public params and a zkgroup auth-credential presentation, verified with the groups `ServerSecretParams` |
| `v2/groups/logs/<from-version>` | `GET` | group change history | group auth |
| `v2/groups/joined_at_version` | `GET` | where this member's history starts | group auth |
| `v2/groups/join/<link-password>` | `GET` | preview before joining by link | group auth |
| `v2/groups/token` | `GET` | external credential for group calls | group auth |
| `v2/groups/avatar/form` | `GET` | an S3 POST policy for a group avatar upload | group auth |
| `v1/storage/manifest` (and `/version/<v>`) | `GET` | settings/contacts manifest | `Basic` user/password the chat server issues on `GET /v1/storage/auth` (HMAC with `storageService.userAuthenticationTokenSharedSecret`) |
| `v1/storage/read` | `PUT` | read records | same |
| `v1/storage/` | `PUT` | write manifest + records | same |

Every response from the storage service carries `X-Signal-Timestamp`. The desktop logs an error
for a storage response without it and ignores such a response if it is a 403 (a front end that
is not the service answered).

### Towards something durable (from the 2026-09-27 proposal)

1. **A Bigtable emulator** - what runs now, with the on-disk variant.
2. **Cloud Bigtable** - durable, but a Google Cloud account and a runtime dependency on a third
   party, which this stack avoids everywhere else.
3. **A SWARM fork of `storage-service` with its own table backend** (FoundationDB, already in the
   stack, or SQL) implementing the four tables with the same conditional writes (manifest version
   compare-and-set, group version checks, group-log range reads). The only durable, self-hosted
   option, and the most work. **DEPLOYED 2026-09-29 04:12 UTC (Opus M6c) on FoundationDB**: see
   the status at the top of this section and "Switching to FoundationDB".

---

## 5d. Calls: the TURN relay (one-to-one) and the calling service (group calls, call links)

**Status 2026-09-29 (Opus M7): IMPLEMENTED and TESTED on the chat host.** Deployed 02:06-02:16 UTC.
Tested 02:21-02:30 UTC with the two hidden desktop instances of the groups test (swarm-main
`e01c737c0`, Chromium's synthetic camera, microphones muted): a one-to-one voice call forced through
the relay, a group call, and a call link with admin approval. What exactly was seen is at the end
of this section. Nothing in the chat server, the storage service or the clients changed: this is
deployment and configuration, plus one small change in the calling service's fork (below).

### What the clients do

**One-to-one calls.** The call itself is set up with ordinary end-to-end encrypted messages through
the chat server (that always worked). For the media, each client asks the chat server for relays,
`GET /v2/calling/relays` (authenticated), and gets:

```json
{"relays": [{"username": "<expiry>:<random>", "password": "<HMAC>", "ttl": 43200,
  "urls": ["turn:sfu.chat.swarm.green:3478"],
  "urlsWithIps": ["turn:64.95.11.180", "turn:64.95.11.180:3478?transport=tcp"],
  "hostname": "sfu.chat.swarm.green"}]}
```

`turn:<ip>` without a port is UDP on 3478 (the default port of `turn:` URLs), the second is TCP on
3478; both are coturn. The two clients connect directly when their networks let them and through
the relay otherwise. The desktop uses the relay **only** (it hides its IP address) for calls with
someone who is not a contact yet and, for every call, with *Settings > Privacy > Advanced > Always
relay calls*.

This Signal-Server version can get TURN credentials from exactly one kind of service, Cloudflare's
TURN API: `CloudflareTurnCredentialsManager` POSTs `{"ttl": <seconds>}` with
`Authorization: Bearer <turn.cloudflare.apiToken>` to `turn.cloudflare.endpoint`, **requires HTTP
201**, reads `{"iceServers": {"username", "credential"}}` and hands clients its own configured URLs.
The endpoint is configurable, so `turn-credentials` answers in exactly that shape with coturn's
TURN REST credentials: username `<expiry, unix seconds>:<16 random characters>`, credential
`base64(HMAC-SHA1(static-auth-secret, username))`, which coturn recomputes and refuses after the
expiry. No server code changed and nothing is sent to Cloudflare.

**Group calls.** The clients have the calling service in their own configuration
(`sfuUrl: https://sfu.chat.swarm.green/`). A member asks the storage service for a group-call token,
`GET /v2/groups/token` (section 5c): `2:<sha256 of the member's encrypted id>:<group id>:<time>:<0|1>:<first
10 bytes of an HMAC-SHA256>`, keyed with the storage service's `group.externalServiceSecret`. With it
the client looks at (`GET`) and joins (`PUT`) `/v2/conference/participants` on the calling
**frontend**, which checks the HMAC with the same key, keeps a call record in DynamoDB and puts the
call on the calling **backend**. The media then goes straight between the client and the backend,
`64.95.11.180:10000` (UDP, or TCP), not through Caddy. Group media is end-to-end encrypted by the
clients (frame encryption); the backend forwards what it cannot read.

**Call links.** A client gets a create-call-link credential from the chat server
(`POST /v1/call-link/create-auth`, issued with `callingZkConfig`) and presents it to the frontend
(`PUT /v1/call-link`); later readers present call-link auth credentials that the chat server hands
out with the group credentials. The frontend verifies both with the calling zkgroup **secret**
(`GenericServerSecretParams`), which is why it holds a copy of `callingZkConfigV101.serverSecret`.

### The pieces

| Piece | Image / source | Where | What it does |
|---|---|---|---|
| `coturn` | `coturn/coturn:4.18.0-trixie` by digest | host network; `64.95.11.180:3478` UDP+TCP, relays on `49160-49259/udp` | the TURN relay. `coturn/turnserver.conf` |
| `turn-credentials` | `swarm-messenger/turn-credentials:staging`, `turn-credentials/Dockerfile` (the pinned `node:22-alpine` of `tus`, standard library only) | `turn-credentials:8080`, compose network only | `POST /credentials/generate`: 201 with credentials for the right Bearer token, 401 otherwise, 405 for other methods, ttl capped at 48 h. `turn-credentials/server.mjs`, tests in `turn-credentials/test/` |
| `calling-bootstrap` | `amazon/aws-cli:2.31.11` (as `dynamodb-bootstrap`) | one-shot | creates the frontend's table `swarm_calling_rooms` in the stack's DynamoDB Local (upstream's schema, index `region-index`, TTL on `deleteAt`). `sfu/bootstrap-calling-table.sh` |
| `calling-backend` | `swarm-messenger/calling-backend:staging`, `sfu/Dockerfile` target `backend` | `10000/udp`+`tcp` published; signaling `10.77.0.31:8080` | forwards group-call media (SFU) |
| `calling-frontend` | `swarm-messenger/calling-frontend:staging`, target `frontend` | `calling-frontend:8080` (client API), `:8100` (internal API for the backend) | authenticates clients, call records and call links, assigns calls to the backend |
| Caddy | `sfu.chat.swarm.green` site block | `https://sfu.chat.swarm.green` | publishes `/v2/conference/participants` and `/v1/call-link` only; everything else 404. Passes and logs no client address, logs no header |
| chat | `staging.yml` `turn.cloudflare.endpoint: http://turn-credentials:8080/credentials/generate` | | asks `turn-credentials` for credentials on `GET /v2/calling/relays` |

**Source of the calling service.** [`louisinthesubway/swarm-calling-service`](https://github.com/louisinthesubway/swarm-calling-service),
a GitHub fork of [`signalapp/Signal-Calling-Service`](https://github.com/signalapp/Signal-Calling-Service)
(AGPL-3.0-only), branch `swarm-main` at `61e5d4085c04` = upstream `56da39e` (v141) plus one change
recorded in its `docs/SWARM-CHANGES.md`: the frontend may read its two secrets from the environment
(`CALLING_AUTH_KEY`, `CALLING_ZKPARAMS`) instead of its command line, where every local user of the
host can read them in `/proc/<pid>/cmdline` and any `ps` listing shows them. No cryptography,
protocol or API code differs. `sfu/Dockerfile` fetches exactly that commit (and checks it), builds
both programs with `cargo build --release --locked` in the official `rust:1.97.1-trixie` image (the
version of the source's `rust-toolchain` file) and puts each into `debian:trixie-slim`, both by
digest. Build on this host: about 6.5 minutes (cargo 5 min 46 s with 4 of the 6 CPUs); the second
target reuses the first one's build stage. Each image records its source commit in
`/usr/local/share/calling-service/SOURCE_COMMIT`.

### Configuration and secrets

| Key | Where | Value | Why |
|---|---|---|---|
| `turn.cloudflare.apiToken` | `staging-secrets.yml` | 32 random bytes, hex (was the placeholder `unset` until 2026-09-29) | the chat server's Bearer token toward `turn-credentials` |
| `SWARM_TURN_API_TOKEN` | `turn.env` | = `turn.cloudflare.apiToken` | the only token `turn-credentials` accepts |
| `SWARM_TURN_STATIC_AUTH_SECRET` | `turn.env` | 32 random bytes, hex | coturn's `static-auth-secret` and the HMAC key of `turn-credentials`. coturn gets it through its environment: the container writes a copy of `turnserver.conf` plus this line into its tmpfs (mode 700, owned by the image's user) and starts from that copy, so it is never on a command line |
| `CALLING_AUTH_KEY` | `sfu.env` | = `SWARM_STORAGE_GROUP_CALL_SECRET_HEX` in `storage.env` (hex, 32 bytes) | checks group-call tokens (the frontend's `--authentication-key`, hex) |
| `CALLING_ZKPARAMS` | `sfu.env` | = `callingZkConfigV101.serverSecret` in `staging-secrets.yml` (base64 `GenericServerSecretParams`) | verifies call-link credentials (`--zkparams`). The frontend refuses to start without it. Not the public params: verifying a presentation needs the secret half |
| `turn.cloudflare.requestedCredentialTtl` / `clientCredentialTtl` | `staging.yml` | `PT24H` / `PT12H` | credentials are minted for 24 h; clients cache the answer for 12 h |
| `turn.cloudflare.urls`, `urlsWithIps`, `hostname` | `staging.yml` | unchanged since 2026-09-26 | see the answer above; `hostname` is resolved by the chat server for every request |

`turn.env` is written by `coturn/make-turn-env.sh` and `sfu.env` by `sfu/make-sfu-env.sh`, once, mode
600, git-ignored; neither prints a secret. `make-turn-env.sh` also replaces the placeholder
`turn.cloudflare.apiToken: unset` in `staging-secrets.yml` **in place** (same inode and mode: that
single file is bind-mounted into `chat`), and `generate-secrets.sh` writes a real token on a new host.

coturn (`coturn/turnserver.conf`): listens only on `64.95.11.180` (`listening-ip`, `relay-ip`,
`external-ip`; another host: change those three), port 3478 UDP and TCP, **no TLS listener**
(`turns:`/5349) for now, RFC 5780 off, relay ports `49160-49259` (100 = `total-quota`; a desktop in a
call holds one allocation per TURN URL and network interface, about 3 to 9, so this carries 5 to 15
relayed one-to-one calls at once), `user-quota=16`, `max-bps=375000` (3 Mbit/s per allocation and
direction), `bps-capacity=12500000` (100 Mbit/s for all relays), `use-auth-secret`,
`realm=sfu.chat.swarm.green`, `fingerprint`, `no-tcp-relay`, `no-multicast-peers`,
`no-software-attribute`, logs to stdout (errors only at this verbosity: no per-call lines).

calling-backend: `--binding-ip=0.0.0.0 --ice-candidate-ip=64.95.11.180 --ice-candidate-port=10000
--ice-candidate-port-tcp=10000 --signaling-ip=10.77.0.31 --signaling-port=8080
--max-clients-per-call=16 --diagnostics-interval-secs=30` and the frontend's internal API for
call-link approvals and removing ended calls. calling-frontend: `--region=swarm-staging
--version=141 --max-clients-per-call=16 --cleanup-interval-ms=30000
--regional-url-template=https://sfu.chat.swarm.green --calling-server-url=http://calling-backend:8080
--storage-table=swarm_calling_rooms --storage-endpoint=http://dynamodb:8000 --internal-api-port=8100`.
`--storage-endpoint` is upstream's switch for a local DynamoDB (fixed dummy keys); DynamoDB Local runs
with `-sharedDb`, so the table is the same one `calling-bootstrap` created. No send-endorsement
secret (`--endorsement-secret`) is configured.

### Security

- **The relay cannot reach inside.** `denied-peer-ip` refuses `0.0.0.0/8`, `10.0.0.0/8` (the
  compose network `10.77.0.0/24` with every service of this stack), `100.64.0.0/10`, `127.0.0.0/8`
  (the chat server's loopback ports, the resolver, other loopback services), `169.254.0.0/16`
  (link-local, cloud metadata), `172.16.0.0/12` (`docker0` and swarm-pay's network),
  `192.0.0.0/24`, `192.0.2.0/24`, `192.88.99.0/24`, `192.168.0.0/16`, `198.18.0.0/15`,
  `198.51.100.0/24`, `203.0.113.0/24`, `224.0.0.0/4` and `240.0.0.0/4`, written as ranges.
  `no-tcp-relay`: a client can never open a TCP connection from this host. Tested: relaying to
  `10.77.0.1`, `127.0.0.1`, `172.17.0.1` and `169.254.169.254` is refused with 403.
- **IPv4 only, on purpose.** The relay address is IPv4 and a TURN server relays only to peers of
  that family. IPv6 ranges are left out because coturn 4.18 skips the lower bound of a range that
  starts at `::` and sorts every IPv4 address below every IPv6 one: `denied-peer-ip=::-::1` refused
  **every** IPv4 peer, the public test peer included (seen on 2026-09-29, fixed before any client
  used the relay). If the host gets IPv6, add IPv6 ranges together with an IPv6 `relay-ip`, none
  starting at `::`, and test that a public IPv4 peer is still allowed.
- **The host's own public address stays an allowed peer**, because two clients that both use the
  relay reach each other through it (relay to relay). Consequence: a UDP service listening on
  `64.95.11.180` is reachable through the relay even where UFW would block it from outside. Today
  that is Caddy's 443/udp, coturn, the relay ports and the backend's 10000/udp, all public anyway;
  keep it that way.
- Credentials reach a client only through the authenticated, rate-limited `GET /v2/calling/relays`;
  `turn-credentials` answers only the chat server's token and is not published.
- No secret is on a command line or in a log: coturn and the frontend read theirs from the
  environment, `turn-credentials` logs status, ttl and expiry only, the `sfu.` access log drops the
  client address and all headers (the `Authorization` header carries the group-call token).
- Scanners probed `sfu.chat.swarm.green/.env*` within seconds of the certificate appearing in the
  certificate transparency logs; they get Caddy's 404.

### First install, and applying it to a running stack (as on 2026-09-29)

```sh
cd /opt/swarm/swarm-messenger-server/deploy/staging
./coturn/make-turn-env.sh                         # turn.env; replaces an `unset` apiToken in place
./sfu/make-sfu-env.sh                             # sfu.env (needs storage.env, section 5c)
docker compose build turn-credentials calling-backend calling-frontend
docker compose up -d --no-deps turn-credentials coturn
./ufw-calls.sh                                    # then: ufw status numbered
# staging.yml: turn.cloudflare.endpoint -> http://turn-credentials:8080/credentials/generate
docker compose restart chat                       # reads the endpoint and the new apiToken
docker compose up --no-deps calling-bootstrap     # "+ swarm_calling_rooms", "+ ... TTL on deleteAt"
docker compose up -d --no-deps calling-backend    # wait for (healthy), then
docker compose up -d --no-deps calling-frontend
# caddy/Caddyfile: the sfu.chat.swarm.green block; validate and reload (section 5c), then Caddy
# gets the certificate by itself (tls-alpn-01).
```

Updating the calling service: set `CALLING_COMMIT` in `sfu/Dockerfile` to the new `swarm-main`
commit of the fork, `docker compose build calling-backend calling-frontend`, then
`docker compose up -d --no-deps calling-backend calling-frontend` (group calls in progress drop).

### Checking it

```sh
docker compose ps coturn turn-credentials calling-backend calling-frontend   # all (healthy)
ss -tulnp | grep turnserver                 # 64.95.11.180:3478 only (no 3479, 5349, 5766)
curl -sI https://sfu.chat.swarm.green/v2/conference/participants     # 401 (frontend, no token)
curl -s -o /dev/null -w '%{http_code}\n' https://chat.swarm.green/v2/calling/relays   # 401
docker compose logs --since 10m turn-credentials   # "POST /credentials/generate 201 ttl=86400 expires=..."
docker compose logs --since 10m calling-backend    # "call_id: ... adding demux_id: ...", diagnostics every 30 s
```

A relay test with a real credential, from the host (the minted credential never printed):

```sh
umask 077
docker compose exec -T turn-credentials node -e 'fetch("http://127.0.0.1:8080/credentials/generate",
  {method:"POST",headers:{Authorization:"Bearer "+process.env.SWARM_TURN_API_TOKEN},body:"{\"ttl\":300}"})
  .then(r=>r.json()).then(j=>process.stdout.write(JSON.stringify(j.iceServers)))' > /root/cred.json
TU=$(python3 -c 'import json; print(json.load(open("/root/cred.json"))["username"])')
TP=$(python3 -c 'import json; print(json.load(open("/root/cred.json"))["credential"])')
IMG=$(docker compose config --images | grep coturn)
docker run -d --rm --name turn-peer --network host --entrypoint turnutils_peer "$IMG" -L 64.95.11.180 -p 3480
docker run --rm --network host --entrypoint turnutils_uclient "$IMG" -u "$TU" -w "$TP" \
  -e 64.95.11.180 -r 3480 -n 20 -m 1 -l 120 64.95.11.180 | grep -E 'tot_recv_msgs|lost packets'
# add -t for TCP to the server; expect "tot_send_msgs=40, tot_recv_msgs=40" and "Total lost packets 0"
docker rm -f turn-peer; rm /root/cred.json; unset TU TP
```

With `-e 10.77.0.1` (or any denied address) the same command must end in `channel bind: error 403`.
From outside, a STUN Binding request to `64.95.11.180:3478` over UDP or TCP answers with a Success
Response and an unauthenticated Allocate with 401, realm `sfu.chat.swarm.green`.

In a desktop log a working one-to-one call shows `GET (WS) https://chat.swarm.green/v2/calling/relays
200 Success`, RingRTC's `proceed(): ... hideIp: ...` followed by the three `server: turn:...` lines,
local candidates `typ relay` on ports 49160-49259, and `ice_network_route_change(NetworkRoute {
... local_relayed: true ... })` when it went through the relay; a group call shows
`GET (REST) https://chat.swarm.green/v2/groups/token 200`, `PUT (REST)
https://sfu.chat.swarm.green/v2/conference/participants 200 Success` and
`LocalDeviceState (Connected, Joined)`. A **404** on `GET /v2/conference/participants` is normal: no
call in that group yet.

### Restart, reset, rotation

- `coturn` or `turn-credentials`: `docker compose restart <service>`. Restarting coturn drops the
  relayed media of calls in progress; clients keep their cached credentials (coturn checks them
  against the unchanged secret).
- `calling-backend`: restarting it ends every group call in progress; clients rejoin. The frontend
  keeps the records and removes ended calls by itself (the backend calls its internal API; the
  cleaner checks every 30 s).
- Rotating the TURN secrets: delete `turn.env` (and set `turn.cloudflare.apiToken` back to `unset` for a
  new API token), `./coturn/make-turn-env.sh`, `docker compose up -d --no-deps coturn turn-credentials`,
  `docker compose restart chat`. Credentials clients already hold stop working at once, and a desktop
  keeps its relay answer in memory for up to 12 hours (`clientCredentialTtl`): until then, or until
  the app restarts, its calls cannot use the relay.
- Rotating `sfu.env` (after the storage service's group-call secret or the calling zk secret
  changed): delete `sfu.env`, `./sfu/make-sfu-env.sh`, `docker compose up -d --no-deps
  calling-frontend`.
- Reset of the calling data: `docker compose stop calling-frontend`, delete the table
  (`aws dynamodb delete-table --table-name swarm_calling_rooms` against `http://dynamodb:8000`, e.g.
  with `docker compose run --rm --no-deps --entrypoint aws calling-bootstrap ...`), then
  `docker compose up --no-deps calling-bootstrap` and start the frontend. Every call link stops
  working (the clients keep them and fail to join).
- The table lives in the `dynamodb-data` volume, so the nightly snapshot (section 12) includes it.

### Tested on 64.95.11.180, 2026-09-29

- **From outside:** `HEAD`/`GET`/`PUT https://sfu.chat.swarm.green/v2/conference/participants` 401,
  `GET /v1/call-link` 401, `/health` 404 at the edge; `GET /v2/calling/relays` without credentials
  401 (it is a `GET`; `POST` 405); STUN on 3478 UDP and TCP; unauthenticated Allocate 401. After the
  chat restart the websocket upgrade still 101, `/v2/groups` 401, `/v1/storage/manifest` 401 and a
  CDN profile object 200.
- **On the host:** `turn-credentials` 201 in Cloudflare's shape (ttl 86400; 10,000,000 capped at
  172,800), 401 for a wrong or missing token (also from another container), 405 for `GET`, 400 for a
  bad body; `turnutils_uclient` with a minted credential over UDP and over TCP: 40 of 40 messages
  relayed to a public peer, none lost; denied peers 403; a wrong credential refused.
- **One-to-one call** (A with *Always relay calls*, both microphones muted): A's log
  `GET (WS) https://chat.swarm.green/v2/calling/relays 200 Success`, the three TURN URLs, three
  local `typ relay` candidates on coturn ports; B showed *Incoming voice call* and answered;
  A `ice_network_route_change(... local_relayed: true, local_relay_protocol: Udp ...)`,
  `ice_connection_change(Connected)`, `RemoteAccepted`, both `ConnectedAndAccepted`, still
  connected after 36 s, then hung up.
- **Group call** (synthetic video, muted): both `PUT /v2/conference/participants 200 Success` and
  `LocalDeviceState (Connected, Joined)`; the backend logged both clients joining one call and,
  30 s later, both sending simulcast video (120/240/480 lines, about 80/200/510 kbps) and
  receiving about 510 kbps; each saw the other's video; both left, the backend removed the call and
  the frontend its record.
- **Call link:** created (`POST /v1/call-link/create-auth?v101=true 200`, `PUT /v1/call-link 200`),
  started by A, B read it and asked to join, A approved, B joined (2 people, video both ways),
  deleted afterwards (`DELETE /v1/call-link 200`; a first attempt right after the call answered
  409 because the call record still existed, see section 10).

Not tested: real audio (both microphones stayed muted; RingRTC's native audio uses the PC's real
devices, Chromium's fake-device switches do not reach it), clients on different networks and
behind other NATs (both instances ran on one PC; one side was forced through the relay), mobile
clients, `turns:` over TLS for networks that allow only 443, IPv6, more than two participants, load.

---

## 6. Start order

Compose enforces this with `depends_on` conditions, but know it for debugging:

```
foundationdb            (healthy: fdbcli reports "The database is available")
  └─ foundationdb-init  (runs "configure new single ssd" once, then exits 0)
dynamodb                (healthy: answers HTTP)
  └─ dynamodb-bootstrap (creates 34 tables + TTLs, then exits 0)
minio                   (healthy: mc ready)
  └─ minio-bootstrap    (3 buckets, scoped CDN key, the tus key, anonymous reads of
       │                 attachments/ and profiles/, uploads the 2 polled objects, exits 0)
       └─ tus           (healthy: its MinIO key can read under attachments/)
redis-cache, redis-pushscheduler, redis-ratelimiters, redis-messages
                        (healthy: cluster_state:ok)
redis-pubsub            (healthy: PONG)
registration-stub       (healthy: a CreateSession round trip over its own TLS)
  └─ chat               (healthy: GET :8081/healthcheck is 200)
       └─ caddy         (profile: edge)
bigtable                (healthy: accepts connections on 8086)
  └─ bigtable-bootstrap (creates the 4 tables + column families if missing, exits 0)
       └─ storage       (healthy: GET :8080/_ready is 200, which reads each table once)
coturn                  (host network; healthy: answers a STUN Binding request on 3478)
turn-credentials        (healthy: GET :8080/healthz is 200)
dynamodb
  └─ calling-bootstrap  (creates swarm_calling_rooms + its TTL if missing, exits 0)
calling-backend         (healthy: GET :8080/health is 200)
  └─ calling-frontend   (after calling-bootstrap; healthy: GET :8080/health is 200)
```

`chat` needs `turn-credentials` only when a client asks for relays, and Caddy reaches
`calling-frontend` per request, so neither waits for the other.

`chat` does not wait for `storage`: it calls it only when an account is deleted, and clients
reach it through Caddy, which resolves `storage` per request.

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

# the CDN3 upload service ("ok", or why its MinIO key does not work)
docker compose exec tus node -e "fetch('http://127.0.0.1:1080/healthz').then(async r => console.log(r.status, await r.text()))"

# the registration stub
docker compose exec registration-stub python /app/healthcheck.py && echo STUB-OK

# the storage service and its Bigtable emulator (section 5c)
docker compose ps bigtable storage
docker compose exec storage bash -c "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /_ready HTTP/1.0\r\n\r\n' >&3 && head -c 12 <&3"
docker compose logs bigtable-bootstrap

# calls (section 5d)
docker compose ps coturn turn-credentials calling-backend calling-frontend
curl -sI https://sfu.chat.swarm.green/v2/conference/participants | head -1   # 401

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
| **GCP attachments (CDN2)** | `gcs.disabled.swarm.invalid`, throwaway RSA signing key | A CDN2 form would point at a name that does not resolve, so none is handed out: the dynamic-configuration experiment `cdn3` gives every account CDN3 (TUS) forms, served by the `tus` service. Avatars use CDN0, the `cdn` block (MinIO). Section 8a |
| ~~Cloudflare TURN / calling~~ | **on since 2026-09-29**: the `turn.cloudflare` client talks to the stack's own `turn-credentials` service, coturn relays, Signal's calling service runs at `sfu.chat.swarm.green` (section 5d) | one-to-one and group calls and call links work; no `turns:` (TLS) relay yet |
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

Status 2026-09-27 (Opus M-J): **implemented and live on the staging host** (swarm-main
`1ed47927f`; CDN3 switched on at 19:26 UTC) and **tested** with real desktop clients: photos, files
and profile photos, both directions. What was tested is at the end of this section. The contract
below was written from this revision's code and the desktop client's before the implementation.

Every byte that reaches the CDN is **ciphertext**. The client encrypts an attachment with a
random per-attachment key (AES-256-CBC + HMAC-SHA256) that travels only inside the end-to-end
encrypted message, a profile photo with the profile key, and a group photo with the group's key.
Neither the chat server, the storage service, the upload service nor MinIO ever sees a key.
Object names are random, and anyone who knows one can fetch the ciphertext, exactly as on
Signal's own CDNs.

| What | Upload | Stored in MinIO bucket `swarm-cdn` as | Read with |
|---|---|---|---|
| message attachments (images, files, voice notes, link-preview images) | **CDN3**: TUS to `https://cdn.chat.swarm.green/upload/attachments`, served by the `tus` service | `attachments/<key>` | `GET https://cdn.chat.swarm.green/attachments/<key>` |
| profile avatars | **CDN0**: S3 POST-policy form to `https://cdn.chat.swarm.green/`, checked by MinIO | `profiles/<name>` | `GET https://cdn.chat.swarm.green/profiles/<name>` |
| group photos (since 2026-09-29) | **CDN0**: the same, with the form from the storage service (`GET /v2/groups/avatar/form`, section 5c) | `groups/<group id>/<random>` | `GET https://cdn.chat.swarm.green/groups/<group id>/<random>` |

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
| GET, HEAD | `/attachments/*`, `/profiles/*`, `/groups/*` | MinIO, bucket `swarm-cdn` | bucket policy: anonymous `s3:GetObject` on exactly these three prefixes; no listing, nothing else |
| anything else | | 404 | |

Nothing published accepts an unauthenticated write: a TUS write needs the chat server's token, a
POST-policy write needs a policy signed with the CDN key.

### The upload service: `deploy/staging/tus/`

Node 22, standard library only: one file, `server.mjs`, with its tests in `tus/test/`
(`node --test deploy/staging/tus/test/server.test.mjs`). It stages the bytes of an upload in the volume `tus-data` and, when the last byte arrives, writes the
object to MinIO with one SigV4 `PutObject`, using its **own** MinIO user, which may only put and
get objects under `swarm-cdn/attachments/`. Its credentials live in `deploy/staging/tus.env`
(mode 600, git-ignored), written once by `tus/make-tus-env.sh`: its copy of
`tus.userAuthenticationTokenSharedSecret` (it must stay equal to the one in
`staging-secrets.yml`) and its MinIO key. A separate file, so the chat container's environment
does not change.

### Runbook

First deployment on a host that already runs the stack, from `deploy/staging` in a checkout of
this revision:

```sh
./tus/make-tus-env.sh                 # once: writes tus.env (mode 600), prints no secret
docker compose build tus
docker compose up --no-deps minio-bootstrap   # the tus MinIO user, the anonymous read policy,
                                              # and the re-upload of minio/dynamic-config.yaml
docker compose up -d --no-deps tus            # healthy within ~20 s: docker compose ps tus
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

`caddy/Caddyfile` is bind-mounted as a single file, which Docker binds by inode: change it **in
place** (`cat new > caddy/Caddyfile`). A tool that writes a new file and renames it leaves the
container reading the old one, and `caddy reload` then reloads the old configuration.

No chat restart: `staging.yml` does not change, and the server re-reads the dynamic configuration
every 30 s (`dynamicConfig.refreshInterval`). `--no-deps` keeps compose from touching anything the
service depends on.

Checks from anywhere:

```sh
curl -si -X OPTIONS https://cdn.chat.swarm.green/upload/attachments | grep -i '^tus-'  # Tus-Version: 1.0.0
curl -so /dev/null -w '%{http_code}\n' -X POST https://cdn.chat.swarm.green/upload/attachments  # 412, not 405
curl -sI https://cdn.chat.swarm.green/attachments/<key>   # 200 with Content-Length for an uploaded key
curl -so /dev/null -w '%{http_code}\n' https://cdn.chat.swarm.green/                 # 404: no listing
```

On the host: `docker compose logs --tail 50 tus` prints one line per request (method, the first
four characters of the key, status, bytes, time), never a header.

- **CDN3 off again** (every form back to CDN2, which does not work here): set
  `enrollmentPercentage: 0` in `minio/dynamic-config.yaml` and `docker compose up minio-bootstrap`.
- **Rotating the token secret**: it lives in two places, `tus.userAuthenticationTokenSharedSecret`
  in `staging-secrets.yml` and `SWARM_TUS_TOKEN_SECRET` in `tus.env`. Change both, then
  `docker compose up -d chat` and `docker compose up -d --no-deps tus`. Uploads in flight fail;
  clients retry with new forms.
- **Unfinished uploads** live in the volume `tus-data` and are deleted 7 days after they started.
  Losing the volume loses only unfinished uploads.

### Tested on 64.95.11.180, 2026-09-27

Step by step, with the log lines, in the vault Live Log (entries "Opus M-J attachments").

- **Edge**, from outside: `OPTIONS /upload/attachments` 204 with `Tus-Version: 1.0.0`; a POST
  without `Tus-Resumable` 412, without a token 401, with Basic credentials 400; PUT, DELETE and a
  bucket listing 404; a missing object 404 instead of MinIO's 403.
- **TUS through the edge** with a token made like `JwtGenerator`'s: creation-with-upload of 3,872
  chunked bytes 201, HEAD 200 with the full offset, `GET /attachments/<key>` 200 with
  `Content-Length` and identical bytes, `Range` 206; the resume path (creation, PATCH 123,456
  bytes, HEAD, PATCH at a wrong offset 409, PATCH the rest 204) stored 300,000 identical bytes; a
  token for another key 401, `Upload-Length` above `maxLen` 413, a forged signature 401.
- **Avatar form through the edge**, built like `PostPolicyGenerator`'s and sent like the desktop's:
  POST 204, `GET /profiles/<name>` 200 with identical bytes; the same form for a key the policy
  does not name 403.
- **Desktop clients** (swarm-messenger `b6a1c821c`, libsignal 0.101.2-swarm.1): a 127,888-byte
  attachment that had been stuck since 17:41 UTC went out at 19:29 UTC, seconds after CDN3 was
  switched on, and the other side downloaded it; two fresh accounts then exchanged a photo (A to
  B) and a `.txt` file (B to A), both delivered and shown, and A's profile photo, uploaded at
  sign-up (`POST https://cdn.chat.swarm.green/` 204), appeared on B once B accepted the message
  request.

Not covered, or not working:

- **Stickers.** The desktop asks `cdn.chat.swarm.green/stickers/<pack>/manifest.proto` for
  Signal's default sticker packs; they are not hosted here, so that answers 404.
- **Backups (CDN3 `backups`)** are not served: only the `attachments` namespace exists.
- **Voice notes and videos** use the same upload path but were not tried.
- **One upload service, one disk.** Fine for staging; for more it needs shared staging storage
  or S3 multipart like Signal's tus-server.
- A client-side oddity, not the server: once, a received file kept its spinner in a chat that was
  open when it arrived, although the download had finished; reopening the app showed it.

---

## 9. Backup and recovery

| What | Where | How |
|---|---|---|
| **`deploy/staging/staging-secrets.yml`** | host filesystem, mode 600 | **Back this up off the host.** The four zk secrets and the sealed-sender trust root are baked into credentials clients already hold; rotating them means updating every client |
| **`deploy/staging/certs/`** | host filesystem | back up. Regenerating means editing `SWARM_REGISTRATION_CA_PEM` in `.env` and restarting `chat` |
| **`deploy/staging/.env`** | host filesystem, mode 600 | back up. Contains the public zk half and the sealed-sender certificate, which must stay paired with the secrets |
| `deploy/staging/tus.env` | host filesystem, mode 600 | back up, or recreate: `tus/make-tus-env.sh` copies the token secret from `staging-secrets.yml` again and makes a new MinIO key (then re-run `minio-bootstrap`) |
| `deploy/staging/storage.env` | host filesystem, mode 600 | back up, or recreate: `storage/make-storage-env.sh` derives two of its three secrets from `staging-secrets.yml` again; the third (group-call tokens) is new, which only invalidates tokens already handed out |
| `deploy/staging/shared/staging-public-params.json` | host filesystem | public, but regenerate-or-back-up: it is the record of what the clients were built against |
| Accounts, keys, profiles, sessions | Docker volume `dynamodb-data` | `docker compose stop chat dynamodb && tar` the volume. DynamoDB Local is a single SQLite-ish file per table set |
| Undelivered and stored messages | Docker volume `fdb-data` + `redis-messages-data` | in the nightly snapshot (section 12): `fdb-data` is tarred with `foundationdb` stopped (chat and storage stopped too), so the copy is consistent. `fdbbackup` would give a copy without stopping anything |
| Attachments and avatars | Docker volume `minio-data` | `mc mirror` to another location |
| Unfinished attachment uploads | Docker volume `tus-data` | not worth backing up: clients retry a failed send with a new upload form |
| Groups, group change logs, settings/contacts sync records | Docker volume `bigtable-data` (LevelDB files of the Bigtable emulator); after the switch to FoundationDB (section 5c) `fdb-data`, directory `swarm-storage-service` | in the nightly snapshot (section 12): stop `bigtable` for a second and tar the volume; after the switch they are in `fdb-data.tgz`. Losing them breaks every existing group (section 5c, "Reset") |
| `deploy/staging/turn.env` | host filesystem, mode 600 | back up, or recreate with `coturn/make-turn-env.sh` (section 5d, rotation): clients fetch new relay credentials by themselves |
| `deploy/staging/sfu.env` | host filesystem, mode 600 | recreate with `sfu/make-sfu-env.sh`: both values are copies of secrets in `storage.env` and `staging-secrets.yml` |
| Active group calls and call links | DynamoDB table `swarm_calling_rooms` in the `dynamodb-data` volume | part of the DynamoDB copy in the nightly snapshot. Losing it ends calls in progress and every call link |

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
| Desktop: **New group** turns the window blank; log says `Failed to parse global.groupsv2.maxGroupSize as an integer` | `remoteConfig.globalConfig` in `staging.yml` lacks the group size limits | set `groupsv2.maxGroupSize` and `groupsv2.groupSizeHardLimit` (without `global.`: the server adds that prefix), restart `chat`, reload the client |
| Desktop: group creation says "This group couldn't be created"; `PUT /v2/groups 404` in its log | the request reached the chat server, not the storage service: the `@storage` route is missing from the running Caddy config | check `caddy/Caddyfile` (chat site block), validate and `caddy reload` (section 5c); `curl https://chat.swarm.green/v2/groups` must answer 401 |
| Desktop: `PUT /v2/groups 502` (or `/v1/storage` 502) | `storage` is down or restarting | `docker compose ps storage bigtable`, `docker compose logs storage`; `docker compose up -d storage` |
| Desktop: every `/v1/storage` call answers 401 although `GET /v1/storage/auth` was 200 | `SWARM_STORAGE_AUTH_KEY_HEX` in `storage.env` is not the chat server's `storageService.userAuthenticationTokenSharedSecret` | delete `storage.env`, `./storage/make-storage-env.sh`, `docker compose up -d storage` |
| Desktop: every `/v2/groups` call answers 401 | `SWARM_STORAGE_ZK_SERVER_SECRET` is not the chat server's `groupsZkConfig.serverSecret` | same fix |
| `storage` exits at start: `DecoderException`, `InvalidInputException` or an unresolved `${SWARM_STORAGE_...}` | `storage.env` is missing | `./storage/make-storage-env.sh`, then `docker compose up -d storage` |
| `storage` unhealthy, its log shows `NOT_FOUND` for a `swarm_storage_*` table | the tables were never created in this emulator volume | `docker compose up bigtable-bootstrap` and read its output, then `docker compose restart storage` |
| `storage` exits at start with `UnsatisfiedLinkError` (`libfdb_c`) or never gets healthy on FoundationDB (`transaction_timed_out`, 1031) | the image lacks `/usr/lib/libfdb_c.so` (built from an old `storage/build/`), or the cluster file is not mounted or the `foundationdb` service is not available | `./storage/prepare-image.sh` again and `docker compose build storage`; `docker compose ps foundationdb`, `docker compose exec foundationdb fdbcli --exec 'status minimal'`; the `fdb-etc` mount of `storage` in `docker-compose.yml` |
| Desktop: a new account's first `GET /v1/storage/manifest` answers 404, log `sync(0): missing` | nothing stored for it yet | expected; the app writes the first manifest right after (`PUT /v1/storage/ 200`) |
| A group photo does not show for the other members; their log has `GET (REST) https://cdn.chat.swarm.green/[REDACTED]...` with 403 or 404 | 403 with `Server: MinIO`: the bucket's anonymous policy lacks `groups/*` (an older `minio/bootstrap-buckets.sh` ran); 404 with `Server: Caddy`: the running Caddy config lacks `/groups/*` in the `cdn.` block's `@read` | `docker compose up --no-deps minio-bootstrap`, check `mc anonymous get-json local/swarm-cdn`; or validate and `caddy reload`. Section 5c, "Group photos" |
| Calls: `GET /v2/calling/relays` answers 500 in a client log; the chat log has `failure request credentials from Cloudflare Turn (code=401)` | `turn.cloudflare.apiToken` in `staging-secrets.yml` differs from `SWARM_TURN_API_TOKEN` in `turn.env`, or the chat server was not restarted after the token changed | make them equal (section 5d, rotation), `docker compose restart chat` |
| Calls: relays arrive but a relayed call never connects; `turnutils_uclient` gets `401` | `SWARM_TURN_STATIC_AUTH_SECRET` of `coturn` and `turn-credentials` differ (one was not recreated after `turn.env` changed) | `docker compose up -d --no-deps --force-recreate coturn turn-credentials` |
| Calls: every relayed call fails; `turnutils_uclient` to a public peer ends in `channel bind: error 403`; coturn logs `denied in the range: ::-::1` | an IPv6 `denied-peer-ip` range starting at `::` matches every IPv4 peer (section 5d, Security) | remove it from `coturn/turnserver.conf`, `docker compose restart coturn` |
| Calls: coturn restarts in a loop with `cannot create /var/lib/coturn/turnserver.conf: Permission denied` | the tmpfs is not owned by the image's user | keep `uid=65534,gid=65534,mode=700` on the `tmpfs` line of `coturn` in `docker-compose.yml` |
| Group call: `GET https://sfu.chat.swarm.green/v2/conference/participants` answers 401/403 in a client log although `GET /v2/groups/token` was 200 | `CALLING_AUTH_KEY` in `sfu.env` is not the storage service's `SWARM_STORAGE_GROUP_CALL_SECRET_HEX` | delete `sfu.env`, `./sfu/make-sfu-env.sh`, `docker compose up -d --no-deps calling-frontend` |
| Group call: joins (`PUT ... 200`) but never connects | UDP and TCP 10000 do not reach `calling-backend` (firewall, or `--ice-candidate-ip` is not the public address) | `ufw status`, `docker compose ps calling-backend`, check the published ports |
| `calling-frontend` exits at start with a zkgroup or base64 error, or `the following required arguments were not provided` | `sfu.env` is missing or `CALLING_ZKPARAMS` is not `callingZkConfigV101.serverSecret` | `./sfu/make-sfu-env.sh`, then start it again |
| Deleting a call link fails with 409 | the link's call record still exists: the backend removes an empty call about 30 s after the last client left | try again a minute later |
| An attachment spins forever; the client log shows a POST to `gcs.disabled.swarm.invalid` | the account got a CDN2 form: the `cdn3` experiment is missing from `s3://swarm-config/dynamic-config.yaml` | `docker compose up minio-bootstrap` (re-uploads `minio/dynamic-config.yaml`); the server re-reads it within 30 s |
| `tus` answers 401 to every upload | `SWARM_TUS_TOKEN_SECRET` in `tus.env` is not `tus.userAuthenticationTokenSharedSecret` | fix `tus.env`, `docker compose up -d --no-deps tus` |
| `tus` is unhealthy, `/healthz` says `S3 HEAD answered 403` | its MinIO user or policy is missing | `docker compose up minio-bootstrap`, then wait a minute (it re-probes) |
| Downloads from `cdn.` answer 403 with `Server: MinIO` | the bucket's anonymous read policy is missing | `docker compose up minio-bootstrap`; check with `mc anonymous get-json local/swarm-cdn` |

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
- [ ] Calls: a `turns:` (TLS) relay on 443 for networks that allow nothing else, more relay ports
      and a second coturn/backend for capacity, IPv6, and a real DynamoDB for the calling service's
      table.

## 12. Nightly snapshot of the data (since 2026-09-28)

`deploy/staging/backup-nightly.sh` runs from root's crontab at 04:10 UTC: it stops the chat
and storage containers (about one minute; clients reconnect on their own; since 2026-09-29 the
storage service's data is in FoundationDB too) and copies DynamoDB Local through sqlite3's online
backup; it stops `foundationdb` too (since 2026-09-29), tars `fdb-data` and starts it again
right away, waiting until `fdbcli` reports the database available; it tars the MinIO and
redis-messages volumes, and (since 2026-09-28) stops the Bigtable emulator for about a second to
tar its volume as `bigtable-data.tgz` (groups and settings sync until the switch to
FoundationDB, section 5c); then it starts chat and storage again and keeps seven days, all into
`/root/backups/<UTC timestamp>/`. Whatever ran before is started again whatever happens (also
from an EXIT trap), FoundationDB first. Every archive is listed with its size, and a tar that
saw a file change prints `(tar exit 1)` next to it. Why stop FoundationDB rather than use
`fdbbackup`: chat and storage are stopped for the copy anyway, so stopping `fdbserver` only adds
its restart (seconds) to the same minute, and a copy of a stopped server's files is what
FoundationDB itself recovers from after any stop, so restoring stays "untar into the volume";
`fdbbackup` would need a `backup_agent` process and a destination mounted into it for every
backup, and `fdbrestore` with agents for every restore, to avoid a pause that happens anyway.
Log:
`/root/backups/backup.log`. It is a snapshot on the same disk - it covers an operator mistake or
a bad deploy, not the loss of the host; copying it elsewhere needs a destination the owner
chooses (an object store or a second machine), which is still open.

Restore, in outline: stop chat and storage, copy the sqlite files back into the dynamodb volume
and untar the three archives into their volumes (for `fdb-data` with `foundationdb` stopped too),
start them again. Since 2026-09-29 groups and settings sync come back with `fdb-data`;
`bigtable-data.tgz` is the emulator's (pre-switch) copy: `docker compose stop storage bigtable`,
empty the `bigtable-data` volume, untar it, start `bigtable`, then `storage` with
`storage.backend: bigtable` (5c, rollback). Test a restore on a throwaway copy of the
stack before relying on it.
