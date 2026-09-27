# SWARM changes from upstream Signal-Server

Upstream fork point: `bdf3e1aea` on `signalapp/Signal-Server` `main`, 2026-09-25. Preserved in
this repository as the branch `upstream-main` and the tag `upstream-bdf3e1a`, so
`git diff upstream-main..swarm-main` is always the complete, authoritative answer to "what did
SWARM change?". This file is the human-readable version of that diff, kept in the order
"code first, then additions", with a reason for every entry.

Licence obligation: this fork is AGPL-3.0 (see `NOTICE-SWARM.md`). This file exists so that
anyone who talks to a SWARM Messenger server can see exactly how it differs from the published
upstream source.

## Rules this fork follows

1. **No cryptographic changes.** No primitive, no protocol, no key handling, no change to
   `libsignal` or how it is called. Nothing in the list below is inside a crypto path.
2. **Configuration before code.** A change to `service/config` or `deploy/staging` is always
   preferred to a change in `service/src/main/java`. Two code changes were unavoidable; both
   are listed first.
3. **Every code change is off by default.** With the SWARM configuration absent, the server
   behaves exactly as upstream does.
4. **No Signal branding in new material.** Upstream files keep their headers and copyright.

---

## 1. Code changes (6)

### 1.1 `DynamoDbClientConfiguration`: optional `endpointOverride`

**File:** `service/src/main/java/org/whispersystems/textsecuregcm/configuration/DynamoDbClientConfiguration.java`

Added one nullable record component, `@Nullable URI endpointOverride`, and passed it to
`.endpointOverride(...)` on both the sync and async DynamoDB client builders.

**Why.** A self-hosted stack stores accounts, keys, profiles and sessions in DynamoDB Local
instead of AWS DynamoDB. Upstream's `default` DynamoDB factory has no way to change the
endpoint: `region` alone always resolves to the real AWS endpoint. The only existing
alternative, `LocalDynamoDbFactory` (`type: local`), lives in the **test** source set, starts
its own testcontainer and creates upstream's `*_test` tables, so it is not available in the
shaded jar and not appropriate for a long-lived staging deployment.

**Why this shape.** It copies a pattern upstream already uses for the same reason elsewhere:
`CdnConfiguration`, `PagedSingleUseKEMPreKeyStoreConfiguration` and
`MonitoredS3ObjectConfiguration` all carry a `@Nullable URI endpointOverride` that is handed
straight to an AWS SDK builder. The SDK's `SdkDefaultClientBuilder.endpointOverride` handles
`null` explicitly (it clears the endpoint provider), so an absent value is byte-for-byte
upstream behaviour.

**Risk.** None when unset, which is the default and the only value any production
configuration would carry. When set it points the DynamoDB clients somewhere else, which is
the entire purpose.

### 1.2 `SwarmStagingRegistrationServiceConfiguration`: a registration channel without a Google Cloud identity token

**Files:**
- `service/src/main/java/org/whispersystems/textsecuregcm/configuration/SwarmStagingRegistrationServiceConfiguration.java` (new)
- `service/src/main/resources/META-INF/services/org.whispersystems.textsecuregcm.configuration.RegistrationServiceClientFactory` (new)

A new `RegistrationServiceClientFactory` registered as `type: swarm-staging`. It builds
upstream's own, unmodified `RegistrationServiceClient` — same TLS channel, same pinned CA
certificate, same collation-key salt, same wire protocol — with `callCredentials = null`.

It refuses to build unless the environment variable `SWARM_STAGING_FIXED_CODE` is exactly
`true`, and throws `IllegalStateException` otherwise, which aborts server startup.

**Why.** Upstream's `default` factory (`RegistrationServiceConfiguration`) calls
`IdentityTokenCallCredentials.fromCredentialConfig`, which builds Google
`ExternalAccountCredentials`, impersonates a service account and fetches an identity token —
with `maxAttempts(Integer.MAX_VALUE)` and exponential backoff. On a host with no Google Cloud
project that call never succeeds and the server never finishes starting. There is no
configuration that avoids it. Without a working registration channel a staging stack cannot
create a single account, so it cannot be tested at all.

