# SWARM Messenger staging - Bigtable emulator (with data on disk) and Google's `cbt` tool.
#
# The storage service (groups + settings/contacts sync, `storage` in docker-compose.yml) speaks
# only the Cloud Bigtable API. This stack has no Google Cloud project and contacts no third party
# at runtime, so the service talks to an emulator on the compose network instead.
#
# Which emulator, and why this one:
#   * Google's own emulator (`gcloud beta emulators bigtable start`, i.e. cbtemulator from
#     google-cloud-go's bigtable/bttest) keeps every table in memory. Every group and every
#     synced setting would be lost whenever the container restarts.
#   * fullstorydev/emulators (MIT) is a fork of that same bttest code whose storage layer is
#     pluggable; with `-dir` it keeps each table in a LevelDB database on disk and reloads it
#     at start. The storage service's calls (ReadRows, MutateRow, MutateRows,
#     CheckAndMutateRow with chain/family/qualifier/value filters) are the bttest code paths.
#     This is the one used here; /data is the named volume `bigtable-data`.
#
# `cbt` (googleapis/cloud-bigtable-cbt-cli, Apache-2.0) creates the four tables: the
# `bigtable-bootstrap` one-shot runs bootstrap-tables.sh with this same image.
#
# Both are built from pinned sources on the host (the same "build once, run offline" rule as
# tus/ and registration-stub/); base images are pinned by digest.
# Runbook: docs/STAGING.md, section 5c "Storage service and groups".

FROM golang:1.26.8-alpine3.24@sha256:8ac98ca534ac3f51e1f420a1dd2c15e74c75cfa0f23f3ad27eb5d7236c349a0c AS build

ENV CGO_ENABLED=0 GOFLAGS=-trimpath

# fullstorydev/emulators, module github.com/fullstorydev/emulators/bigtable, commit 5e109b8
# (2026-04-08, the latest change under bigtable/).
RUN go install github.com/fullstorydev/emulators/bigtable/cmd/cbtemulator@5e109b853821bc614184787e15e6a1beb37dc79c

# cloud.google.com/go/cbt at googleapis/cloud-bigtable-cbt-cli fe593de (2026-08-10).
RUN go install cloud.google.com/go/cbt@v0.0.0-20260810145131-fe593de7bc1a

FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN addgroup -S bigtable && adduser -S -G bigtable bigtable \
 && mkdir -p /data && chown bigtable:bigtable /data

COPY --from=build /go/bin/cbtemulator /go/bin/cbt /usr/local/bin/

USER bigtable
EXPOSE 8086
VOLUME ["/data"]

# 0.0.0.0 inside the container only: docker-compose.yml publishes no port for this service.
ENTRYPOINT ["/usr/local/bin/cbtemulator", "-host", "0.0.0.0", "-port", "8086", "-dir", "/data"]
