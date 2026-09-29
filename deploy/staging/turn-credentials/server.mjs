// SWARM Messenger staging: TURN credentials for one-to-one calls, in Cloudflare's format.
//
// The chat server (Signal-Server) knows exactly one way to get TURN credentials: Cloudflare's
// "generate TURN credentials" API. CloudflareTurnCredentialsManager POSTs
//     {"ttl": <seconds>}
// with "Authorization: Bearer <turn.cloudflare.apiToken>" and "Content-Type: application/json"
// to turn.cloudflare.endpoint, requires HTTP 201, and reads
//     {"iceServers": {"username": "...", "credential": "..."}}
// It then hands clients (GET /v2/calling/relays) its own configured TURN URLs with that username
// and credential. The endpoint is configurable, so this service answers in exactly that shape
// and no server code changes. docs/STAGING.md, section 5d.
//
// The credentials are coturn's TURN REST ones (coturn: use-auth-secret):
//     username   = "<expiry, unix seconds>:<random>"
//     credential = base64(HMAC-SHA1(static-auth-secret, username))
// coturn recomputes the HMAC and refuses the credential after the expiry in the username.
//
// POST /credentials/generate   the one API. 201 with credentials; 401 without the right Bearer
//                              token; 400 for a body that is not {"ttl": <positive integer>};
//                              405 for any other method; ttl is capped at MAX_TTL_SECONDS.
// GET  /healthz                200 "ok" (the container health check). Everything else: 404.
//
// Node's standard library only. Configuration is the environment (loadConfig); the two secrets
// come from deploy/staging/turn.env, which coturn/make-turn-env.sh writes. Nothing secret is ever
// logged: one line per request with the status and, for a success, the ttl and expiry.

import crypto from 'node:crypto';
import http from 'node:http';
import { pathToFileURL } from 'node:url';

export const API_PATH = '/credentials/generate';
export const HEALTH_PATH = '/healthz';
// Cloudflare's own maximum (48 hours). The chat server asks for requestedCredentialTtl (PT24H).
export const MAX_TTL_SECONDS = 48 * 60 * 60;
const MAX_BODY_BYTES = 1024;

export class HttpError extends Error {
  constructor(status, message, headers = {}) {
    super(message);
    this.status = status;
    this.headers = headers;
  }
}

export function loadConfig(env = process.env) {
  const problems = [];
  const token = env.SWARM_TURN_API_TOKEN ?? '';
  const secret = env.SWARM_TURN_STATIC_AUTH_SECRET ?? '';
  if (token.length < 32) {
    problems.push('SWARM_TURN_API_TOKEN must be set (turn.cloudflare.apiToken from staging-secrets.yml, '
      + 'at least 32 characters); run coturn/make-turn-env.sh');
  }
  if (secret.length < 32) {
    problems.push('SWARM_TURN_STATIC_AUTH_SECRET must be set (at least 32 characters); '
      + 'run coturn/make-turn-env.sh');
  }
  const urls = (env.SWARM_TURN_URLS ?? '').split(',').map(u => u.trim()).filter(Boolean);
  const port = Number(env.SWARM_TURN_CREDENTIALS_PORT ?? '8080');
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    problems.push('SWARM_TURN_CREDENTIALS_PORT must be a TCP port');
  }
  if (problems.length > 0) {
    throw new Error(problems.join('; '));
  }
  return {
    token: Buffer.from(token, 'utf8'),
    secret: Buffer.from(secret, 'utf8'),
    urls,
    port,
  };
}

// coturn's TURN REST credential for one username.
export function turnCredential(secret, username) {
  return crypto.createHmac('sha1', secret).update(username, 'utf8').digest('base64');
}

export function mintCredentials(config, ttlSeconds, nowMs = Date.now()) {
  const ttl = Math.min(ttlSeconds, MAX_TTL_SECONDS);
  const expiry = Math.floor(nowMs / 1000) + ttl;
  const username = `${expiry}:${crypto.randomBytes(12).toString('base64url')}`;
  return {
    ttl,
    expiry,
    body: {
      iceServers: {
        urls: config.urls,
        username,
        credential: turnCredential(config.secret, username),
      },
    },
  };
}

function bearerMatches(config, header) {
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) {
    return false;
  }
  const presented = Buffer.from(header.slice('Bearer '.length).trim(), 'utf8');
  // Compare digests, so the comparison takes the same time whatever the presented length.
  const a = crypto.createHash('sha256').update(presented).digest();
  const b = crypto.createHash('sha256').update(config.token).digest();
  return crypto.timingSafeEqual(a, b) && presented.length === config.token.length;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new HttpError(413, 'request body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

export function parseTtl(text) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new HttpError(400, 'body is not JSON');
  }
  const ttl = parsed?.ttl;
  if (!Number.isSafeInteger(ttl) || ttl <= 0) {
    throw new HttpError(400, 'body must be {"ttl": <positive integer seconds>}');
  }
  return ttl;
}

export function createServer(config, log = line => process.stdout.write(`${line}\n`)) {
  return http.createServer(async (req, res) => {
    const started = new Date().toISOString();
    const path = (req.url ?? '').split('?')[0];
    let status = 500;
    let note = '';
    try {
      if (path === HEALTH_PATH && (req.method === 'GET' || req.method === 'HEAD')) {
        status = 200;
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('ok');
        return;
      }
      if (path !== API_PATH) {
        throw new HttpError(404, 'not found');
      }
      if (req.method !== 'POST') {
        throw new HttpError(405, 'method not allowed', { Allow: 'POST' });
      }
      if (!bearerMatches(config, req.headers.authorization)) {
        throw new HttpError(401, 'unauthorized', { 'WWW-Authenticate': 'Bearer' });
      }
      const ttl = parseTtl(await readBody(req));
      const minted = mintCredentials(config, ttl);
      status = 201;
      note = ` ttl=${minted.ttl}${minted.ttl < ttl ? ` (asked ${ttl})` : ''} expires=${new Date(minted.expiry * 1000).toISOString()}`;
      res.writeHead(201, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(minted.body));
    } catch (error) {
      status = error instanceof HttpError ? error.status : 500;
      note = ` ${error instanceof HttpError ? error.message : 'internal error'}`;
      if (!res.headersSent) {
        res.writeHead(status, {
          'Content-Type': 'application/json',
          ...(error instanceof HttpError ? error.headers : {}),
        });
        res.end(JSON.stringify({ success: false, errors: [{ code: status, message: note.trim() }] }));
      }
    } finally {
      if (path !== HEALTH_PATH) {
        log(`${started} ${req.method} ${path} ${status}${note}`);
      }
    }
  });
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  let config;
  try {
    config = loadConfig();
  } catch (error) {
    process.stderr.write(`turn-credentials: ${error.message}\n`);
    process.exit(78);
  }
  const server = createServer(config);
  server.listen(config.port, '0.0.0.0', () => {
    process.stdout.write(`turn-credentials: listening on :${config.port}, ${API_PATH}, `
      + `max ttl ${MAX_TTL_SECONDS} s, ${config.urls.length} TURN URL(s) in answers\n`);
  });
  const stop = () => server.close(() => process.exit(0));
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}