**Why not the upstream test stub.** `StubRegistrationServiceClientFactory` (`type: stub`) does
exist and accepts any code, but it is in the **test** source set, so it is not in the shaded
jar; and it answers requests in-process, which hides the real gRPC hop that the desktop
registration flow depends on. The SWARM staging stack runs a separate gRPC service
(`deploy/staging/registration-stub/`) so that hop is real and testable.

**Why it cannot be enabled in production.** Three things must all be true:
the configuration must say `type: swarm-staging`; `SWARM_STAGING_FIXED_CODE` must be exactly
`true` in the server's environment; and something must be listening that speaks the
registration protocol. The stub itself has the same environment-variable guard and exits 78
without it. Neither guard has a default, a config key or a command-line flag.

**Risk.** The registration gRPC call carries no bearer token, so anything that can reach the
registration host on the registration port can drive registration sessions. In the staging
stack the stub is on a private Docker network and is never published on a host port; the
Caddyfile answers `reg.chat.swarm.green` with a 404 rather than proxying it. The upstream
`default` type is untouched and remains the only option for a real deployment.

---

### 1.3 Wallet sign-in: four small edits, one new package

Added 2026-09-27 on the owner's decision, *"instead of a phone number make the users sign in with our
wallet."* `docs/WALLET-SIGN-IN.md` is the full account - the protocol, the derivation, why `+888`, what
it is safe against, what phase 2 removes. The upstream files touched:

| File | Change |
|---|---|
| `controllers/RegistrationController.java` | a SWARM account identifier may only be registered by the identity key that derives it (403), and an existing SWARM account may not be handed to a different key (409). Two guards, both no-ops for an ordinary phone number |
| `controllers/VerificationController.java` | `POST /v1/verification/session` refuses a SWARM identifier (400): no SMS or call can ever reach one |
| `limits/RateLimiters.java` | `swarmWalletChallenge` (20/minute, by IP) and `swarmWalletVerify` (6/minute) |
| `WhisperServerService.java` | constructs and registers the new controller; the two-minute challenge TTL |

and the new package `service/src/main/java/org/whispersystems/textsecuregcm/swarm/`:
`SwarmWalletIdentity` (the derivations and the checks, pure functions),
`SwarmWalletChallengeStore` (pending challenges in the rate-limiters Redis, `SET … EX` / `GETDEL`),
`SwarmWalletRegistrationController` (`POST /v1/swarm/registration/challenge` and `/verify`), four DTOs
and one exception. Tests: `SwarmWalletIdentityTest` (23) and `SwarmWalletRegistrationControllerTest`
(10).

**No new table and no new configuration key**, so deploying this is rebuilding the image and
restarting the chat container. Nothing in `deploy/staging/` changed.

## 2. Additions (no upstream file changed)

### 2.1 `deploy/staging/` — the self-hosted stack

New directory. Nothing outside it is affected and the upstream build ignores it.

| File | Purpose |
|---|---|
| `docker-compose.yml` | FoundationDB (messages), DynamoDB Local, four single-node Redis clusters + one standalone Redis, MinIO (S3), the registration stub, the chat server, Caddy (profile `edge`) |
| `staging.yml` | the chat server configuration. Derived from upstream's own `service/src/test/resources/config/test.yml`; only the storage/registration endpoints differ. Annotated block by block |
| `staging-secrets.yml.example`, `.env.example` | templates. The filled-in files are git-ignored |
| `bootstrap-host.sh` | one command on a fresh Ubuntu 24.04 host: Docker Engine + compose plugin, Temurin JDK 26, a checkout at a pinned commit, the build, the secrets, the stack, Let's Encrypt, and a verification pass |
| `generate-secrets.sh` | generates this deployment's secrets using the server's own `certificate` command and `zkparams/SwarmZkParams.java` (i.e. libsignal), plus `openssl rand`, and writes `shared/staging-public-params.json` for the client builds |
| `zkparams/SwarmZkParams.java` | generates all four sets of zero-knowledge server parameters. Upstream's `zkparams` command produces only `ServerSecretParams`; three of the four configuration blocks need `GenericServerSecretParams`, which is a different libsignal type of a different length |
| `Dockerfile`, `prepare-image.sh`, `.dockerignore` | the chat server image: `eclipse-temurin:26-jre-resolute` + the shaded jar + `libfdb_c.so`, mirroring upstream's jib configuration. `prepare-image.sh` stages exactly those two files so the `COPY` is unambiguous and the build context is two files rather than the whole repository |
| `dynamodb/bootstrap-tables.sh` | creates all 34 tables and their TTLs. Every key schema cites the Java class and constant it came from |
| `foundationdb/init-foundationdb.sh` | `configure new single ssd` on first start; idempotent |
| `minio/bootstrap-buckets.sh`, `minio/dynamic-config.yaml`, `minio/asn.tsv` | the three buckets, a scoped CDN credential, the upload service's credential, anonymous reads of `attachments/` and `profiles/` only, and the two objects the server polls (the dynamic configuration turns on CDN3 for every account) |
| `tus/` | the CDN3 (TUS 1.0.0) upload service for message attachments: `server.mjs` (Node standard library only), its tests, `Dockerfile`, and `make-tus-env.sh` for its credentials. It stands in for Signal's Cloudflare tus-server with the same paths, token and status codes; see `docs/STAGING.md`, section 8a |
| `registration-stub/` | the fixed-verification-code gRPC service (Python, ~200 lines) and its `RegistrationService.proto` copy |
| `certs/make-certs.sh` | the internal CA and the stub's server certificate |
| `caddy/Caddyfile` | TLS edge for `chat.swarm.green` and `cdn.chat.swarm.green` (anonymous reads, TUS uploads to `tus`, avatar POST forms to MinIO; nothing else) |

