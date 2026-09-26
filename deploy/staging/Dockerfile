# SWARM Messenger — staging chat server image.
#
# The build context is THIS directory, and the only things copied in come from build/, which
# prepare-image.sh fills with exactly two files. See prepare-image.sh for why that indirection
# exists rather than a wildcard COPY from service/target.
#
#   ./mvnw -DskipTests -Pexclude-spam-filter package    # from the repository root
#   cd deploy/staging && ./prepare-image.sh
#   docker compose build chat
#
# `-Pexclude-spam-filter` is upstream's profile, and it is what produces the shaded runnable jar
# and downloads the matching FoundationDB client library. It has no <activation> block in
# service/pom.xml, so nothing enables it implicitly; it must be named. (The spam-filter
# submodule is a private Signal module and is not part of this fork.)
#
# The base image and the JVM flags mirror service/pom.xml's jib configuration, so the container
# the owner runs behaves like the one upstream builds.

FROM eclipse-temurin:26-jre-resolute

# The FoundationDB Java binding loads libfdb_c at runtime and its version must match the
# FoundationDB server (7.3.76, pinned in pom.xml as foundationdb.version).
COPY build/libfdb_c.so /usr/lib/libfdb_c.so

COPY build/chat.jar /opt/swarm/chat.jar

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
