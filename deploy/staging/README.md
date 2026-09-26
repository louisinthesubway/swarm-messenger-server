# SWARM Messenger — staging stack

A self-hosted Signal-Server derivative: registration, accounts, keys and messaging on one
Linux host, with every cloud dependency replaced by a local container and every
enclave-backed feature switched off.

**Read [`../../docs/STAGING.md`](../../docs/STAGING.md) first.** It has host sizing, ports,
DNS, start order, health checks, and the full list of what is disabled and why.

## Files

| Path | What it is |
|---|---|
| `docker-compose.yml` | the whole stack: FoundationDB, DynamoDB Local, 4 Redis clusters + 1 standalone Redis, MinIO, the registration stub, the chat server, and Caddy (profile `edge`) |
| `staging.yml` | the chat server's configuration. Committed, environment-substituted, no secrets |
| `staging-secrets.yml.example` | template for the secrets bundle. Copy to `staging-secrets.yml` (git-ignored) or let `generate-secrets.sh` write it |
| `.env.example` | template for the compose environment. Copy to `.env` (git-ignored) |
| `bootstrap-host.sh` | one command on a fresh Ubuntu 24.04 host: Docker, JDK 26, a pinned checkout, the build, the secrets, the stack, and Let's Encrypt |
| `generate-secrets.sh` | generates this deployment's zk parameters, sealed-sender trust root, random shared secrets, internal CA, `.env`, `staging-secrets.yml` and `shared/staging-public-params.json` |
| `zkparams/SwarmZkParams.java` | generates all four sets of zero-knowledge server parameters with libsignal. The server's own `zkparams` command only produces one of the two types needed |
| `Dockerfile` | the chat server image (build context is the repository root) |
| `dynamodb/bootstrap-tables.sh` | creates all 34 DynamoDB tables and their TTLs; every schema is annotated with the Java class it comes from |
| `foundationdb/init-foundationdb.sh` | `configure new single ssd` on first start |
| `minio/bootstrap-buckets.sh` | creates the three buckets, the scoped CDN key, and uploads the two objects the server polls |
| `minio/dynamic-config.yaml` | the dynamic configuration object. Editing this and re-running `minio-bootstrap` is how staging's dynamic config changes |
| `registration-stub/` | the fixed-verification-code gRPC service. See its own README |
| `certs/make-certs.sh` | internal CA + certificate for the gRPC hop to the stub |
| `caddy/Caddyfile` | TLS edge for `chat.swarm.green` / `cdn.chat.swarm.green` |

## Shortest path

On a fresh Ubuntu 24.04 host, with DNS already pointing here:

```sh
sudo SWARM_ACME_EMAIL=you@example.com SWARM_COMMIT=<full sha> ./bootstrap-host.sh
```

By hand:

```sh
cd ../..                                               # the repository root
./mvnw -DskipTests -Pexclude-spam-filter package       # the profile is REQUIRED
cd deploy/staging
./generate-secrets.sh
$EDITOR .env                                           # set SWARM_ACME_EMAIL
docker compose up -d
docker compose logs -f chat
curl -sf http://127.0.0.1:8081/healthcheck
```

`docker compose --profile edge up -d caddy` adds the public TLS edge — only once DNS points
at the host.

`shared/staging-public-params.json` is what the client builds need. See
[`../../docs/STAGING.md` §5a](../../docs/STAGING.md) for the format, and for why a client
cannot reach this server until libsignal gains a SWARM environment.

## The one thing that must never leak into production

`SWARM_STAGING_FIXED_CODE=true`. It is what lets the registration stub run and what lets the
chat server use `registrationService.type: swarm-staging`. Without it the stub exits 78 and
the server refuses to start. There is no other way to turn either on.
