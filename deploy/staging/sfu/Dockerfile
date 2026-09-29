# SWARM Messenger staging: Signal's calling service, the server for GROUP calls (an SFU).
# docs/STAGING.md, section 5d.
#
# Source: https://github.com/louisinthesubway/swarm-calling-service, a fork of
# signalapp/Signal-Calling-Service (AGPL-3.0-only), at the commit pinned below: upstream v141
# (56da39e) plus one change, listed in that repository's docs/SWARM-CHANGES.md (the frontend may
# read its two secrets from the environment instead of its command line). No other change.
#
# One build stage compiles both programs; each runtime stage carries one of them:
#   calling_backend   target `backend`   the media server: ICE/SRTP on UDP (and TCP) 10000,
#                                        its signaling API on 8080 for the frontend only
#   calling_frontend  target `frontend`  the HTTPS API the clients call (behind Caddy at
#                                        sfu.chat.swarm.green): checks group-call tokens, keeps
#                                        call records in DynamoDB, assigns calls to the backend
# docker-compose.yml builds the two targets as the services calling-backend and calling-frontend;
# the second build reuses the first one's build stage from the cache.
#
# Upstream's own Dockerfiles install the toolchain with rustup at build time and ship curl and jq
# for Google Cloud metadata lookups. Here the toolchain comes from the official image of exactly the
# version in the source's rust-toolchain file (1.97.1), both base images are pinned by digest (the
# multi-arch index digests of 2026-09-29), and the runtime images carry the program and nothing
# else. Build time on the chat host (6 vCPU): see docs/STAGING.md, 5d.

FROM rust:1.97.1-trixie@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f AS build

ARG CALLING_REPO=https://github.com/louisinthesubway/swarm-calling-service.git
ARG CALLING_COMMIT=61e5d4085c04ae03a8afaa90e28843ca52dc1149
# The chat stack shares this host's CPUs, so the compiler gets four of the six. The release
# profile's fat LTO (codegen-units = 1) runs single-threaded at the end of each link anyway.
ARG CARGO_BUILD_JOBS=4

# protoc: the backend's build.rs compiles its protobuf definitions.
RUN apt-get update \
    && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Exactly the pinned commit, verified; nothing from the build context.
RUN git init -q . \
    && git remote add origin "${CALLING_REPO}" \
    && git fetch -q --depth 1 origin "${CALLING_COMMIT}" \
    && git checkout -q --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${CALLING_COMMIT}" \
    && echo "calling service source: ${CALLING_REPO} @ $(git rev-parse HEAD)"

# --locked: exactly the dependency versions in the source's Cargo.lock (libsignal's zkgroup comes
# from its git tag v0.101.0, pinned there by commit). No RUSTFLAGS target-cpu: a portable x86-64
# build.
RUN cargo build --release --locked -j "${CARGO_BUILD_JOBS}" \
        --bin calling_backend --bin calling_frontend \
    && mkdir -p /out \
    && cp target/release/calling_backend target/release/calling_frontend /out/ \
    && git rev-parse HEAD > /out/SOURCE_COMMIT

# ---------------------------------------------------------------------------------------- backend
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS backend
COPY --from=build /out/calling_backend /usr/local/bin/calling_backend
COPY --from=build /out/SOURCE_COMMIT /usr/local/share/calling-service/SOURCE_COMMIT
USER nobody:nogroup
# 8080: signaling API for the frontend (compose network only). 10000/udp and 10000/tcp: media.
EXPOSE 8080 10000/udp 10000/tcp
ENTRYPOINT ["/usr/local/bin/calling_backend"]

# --------------------------------------------------------------------------------------- frontend
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS frontend
COPY --from=build /out/calling_frontend /usr/local/bin/calling_frontend
COPY --from=build /out/SOURCE_COMMIT /usr/local/share/calling-service/SOURCE_COMMIT
USER nobody:nogroup
# 8080: the client API (Caddy proxies sfu.chat.swarm.green to it). 8100: the internal API the
# backend calls (call-link approvals, removing ended calls). Neither is published on the host.
EXPOSE 8080 8100
ENTRYPOINT ["/usr/local/bin/calling_frontend"]