`registration-stub/RegistrationService.proto` is a verbatim copy of
`service/src/main/proto/RegistrationService.proto`. Keep the copy in sync when rebasing; the
stub's Docker build regenerates its Python bindings from it, so a mismatch shows up at build
time.

### 2.2 Documentation

| File | Purpose |
|---|---|
| `NOTICE-SWARM.md` | AGPL-3.0 attribution, fork point, trademark statement |
| `docs/SWARM-CHANGES.md` | this file |
| `docs/STAGING.md` | the runbook: host sizing, ports, DNS, TLS, start order, health checks, what is disabled and why |
| `docs/STAGING-PROOF-2026-09-26.md` | every command run to verify this work, with its output, and an explicit list of what could not be verified on the machine it was built on |

Upstream's `README.md` and `LICENSE` are untouched.

---

## 3. Things that look like changes but are not

* **Disabled features are configuration, not code.** SVR2/SVRB, CDSI (`directoryV2`), key
  transparency, Stripe, Braintree, Google Play billing, App Store billing, APNs, FCM, GCP
  attachments, Cloudflare TURN and MobileCoin payments are all switched off purely by what
  `deploy/staging/staging.yml` says. No feature flag was added and no code path was removed.
  `docs/STAGING.md` lists each one with the client-visible consequence.
* **Captcha.** Nothing was changed. The `spam-filter` submodule is a private Signal module
  that is not part of this fork, so upstream's own fallback applies: `CaptchaClient.noop()`,
  which accepts the site key `noop` (token `noop.noop.registration.noop`). The same fallback
  gives no-op spam, challenge-constraint, registration-fraud and registration-recovery
  checkers.
* **`-Pexclude-spam-filter`.** Not a SWARM profile. It is upstream's, and it is what builds the
  shaded runnable jar and downloads `libfdb_c.so`. It has no `<activation>` block in
  `service/pom.xml`, so it must be named on the command line.
* **The zk parameter types.** Nothing was changed in how the server reads them.
  `SwarmZkParams.java` exists because upstream simply has no command for
  `GenericServerSecretParams`; it calls libsignal's own generator.

---

## 4. Not done, on purpose

* **No phone-number-free registration.** Phase 1 keeps upstream's phone-number identity, as
  agreed in the project plan. That is a server and client change and is not in this fork yet.
* **No SWARM payment message type.** The in-chat SWARM payment notice (extending
  `DataMessage.payment`) belongs to the wallet work and is not in this fork yet.
* **No branding changes in the server.** The server has no user-visible branding. The Java
  package remains `org.whispersystems.textsecuregcm` and the artifact remains
  `TextSecureServer`: renaming them would touch every file, break `git diff
  upstream-main..swarm-main` as a review tool, and make rebasing onto upstream painful, for no
  benefit. Product-facing naming lives in the clients.
