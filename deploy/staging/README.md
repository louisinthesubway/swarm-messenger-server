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
| `generate-secrets.sh` | generates this deployment's zk parameters, sealed-sender trust root, random shared secrets, internal CA, `.env` and `staging-secrets.yml` |
| `Dockerfile` | the chat server image (build context is the repository root) |
| `dynamodb/bootstrap-tables.sh` | creates all 34 DynamoDB tables and their TTLs; every schema is annotated with the Java class it comes from |
| `foundationdb/init-foundationdb.sh` | `configure new single ssd` on first start |
| `minio/bootstrap-buckets.sh` | creates the three buckets, the scoped CDN key, and uploads the two objects the server polls |
| `minio/dynamic-config.yaml` | the dynamic configuration object. Editing this and re-running `minio-bootstrap` is how staging's dynamic config changes |
| `registration-stub/` | the fixed-verification-code gRPC service. See its own README |
| `certs/make-certs.sh` | internal CA + certificate for the gRPC hop to the stub |
| `caddy/Caddyfile` | TLS edge for `chat.swarm.green` / `cdn.chat.swarm.green` |

## Shortest path

```sh
# on the host, in this directory
../../mvnw -DskipTests -Pexclude-spam-filter package   # from the repo root, actually
./generate-secrets.sh
$EDITOR .env                                           # set SWARM_ACME_EMAIL
docker compose up -d
docker compose logs -f chat
curl -sf http://127.0.0.1:8081/healthcheck
```

`docker compose --profile edge up -d caddy` adds the public TLS edge — only once DNS points
at the host.

## The one thing that must never leak into production

`SWARM_STAGING_FIXED_CODE=true`. It is what lets the registration stub run and what lets the
chat server use `registrationService.type: swarm-staging`. Without it the stub exits 78 and
the server refuses to start. There is no other way to turn either on.
