# SWARM Messenger staging server — what was proven, and what was not

Date: 2026-09-26. Agent: Opus M-B. Branch: `swarm-main`, forked from upstream `bdf3e1aea`.

Two lists. The first is everything actually executed, with the command and its real output.
The second is everything that could **not** be executed on the machine this was built on, why,
and exactly what the owner's host has to do instead. Nothing here is inferred: if it is in the
first list, it ran.

The build machine: Windows 11, no Docker daemon, no Linux kernel available (see §B1).

---

## A. What ran

### A1. Toolchain

`pom.xml` says `<release>26</release>` and `<foundationdb.version>7.3.76</foundationdb.version>`,
so a portable Temurin JDK 26 was installed under `D:\swarm-messenger\.tools\jdk` — nothing on
the machine itself, nothing on C:.

```
$ D:/swarm-messenger/.tools/jdk/bin/java -version
openjdk version "26.0.2.1" 2026-08-18
OpenJDK Runtime Environment Temurin-26.0.2.1+1 (build 26.0.2.1+1)
OpenJDK 64-Bit Server VM Temurin-26.0.2.1+1 (build 26.0.2.1+1, mixed mode, sharing)
```

Maven's repository cache is on D: via `MAVEN_OPTS=-Dmaven.repo.local=D:\swarm-messenger\.cache\m2`,
as the workspace rules require. `./mvnw` (the wrapper) was used throughout; Maven was never
installed.

### A2. Repository and branches

```
$ git remote add swarm https://github.com/Swarm-Official/swarm-messenger-server.git
$ git branch upstream-main main
$ git tag -a upstream-bdf3e1a -m "Upstream Signal-Server main at bdf3e1aea, cloned 2026-09-25" main
$ git branch swarm-main main && git checkout swarm-main

$ git push swarm upstream-main:upstream-main
 * [new branch]          upstream-main -> upstream-main
$ git push swarm upstream-bdf3e1a
 * [new tag]             upstream-bdf3e1a -> upstream-bdf3e1a
$ git push -u swarm swarm-main:swarm-main
 * [new branch]          swarm-main -> swarm-main
```

No force-push was used at any point. `git diff upstream-main..swarm-main` is the complete
record of SWARM's changes.

### A3. `./mvnw -DskipTests package` — the build asked for

```
$ ./mvnw -B -DskipTests package
[INFO] Reactor Summary for TextSecureServer 20260925.1.0:
[INFO] TextSecureServer ................................... SUCCESS [  2.748 s]
[INFO] websocket-resources ................................ SUCCESS [  7.540 s]
[INFO] service ........................................... SUCCESS [01:33 min]
[INFO] api-doc ........................................... SUCCESS [ 12.760 s]
[INFO] integration-tests ................................. SUCCESS [  3.261 s]
[INFO] BUILD SUCCESS
```

**But that command does not produce a runnable server.** It yields only the thin jar
(`TextSecureServer-<version>.jar`, 7.3 MB, no dependencies, no main-class manifest). The shade
plugin, the assembly and the FoundationDB client download all live in the `exclude-spam-filter`
profile in `service/pom.xml`, and that profile has **no `<activation>` block**, so nothing
activates it implicitly. `mvn help:active-profiles -pl service` confirms it:

```
$ ./mvnw -B -pl service help:active-profiles
The following profiles are active:
 - exclude-spam-filter (source: org.whispersystems.textsecure:TextSecureServer:20260925.1.0)
```

— that is the **root** pom's profile of the same name, which only adds/removes the
`spam-filter` module. The service module's own profile of the same id is not listed.

So the real build command, the one in `docs/STAGING.md` and in `bootstrap-host.sh`, is:

```
$ ./mvnw -B -DskipTests -Pexclude-spam-filter package
[INFO] BUILD SUCCESS
```

Recorded artifacts from the final build of the committed tree (all nine commits, clean working
directory):

