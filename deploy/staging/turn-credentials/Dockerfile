# SWARM Messenger staging: TURN credentials for one-to-one calls, in the shape the chat server's
# Cloudflare TURN client expects. See server.mjs and docs/STAGING.md, section 5d. Node's standard
# library only, so there is no install step; the base image is the same pinned one as ../tus
# (the multi-arch index digest of node:22-alpine on 2026-09-27).
FROM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402

WORKDIR /app
COPY server.mjs /app/server.mjs

USER node
ENV NODE_ENV=production \
    SWARM_TURN_CREDENTIALS_PORT=8080
EXPOSE 8080

CMD ["node", "/app/server.mjs"]
