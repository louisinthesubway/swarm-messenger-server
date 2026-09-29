# SWARM Messenger staging - the storage service image (groups + settings/contacts sync).
#
# The service is github.com/louisinthesubway/swarm-storage-service (branch swarm-main), a fork of
# signalapp/storage-service (AGPL-3.0-only) whose only changes are listed in its
# docs/SWARM-CHANGES.md. The build context is THIS directory, and the only things copied in come
# from build/, which prepare-image.sh fills from a built checkout of that repository:
#
#   git clone https://github.com/louisinthesubway/swarm-storage-service /opt/swarm/swarm-storage-service
#   (cd /opt/swarm/swarm-storage-service && ./mvnw -B -DskipTests package)    # JDK 25 or newer
#   ./storage/prepare-image.sh /opt/swarm/swarm-storage-service
#   docker compose build storage
#
# The base image (digest included) and the JVM flags mirror the jib configuration in the fork's
# pom.xml (docker.image, <jvmFlags>, <args>, and since the FoundationDB backend its
# <extraDirectories> target/jib-extra), so this container runs the service the way upstream's own
# image does. Two differences: the heap limit is set in docker-compose.yml (JAVA_TOOL_OPTIONS)
# instead of jib's -Xmx8192m, which is sized for Signal's production, and the configuration file
# is /config/storage.yml, mounted from deploy/staging/storage.yml.

FROM eclipse-temurin:25-jre-resolute@sha256:17ddcc32b1f296155738c4b2f689208e46bf0cf4eb0b215c717717deb8b74b90

# The FoundationDB backend (storage.backend: foundationdb in storage.yml): the Java binding loads
# libfdb_c at runtime, and its version must match the FoundationDB server (7.3.76). The fork's build
# downloads it with the SHA-256 swarm-messenger-server's pom.xml pins for the chat image, and
# prepare-image.sh checks that checksum again. Same place as in the chat image (../Dockerfile).
COPY build/libfdb_c.so /usr/lib/libfdb_c.so

COPY build/lib/ /opt/swarm/storage/lib/
COPY build/storage-service.jar /opt/swarm/storage/storage-service.jar

WORKDIR /opt/swarm/storage

# 8080: the API (Caddy sends /v1/storage* and /v2/groups* here; the chat server sends its
# account-deletion DELETE /v1/storage). 8081: Dropwizard admin. Neither is published on the host.
EXPOSE 8080 8081

# Exec form: the JVM is PID 1 and gets SIGTERM directly. The launcher, not a shell, expands lib/*.
# The Dropwizard command and the config file are the CMD, so a one-off container can run another
# command of the service, e.g. the migration (docs/STAGING.md, section 5c):
#   docker compose run --rm --no-deps storage migrate-bigtable-to-foundationdb /config/storage.yml
ENTRYPOINT ["java", "-server", "-Djava.awt.headless=true", "-Xss512k", "-XX:+HeapDumpOnOutOfMemoryError", \
  "-cp", "/opt/swarm/storage/storage-service.jar:/opt/swarm/storage/lib/*", \
  "org.signal.storageservice.StorageService"]
CMD ["server", "/config/storage.yml"]