```
$ ./mvnw -B -DskipTests -Pexclude-spam-filter package
[INFO] BUILD SUCCESS

$ ls -la service/target/
427395782  TextSecureServer-20260925.1.1-SNAPSHOT.jar          <- the shaded, runnable jar
408971696  TextSecureServer-20260925.1.1-SNAPSHOT-bin.tar.gz   <- assembly: jar + config
  7282481  original-TextSecureServer-20260925.1.1-SNAPSHOT.jar <- pre-shade, kept by the plugin
  2305056  TextSecureServer-20260925.1.1-SNAPSHOT-tests.jar
 23962936  jib-extra/usr/lib/libfdb_c.so                       <- FoundationDB 7.3.76 client

$ sha256sum service/target/TextSecureServer-20260925.1.1-SNAPSHOT.jar
$ sha256sum service/target/jib-extra/usr/lib/libfdb_c.so
c1f58355a557f53c8aabb2b49bb6a591d64f263f854d30dfe56f508b3300617d  TextSecureServer-20260925.1.1-SNAPSHOT.jar
af099848721d08904ff9e5d38fade0de24d92e86451ea491d9ab5ce84adcf62a  libfdb_c.so
```

The version string comes from jgitver, which derives it from git; `-SNAPSHOT` simply means HEAD
is not tagged. The `libfdb_c.so` hash is exactly the value pinned in `pom.xml` as
`<foundationdb.client-library-sha256>`, which the `download-maven-plugin` verifies — so the
client library in the image is the one upstream intends, not whatever a mirror served.

That listing is also why `prepare-image.sh` exists. The Dockerfile originally said
`COPY service/target/TextSecureServer-*.jar /opt/swarm/chat.jar`, and that glob matches **two**
files — the shaded jar and the `-tests` jar. A `COPY` with several matched sources and a single
file as its destination is an error, so `docker compose build chat` would have failed on the
owner's host with a message about the destination not being a directory. Using the repository
root as the build context would also have shipped every `target/` directory to the daemon,
which is well over a gigabyte. `prepare-image.sh` resolves the shaded jar by exclusion, refuses
to proceed if what it found is the thin jar, and stages exactly two files; the build context is
`deploy/staging` with a `.dockerignore` that admits only those two, so no secret ever reaches
the daemon.

```
$ ./prepare-image.sh
staged into deploy/staging/build:

  chat.jar        from TextSecureServer-20260925.1.1-SNAPSHOT.jar
                  427395782 bytes
                  sha256 c1f58355a557f53c8aabb2b49bb6a591d64f263f854d30dfe56f508b3300617d
  libfdb_c.so     FoundationDB client library
                  23962936 bytes
                  sha256 af099848721d08904ff9e5d38fade0de24d92e86451ea491d9ab5ce84adcf62a

next: docker compose build chat
```

One build failure worth recording, because the owner's host can hit it: the first attempt died
with `Native memory allocation (malloc) failed ... Chunk::new` during `testCompile`. The machine
had 128 GB of RAM but only 2.4 GB of free *commit*, and the JVM's default
`MaxRAMPercentage=25` reserves 32 GB. `MAVEN_OPTS=-Xmx3g` fixed it. `bootstrap-host.sh` sets
`-Xmx3g` by default for the same reason.

### A4. The configuration validates — the strongest local proof

Dropwizard's `check` command parses the configuration file, resolves every `secret://`
reference, instantiates every polymorphic factory and runs every Jakarta validation
constraint — without connecting to anything. If `staging.yml` were wrong, this is where it
would say so.

```
$ ./generate-secrets.sh ../../service/target/TextSecureServer-<version>.jar
==> 1/7  internal CA and registration-stub certificate
==> 2/7  random shared secrets
==> 3/7  throwaway RSA key for the two disabled Google integrations
==> 4/7  zero-knowledge server parameters (libsignal, via zkparams/SwarmZkParams.java)
==> 5/7  sealed-sender trust root and server certificate
==> 6/7  writing staging-secrets.yml and .env
==> 7/7  writing shared/staging-public-params.json
==> done

$ java -Dsecrets.bundle.filename=staging-secrets.yml -jar <jar> check staging.yml
INFO  [2026-09-26 17:22:40,409] io.dropwizard.core.cli.CheckCommand: Configuration is OK
```

That single line covers:

* all 34 DynamoDB table names and their expirations;
* the new `dynamoDbClient.endpointOverride`, i.e. SWARM code change 1;
* `registrationService.type: swarm-staging` resolving through the new `META-INF/services`
  registration, i.e. SWARM code change 2;
* the four Redis cluster URIs and the standalone `pubsub` URI;
* the FoundationDB cluster-file URL and the versionstamp cipher key;
* the MinIO endpoints for the CDN bucket, the paged PQ prekey bucket, the dynamic-config
  object and the ASN table;
