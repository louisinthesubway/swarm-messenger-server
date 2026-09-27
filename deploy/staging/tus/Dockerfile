# SWARM Messenger staging: the CDN3 (TUS) upload service. See server.mjs and docs/STAGING.md,
# section 8a. Node's standard library only, so there is no install step and nothing to fetch
# beyond this base image (the multi-arch index digest of node:22-alpine on 2026-09-27).
FROM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402

WORKDIR /app
COPY server.mjs /app/server.mjs

# In-progress uploads are staged here (the tus-data volume). A new named volume copies this
# directory's ownership, so the unprivileged user can write to it.
RUN mkdir -p /data && chown node:node /data

USER node
ENV NODE_ENV=production \
    TUS_DATA_DIR=/data \
    TUS_PORT=1080
EXPOSE 1080

CMD ["node", "/app/server.mjs"]
