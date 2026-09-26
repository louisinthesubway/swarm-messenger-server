# SWARM Messenger — staging chat server image.
#
# Build context is the repository root:
#   docker compose -f deploy/staging/docker-compose.yml build chat
#
# The jar must exist before the image is built:
#   ./mvnw -DskipTests -Pexclude-spam-filter package
#
# `-Pexclude-spam-filter` is what produces the shaded, runnable jar and downloads the matching
# FoundationDB client library into service/target/jib-extra/usr/lib/libfdb_c.so. Without the
# profile Maven builds only the thin jar (the profile is declared without an <activation>
# block in service/pom.xml, so nothing activates it implicitly). The spam-filter submodule is
# a private Signal module that is not part of this fork.
#
# Base image and JVM flags mirror service/pom.xml's jib configuration, so the container the
# owner runs behaves like the one upstream builds.

FROM eclipse-temurin:26-jre-resolute

# The FoundationDB Java binding loads libfdb_c at runtime; the version must match the
# FoundationDB server (7.3.76, pinned in pom.xml as foundationdb.version).
COPY service/target/jib-extra/usr/lib/libfdb_c.so /usr/lib/libfdb_c.so

COPY service/target/TextSecureServer-*.jar /opt/swarm/chat.jar

WORKDIR /opt/swarm

# Dropwizard reads the secrets bundle through this system property before it parses the main
# configuration file, so it cannot be a configuration key.
ENV SECRETS_BUNDLE=/config/staging-secrets.yml

EXPOSE 8080 8081 50051

# `exec` so the JVM is PID 1 and receives SIGTERM directly.
ENTRYPOINT ["/bin/sh", "-c", "exec java \
  -Dsecrets.bundle.filename=\"$SECRETS_BUNDLE\" \
  -XX:+UseCompactObjectHeaders \
  -Djdk.nio.maxCachedBufferSize=262144 \
  -Djdk.tls.server.newSessionTicketCount=0 \
  -jar /opt/swarm/chat.jar server /config/staging.yml"]