* every disabled block — SVR2, SVRB, CDSI, key transparency, Stripe, Braintree, Google Play,
  App Store, APNs, FCM, GCP attachments, Cloudflare TURN, MobileCoin payments — parsing and
  passing validation with the placeholder values;
* environment-variable substitution, including the one-line CA PEM with `\n` escapes inside a
  double-quoted YAML scalar;
* the four zero-knowledge parameter sets being the right libsignal *types*.

It does **not** cover anything that happens at connection time. That is §B.

Getting to "Configuration is OK" took four rounds and found four real defects, each of which
would have been a confusing failure on the owner's host:

| # | Defect | Symptom it would have caused |
|---|---|---|
| 1 | Dropwizard substitutes environment variables over the **raw text** of the config, comments included. A dollar-brace example in one of my own comments was treated as a variable | server exits with `Cannot resolve variable 'VAR'` and no hint that a comment is to blame |
| 2 | The server's `zkparams` command prints base64 **without padding**; the `byte[]`/`SecretBytes` deserializer rejects it | `Incorrect type of value at: groupsZkConfig.serverPublic; is of type: String, expected: byte[]` |
| 3 | `chatZkConfig`, `callingZkConfig` and `callingZkConfigPreV101` need `GenericServerSecretParams`, a **different libsignal type** from what `zkparams` generates (300 vs 900 base64 chars for the public half). Jackson sees only base64, so `check` passes | server throws at startup, long after the configuration looked fine |
| 4 | A YAML anchor/alias for a polymorphic object is not resolved by Dropwizard's YAML mapper — it hands the alias name over as a string | `Cannot construct instance of DefaultPubSubPublisherFactory ... from String value ('disabled-pubsub')` |

Defect 3 is why `deploy/staging/zkparams/SwarmZkParams.java` exists. Its output, confirming the
two distinct types:

```
$ java -cp <jar> SwarmZkParams.java
groups          public_len=900  secret_len=3628      (zkgroup ServerSecretParams)
chat            public_len=300  secret_len=516       (GenericServerSecretParams)
calling         public_len=300  secret_len=516
callingPreV101  public_len=300  secret_len=516
```

### A5. The registration stub, live, over real TLS

The stub was run outside its container against the CA generated by `certs/make-certs.sh`, and
driven through the same four RPCs in the same order the chat server's
`RegistrationServiceClient` calls.

Fail-closed first:

```
$ unset SWARM_STAGING_FIXED_CODE; python registration_stub.py
REFUSING TO START.
The SWARM registration stub issues one fixed verification code and verifies
nothing. It is for the self-hosted staging stack only. To run it, set
  SWARM_STAGING_FIXED_CODE=true
Do not set that variable in a production profile.
exit=78
```

Then with it set:

```
$ SWARM_STAGING_FIXED_CODE=true SWARM_STUB_LISTEN=127.0.0.1:18443 \
  SWARM_STUB_TLS_CERT=certs/registration-stub.crt SWARM_STUB_TLS_KEY=certs/registration-stub.key \
  python registration_stub.py
2026-09-26 17:25:17 WARNING SWARM registration STUB listening on 127.0.0.1:18443 (TLS).
  Fixed verification code: 123456. STAGING ONLY - every phone number verifies with this one code.
```

```
$ python stub_client_proof.py certs/swarm-staging-ca.crt localhost:18443 123456
1. CreateSession(e164=15555550123)
   session_id=201995a559e2d2cf... verified=False may_check_code=False expires_in=600s
2. SendVerificationCode(transport=SMS)
   error_set=False may_check_code=True
3. CheckVerificationCode("000000")  <- deliberately wrong
   verified=False
4. CheckVerificationCode("123456")  <- the fixed staging code
   verified=True
5. GetSessionMetadata  <- the chat server re-reads the session before registering
   verified=True e164=15555550123
6. GetSessionMetadata(unknown session)
   error_type=GET_REGISTRATION_SESSION_METADATA_ERROR_TYPE_NOT_FOUND

ALL CHECKS PASSED
```

Server-side log for the same exchange:

```
CreateSession +15555550123 -> 201995a559e2d2cf
SendVerificationCode +15555550123 transport=MESSAGE_TRANSPORT_SMS -> fixed code 123456
CheckVerificationCode +15555550123 rejected (wrong code)
CheckVerificationCode +15555550123 accepted
```

The container health check script also passes against the running stub:

```
$ python healthcheck.py; echo "exit=$?"
exit=0
```

What this proves: the gRPC contract in `RegistrationService.proto` is implemented correctly,
TLS with the private CA works, a wrong code does not verify a session, the fixed code does, the
`verified` flag persists across a `GetSessionMetadata`, and an unknown session is an error and
not a crash. Those are exactly the behaviours `POST /v1/registration` depends on.

### A6. The server-side guard fails closed too

The chat server's half of the guard was exercised directly, with the shaded jar on the
classpath, in both states:

```
$ unset SWARM_STAGING_FIXED_CODE; java -cp <jar> SwarmStagingGuardProof.java certs/swarm-staging-ca.crt
SWARM_STAGING_FIXED_CODE = <unset>
RESULT: build() THREW java.lang.IllegalStateException
        registrationService type "swarm-staging" is a staging-only, no-identity-token
        registration channel and must never be used in production. To use it, set the
        environment variable SWARM_STAGING_FIXED_CODE=true. Refusing to start.
PASS: expected, the server would refuse to start

$ SWARM_STAGING_FIXED_CODE=true java -cp <jar> SwarmStagingGuardProof.java certs/swarm-staging-ca.crt
SWARM_STAGING_FIXED_CODE = "true"
RESULT: build() SUCCEEDED - a registration client was created
PASS: expected, because the variable is exactly "true"
```

`build()` is called by Dropwizard during `run()`, so an `IllegalStateException` there means the
server does not come up. Both halves of the fail-closed requirement are therefore demonstrated,
not asserted.

### A7. The compose stack resolves

```
$ docker compose config --quiet
COMPOSE CONFIG OK

$ docker compose config --services | sort
chat
dynamodb
dynamodb-bootstrap
foundationdb
foundationdb-init
minio
minio-bootstrap
redis-cache
redis-messages
redis-pubsub
redis-pushscheduler
redis-ratelimiters
registration-stub

$ docker compose config --profiles
edge

$ docker compose config --images | sort -u
amazon/aws-cli:2.31.11
amazon/dynamodb-local:3.3.1@sha256:ff89bd48ff32cd8d9be5fee8873b65b8854dc408f1afe881be6eb00247bc0dab
docker.io/bitnamilegacy/redis-cluster:7.4.3@sha256:a53d023fdfaf8a8d7ddc58da040d3494e4cb45772644618ffa44c42dcd32b9af
foundationdb/foundationdb:7.3.76
minio/mc:RELEASE.2025-08-13T08-35-41Z
minio/minio:RELEASE.2025-10-15T17-29-55Z
redis:7.4-alpine@sha256:6ab0b6e7381779332f97b8ca76193e45b0756f38d4c0dcda72dbb3c32061ab99
swarm-messenger/chat:staging
swarm-messenger/registration-stub:staging
```

`docker compose config` needs the CLI but not a daemon, so this ran. It proves the file is
valid, that all `depends_on` targets and conditions exist, that every `${…}` in it resolves
against `.env`, and that the network, volumes and static IP assignments are consistent.

Every third-party image tag was then checked for existence rather than assumed:

```
200  amazon/aws-cli:2.31.11
200  caddy:2.10-alpine
200  python:3.13-slim
200  foundationdb/foundationdb:7.3.76
200  eclipse-temurin:26-jre-resolute
200  amazon/dynamodb-local:3.3.1
200  bitnamilegacy/redis-cluster:7.4.3
200  redis:7.4-alpine
404  minio/minio:RELEASE.2025-04-22T22-12-26Z      <- I had invented this date
404  minio/mc:RELEASE.2025-04-16T18-13-26Z         <- Hub API needs auth; real, per GitHub
```

The MinIO tags were then taken from the `minio/minio` and `minio/mc` GitHub releases APIs,
which list the exact strings used as Docker tags. The compose file now pins
`minio/minio:RELEASE.2025-10-15T17-29-55Z` and `minio/mc:RELEASE.2025-08-13T08-35-41Z`, both of
which appear in those release lists. Current MinIO releases no longer ship the web console, so
`--console-address` was dropped and administration is through `mc`.

The Redis, DynamoDB Local and FoundationDB images are the ones upstream pins for its own test
suite (`pom.xml`: `dynamodb.image`, `redis.image`, `redis-cluster.image`, `foundationdb.version`),
digest and all, so the staging stack runs what upstream tests against.

### A8. Everything else parses

```
$ bash -n bootstrap-host.sh generate-secrets.sh certs/make-certs.sh \
         dynamodb/bootstrap-tables.sh foundationdb/init-foundationdb.sh
$ sh   -n minio/bootstrap-buckets.sh
ALL SHELL SCRIPTS PARSE
$ python -m py_compile registration-stub/registration_stub.py registration-stub/healthcheck.py
PYTHON COMPILES
```

A `.gitattributes` in `deploy/staging/` forces LF on every `.sh`, `.py`, `.yml`, Dockerfile and
Caddyfile, because a CRLF shebang in a bind-mounted script fails with "no such file or
directory" and that is a bad hour to give somebody.

### A9. No secret is committed

```
$ git status --short          # after generate-secrets.sh had written real values
(clean)
```

`.env`, `staging-secrets.yml`, `shared/` and `certs/*.key|crt|csr|srl|ext|pem` are all in
`deploy/staging/.gitignore`. What is committed is `staging-secrets.yml.example` and
`.env.example`, whose values are `REPLACE_ME` or placeholders for switched-off features. The
sealed-sender trust root and zk parameters produced during this session were throwaway values
for a local `check` run; the owner's host generates its own and they never leave it.

---

## B. What could not be proven here, and what the host must do

### B1. The stack was never started. There is no Linux kernel available on this machine.

This is the one substantive gap, and the reason is specific rather than general:

```
$ wsl -l -v
  NAME             STATE           VERSION
* Privacy-Zcash    Running         1

$ wsl -d Privacy-Zcash -- uname -r
4.4.0-26100-Microsoft
```

The `Privacy-Zcash` distro is **WSL version 1**, which is a syscall translation layer, not a
Linux kernel: it has no cgroups and no namespaces, so Docker Engine cannot run inside it. The
task permitted installing Docker Engine, the FoundationDB client and a JDK *in that distro*;
none of that helps, because the missing thing is the kernel.

Two ways to get one were considered and rejected:

* **Converting `Privacy-Zcash` to WSL 2.** It is the owner's Zcash/explorer environment (the
  project memory has the mainnet explorer suite running out of it). Converting a live distro is
  disruptive and destructive if it goes wrong, and it was not mine to do.
* **Docker Desktop.** Installed, but its WSL 2 distro is not registered and C: has 1.9–3.4 GB
  free. Provisioning would either fail or fill the system drive of a machine that other agents
  are working on. The workspace rules already flag Docker Desktop as unreliable here.

So the following are **unverified** and must be confirmed on the owner's host. Each has a
concrete command, and `bootstrap-host.sh` runs all of them and fails loudly:

| # | Unverified | Verify on the host with |
|---|---|---|
| B1.1 | the server starts and stays up | `docker compose up -d && curl -sf http://127.0.0.1:8081/healthcheck` |
| B1.2 | FoundationDB accepts a database and the Java binding loads `libfdb_c.so` | `docker compose exec foundationdb fdbcli --exec 'status minimal'`, then look for absence of `UnsatisfiedLinkError` in `docker compose logs chat` |
| B1.3 | the 34 DynamoDB tables are created with the right key schemas — the schemas are transcribed from the Java constants, which is careful, not proven | read the output of `docker compose logs dynamodb-bootstrap`; a wrong key schema shows up as a `ValidationException` on first use, not at create time |
| B1.4 | a single-node Bitnami Redis cluster reaches `cluster_state:ok` and Lettuce talks to it | `docker compose exec redis-cache redis-cli cluster info`. **If the single-node cluster creator refuses**, use three nodes per role with `REDIS_NODES="a b c"`, `REDIS_CLUSTER_REPLICAS=0` and `REDIS_CLUSTER_CREATOR=yes` on the third — that exact topology is what upstream's own `RedisClusterExtension` uses, so it is known to work |
| B1.5 | MinIO accepts virtual-host-style addressing at `<bucket>.minio.swarm.local` | `docker compose logs chat` must not contain `UnknownHostException`. If it does, the fallback is to add `forcePathStyle(true)` to the two `S3AsyncClient` builders in `WhisperServerService` — a third code change, avoided so far |
| B1.6 | the dynamic-config object loads, so startup does not block on the latch | `docker compose logs chat` shows `Initial request for s3://swarm-config/dynamic-config.yaml` followed by more lines |
| B1.7 | `POST /v1/verification/session` → code → `POST /v1/registration` end to end | the walk-through in `docs/STAGING.md` §7 |
| B1.8 | a message deposited to a second account | see B2 — this one is blocked on more than a kernel |
| B1.9 | Caddy obtains Let's Encrypt certificates | `docker compose --profile edge up -d caddy && curl -sI https://chat.swarm.green/v1/config` |

### B2. A real client cannot reach this server yet, for a reason that is not the server's

Even with the stack running, "two desktop clients exchange a message" is not achievable today,
and it would not have been achievable on this machine with a kernel either.

libsignal's `Net` / `ChatConnection` layer does not take a hostname. It takes an **environment**
— production or staging — and each environment carries Signal's own hostnames and its own
pinned certificate authority, compiled into the Rust library. A desktop client therefore cannot
be pointed at `chat.swarm.green` by configuration.

Two routes, in the order they become available:

1. **libsignal's loopback / local-testing environment**, which accepts a host, a port and a
   supplied trust root. Good enough for development against this staging server today.
2. **A SWARM environment in the `swarm-libsignal` fork** (Opus M-D). Hostnames under
   `swarm.green`, trust anchors being the public Web PKI roots that Let's Encrypt chains to.
   After that, clients select the SWARM environment and nothing is special.

Until (2) lands, message round-trip testing goes through HTTP tooling against the REST and
websocket endpoints, not through a shipped client. This is recorded in `docs/STAGING.md` §5a.

### B3. Registration beyond the session is not scripted

`POST /v1/registration` needs a full generated key bundle: an identity key pair, a signed
prekey, a post-quantum last-resort prekey, registration IDs for ACI and PNI, and an account
password. Hand-rolling that in a shell script would mean writing key generation by hand, which
this fork's rules forbid and which would be wrong anyway. The correct generators are
`@signalapp/libsignal-client` from npm, or the desktop client's own standalone registration
path. `docs/STAGING.md` §7 says so and stops there rather than shipping a half-correct script.

### B4. Not attempted, deliberately

* Nothing was deployed anywhere. No host was provisioned, no DNS record created, no certificate
  requested.
* No request was made to any Signal server, production or staging, at any point.
* No cryptographic primitive, protocol or key-handling path was touched. The two code changes
  are an optional AWS endpoint override and a registration-service factory that omits a Google
  Cloud bearer token; both are listed in `docs/SWARM-CHANGES.md`.
* `D:\privacy` was touched only by the mandatory vault log command.
* `D:\swarm-messenger\Signal-Desktop` and `D:\swarm-messenger\swarm-wallet-core` were not
  touched.

---

## C. Commands, in order, for anyone repeating this

```sh
# toolchain (nothing installed on the machine)
curl -sL -o jdk26.zip "https://api.adoptium.net/v3/binary/latest/26/ga/windows/x64/jdk/hotspot/normal/eclipse"

export JAVA_HOME=D:/swarm-messenger/.tools/jdk
export MAVEN_OPTS='-Xmx3g -Dmaven.repo.local=D:\swarm-messenger\.cache\m2'
export PATH="$JAVA_HOME/bin:$PATH"

# build
./mvnw -B -DskipTests package                          # thin jar only
./mvnw -B -DskipTests -Pexclude-spam-filter package    # the runnable one

# secrets, then the proof that the configuration is complete
cd deploy/staging
./generate-secrets.sh ../../service/target/TextSecureServer-<version>.jar
java -Dsecrets.bundle.filename=staging-secrets.yml -jar ../../service/target/TextSecureServer-<version>.jar \
     check staging.yml

# the stub, live
(cd zkparams && java -cp <jar> SwarmZkParams.java)
python -m grpc_tools.protoc -I registration-stub --python_out=. --grpc_python_out=. \
       registration-stub/RegistrationService.proto
SWARM_STAGING_FIXED_CODE=true python registration-stub/registration_stub.py

# the compose file
docker compose config --quiet
```
