// SWARM Messenger staging: the CDN3 (TUS) upload service for message attachments.
//
// Contract: docs/STAGING.md, section 8a ("Attachments and avatars"). In short: the chat server
// hands a client an upload form with a key, an HS256 JWT (aud "attachments", sub = the key,
// maxLen = the most bytes it may write) and signedUploadLocation https://<cdn>/upload/attachments.
// The client POSTs the ciphertext there (TUS 1.0.0 creation-with-upload) and, only if that
// connection breaks, asks HEAD <location>/<key> for the offset and PATCHes the rest.
//
// This service checks the token on every POST, HEAD and PATCH, stages the bytes on local disk
// and, when the last byte has arrived, writes the object to MinIO at attachments/<key> with one
// SigV4 PutObject BEFORE it answers, so a success means the recipient can download it. Reads
// never come here: Caddy sends GET /attachments/<key> straight to MinIO.
//
// It follows Signal's own tus-server (github.com/signalapp/tus-server, a Cloudflare worker): the
// same paths, the same token checks and 7-day token age, the same status codes. Everything it
// receives is already end-to-end-encrypted ciphertext; it never sees an attachment key.
//
// Node's standard library only. Configuration is environment variables (loadConfig below); the
// two secrets come from deploy/staging/tus.env, which make-tus-env.sh writes.

import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export const TUS_VERSION = '1.0.0';
export const NAMESPACE = 'attachments';
const COLLECTION_PATH = `/upload/${NAMESPACE}`;
const OFFSET_OCTET_STREAM = 'application/offset+octet-stream';
const CHECKSUM_HEADER = 'x-signal-checksum-sha256';
// Keys made by the chat server are 20 characters of base64url (AttachmentUtil). Anything that
// could name another file or directory is refused before it gets near the filesystem.
const KEY_PATTERN = /^[A-Za-z0-9_-]{8,128}$/;
const CLOCK_SKEW_SECONDS = 60;
const EMPTY_SHA256_HEX = crypto.createHash('sha256').update('').digest('hex');
const PROBE_KEY = `${NAMESPACE}/.swarm-tus-probe`;

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

class StorageError extends Error {}

// ------------------------------------------------------------------------------ configuration

export function loadConfig(env = process.env) {
  const problems = [];
  const required = (name) => {
    const value = env[name];
    if (value === undefined || value === '') {
      problems.push(`${name} is not set`);
    }
    return value;
  };
  const positiveInt = (name, fallback) => {
    const raw = env[name];
    if (raw === undefined || raw === '') {
      return fallback;
    }
    const n = Number(raw);
    if (!Number.isSafeInteger(n) || n <= 0) {
      problems.push(`${name} must be a positive integer`);
      return fallback;
    }
    return n;
  };

  const secretBase64 = required('SWARM_TUS_TOKEN_SECRET');
  let tokenSecret;
  if (secretBase64) {
    tokenSecret = Buffer.from(secretBase64, 'base64');
    if (tokenSecret.length !== 32) {
      problems.push('SWARM_TUS_TOKEN_SECRET must be the base64 of exactly 32 bytes '
        + '(the value of tus.userAuthenticationTokenSharedSecret in staging-secrets.yml)');
    }
  }

  const publicUploadUri = required('TUS_PUBLIC_UPLOAD_URI');
  const config = {
    port: positiveInt('TUS_PORT', 1080),
    publicUploadUri: publicUploadUri ? publicUploadUri.replace(/\/+$/, '') : undefined,
    tokenSecret,
    maxTokenAgeSeconds: positiveInt('TUS_MAX_TOKEN_AGE_SECONDS', 7 * 24 * 3600),
    maxUploadBytes: positiveInt('TUS_MAX_UPLOAD_BYTES', 100 * 1024 * 1024),
    uploadExpirySeconds: positiveInt('TUS_UPLOAD_EXPIRY_SECONDS', 7 * 24 * 3600),
    dataDir: env.TUS_DATA_DIR || '/data',
    s3: {
      endpoint: env.TUS_S3_ENDPOINT || 'http://minio:9000',
      bucket: env.TUS_S3_BUCKET || 'swarm-cdn',
      region: env.TUS_S3_REGION || 'us-east-1',
      accessKey: required('SWARM_TUS_S3_ACCESS_KEY'),
      secretKey: required('SWARM_TUS_S3_SECRET_KEY'),
    },
  };
  if (problems.length > 0) {
    throw new Error(problems.join('; '));
  }
  return config;
}

// ------------------------------------------------------------------------------ S3 (MinIO)

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function hmac(key, data) {
  return crypto.createHmac('sha256', key).update(data).digest();
}

// RFC 3986 unreserved characters stay as they are; everything else becomes %XX. The caller
// keeps the '/' between path segments.
export function awsUriEncode(segment) {
  return encodeURIComponent(segment)
    .replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

export function amzDate(date) {
  return date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
}

// AWS Signature Version 4, signed headers, as S3 and MinIO expect it.
export function signV4({
  method, canonicalUri, canonicalQuery = '', headers, payloadHash,
  accessKey, secretKey, region, service = 's3', date,
}) {
  const stamp = amzDate(date);
  const day = stamp.slice(0, 8);
  const lower = {};
  for (const [name, value] of Object.entries(headers)) {
    lower[name.toLowerCase()] = String(value).trim().replace(/\s+/g, ' ');
  }
  const names = Object.keys(lower).sort();
  const canonicalHeaders = names.map((n) => `${n}:${lower[n]}\n`).join('');
  const signedHeaders = names.join(';');
  const canonicalRequest = [method, canonicalUri, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
    .join('\n');
  const scope = `${day}/${region}/${service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', stamp, scope, sha256Hex(canonicalRequest)].join('\n');
  const signingKey = hmac(hmac(hmac(hmac(`AWS4${secretKey}`, day), region), service), 'aws4_request');
  const signature = crypto.createHmac('sha256', signingKey).update(stringToSign).digest('hex');
  return {
    signature,
    signedHeaders,
    authorization: `AWS4-HMAC-SHA256 Credential=${accessKey}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  };
}

function s3ErrorCode(body) {
  const match = /<Code>([^<]+)<\/Code>/.exec(body || '');
  return match ? match[1] : 'no error code';
}

export function createS3Client({ endpoint, bucket, region, accessKey, secretKey, timeoutMs = 120_000 }) {
  const base = new URL(endpoint);
  const transport = base.protocol === 'https:' ? https : http;
  const objectUri = (objectKey) => `/${awsUriEncode(bucket)}/${objectKey.split('/').map(awsUriEncode).join('/')}`;

  function request(method, objectKey, { payloadHash = EMPTY_SHA256_HEX, headers = {}, body } = {}) {
    const uri = objectUri(objectKey);
    const now = new Date();
    // Path-style addressing: the Host is the endpoint itself, never <bucket>.<endpoint>.
    const signed = { host: base.host, 'x-amz-content-sha256': payloadHash, 'x-amz-date': amzDate(now) };
    const { authorization } = signV4({
      method, canonicalUri: uri, headers: signed, payloadHash, accessKey, secretKey, region, date: now,
    });
    return new Promise((resolve, reject) => {
      const req = transport.request({
        hostname: base.hostname,
        port: base.port || (base.protocol === 'https:' ? 443 : 80),
        method,
        path: uri,
        headers: { ...headers, ...signed, authorization },
        timeout: timeoutMs,
      }, (res) => {
        let text = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          if (text.length < 4096) {
            text += chunk;
          }
        });
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: text }));
        res.on('error', reject);
      });
      req.on('timeout', () => req.destroy(new Error(`S3 ${method} timed out`)));
      req.on('error', reject);
      if (body) {
        body.on('error', (err) => req.destroy(err));
        body.pipe(req);
      } else {
        req.end();
      }
    });
  }

  return {
    async putFile(objectKey, filePath, size, sha256hex) {
      const res = await request('PUT', objectKey, {
        payloadHash: sha256hex,
        headers: { 'content-length': String(size), 'content-type': 'application/octet-stream' },
        body: fs.createReadStream(filePath),
      });
      if (res.status !== 200) {
        throw new Error(`S3 PUT answered ${res.status} (${s3ErrorCode(res.body)})`);
      }
    },
    async headObject(objectKey) {
      const res = await request('HEAD', objectKey);
      if (res.status === 200) {
        return { size: Number(res.headers['content-length']) };
      }
      if (res.status === 404) {
        return null;
      }
      throw new Error(`S3 HEAD answered ${res.status}`);
    },
  };
}

// ------------------------------------------------------------------------------ token

function decodeJsonPart(part) {
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
}

// The chat server's JwtGenerator: HS256, aud "attachments", sub = key, iat, maxLen. No exp; the
// age limit is ours (Signal's tus-server uses the same 7 days).
export function verifyToken(authorization, secret, { audience, maxAgeSeconds, nowSeconds }) {
  if (!authorization) {
    throw new HttpError(401, 'missing credentials');
  }
  if (!authorization.startsWith('Bearer ')) {
    throw new HttpError(400, 'invalid auth format');
  }
  const parts = authorization.slice('Bearer '.length).trim().split('.');
  if (parts.length !== 3 || parts[2] === '') {
    throw new HttpError(401, 'invalid credentials');
  }
  let header;
  let payload;
  try {
    header = decodeJsonPart(parts[0]);
    payload = decodeJsonPart(parts[1]);
  } catch {
    throw new HttpError(401, 'invalid credentials');
  }
  if (header === null || typeof header !== 'object' || header.alg !== 'HS256' || header.crit !== undefined) {
    throw new HttpError(401, 'invalid credentials');
  }
  const expected = crypto.createHmac('sha256', secret).update(`${parts[0]}.${parts[1]}`).digest();
  const given = Buffer.from(parts[2], 'base64url');
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) {
    throw new HttpError(401, 'invalid credentials');
  }
  if (payload === null || typeof payload !== 'object') {
    throw new HttpError(401, 'invalid credentials');
  }
  const { aud, iat, exp, nbf, sub, maxLen } = payload;
  if (!(aud === audience || (Array.isArray(aud) && aud.includes(audience)))) {
    throw new HttpError(401, 'invalid credentials');
  }
  if (typeof iat !== 'number' || !Number.isFinite(iat) || iat > nowSeconds + CLOCK_SKEW_SECONDS) {
    throw new HttpError(401, 'invalid credentials');
  }
  if (nowSeconds - iat > maxAgeSeconds) {
    throw new HttpError(401, 'credentials expired');
  }
  if (exp !== undefined && (typeof exp !== 'number' || exp <= nowSeconds - CLOCK_SKEW_SECONDS)) {
    throw new HttpError(401, 'credentials expired');
  }
  if (nbf !== undefined && (typeof nbf !== 'number' || nbf > nowSeconds + CLOCK_SKEW_SECONDS)) {
    throw new HttpError(401, 'invalid credentials');
  }
  if (typeof sub !== 'string' || sub === '') {
    throw new HttpError(401, 'invalid credentials');
  }
  if (typeof maxLen !== 'number' || !Number.isSafeInteger(maxLen) || maxLen < 0) {
    throw new HttpError(401, 'invalid credentials');
  }
  return { sub, maxLen };
}

// ------------------------------------------------------------------------------ TUS headers

// "Upload-Metadata: key base64value,key base64value". Only `filename` matters: it is the key.
export function parseUploadMetadata(value) {
  const out = {};
  if (value === undefined) {
    return out;
  }
  for (const pair of String(value).split(',')) {
    const [name, encoded] = pair.trim().split(' ', 2);
    if (!name) {
      throw new HttpError(400, 'upload-metadata entries must have keys');
    }
    if (encoded === undefined) {
      continue;
    }
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
      throw new HttpError(400, 'upload metadata must be base64 encoded');
    }
    if (name === 'filename') {
      out.filename = Buffer.from(encoded, 'base64').toString('utf8');
    }
  }
  return out;
}

function parseLength(value) {
  if (value === undefined) {
    return undefined;
  }
  if (!/^\d{1,16}$/.test(value)) {
    return NaN;
  }
  const n = Number(value);
  return Number.isSafeInteger(n) ? n : NaN;
}

function parseChecksum(value) {
  if (value === undefined) {
    return undefined;
  }
  const bytes = /^[A-Za-z0-9+/]*={0,2}$/.test(value) ? Buffer.from(value, 'base64') : null;
  if (bytes === null || bytes.length !== 32) {
    throw new HttpError(400, 'X-Signal-Checksum-Sha256 must be the base64 of 32 bytes');
  }
  return bytes.toString('base64');
}

function hasRequestBody(req) {
  const length = req.headers['content-length'];
  if (length !== undefined) {
    return Number(length) > 0;
  }
  return req.headers['transfer-encoding'] !== undefined;
}

function redact(key) {
  return key ? `${key.slice(0, 4)}…` : '-';
}

// ------------------------------------------------------------------------------ staging area

// An upload in progress is two files in the data directory: <key>.json (what the client
// declared) and <key>.bin (the bytes so far; its size is the upload offset). Both go away when
// the object is in MinIO, when the upload fails for good, or when it expires.
function createStore(dataDir) {
  const metaPath = (key) => path.join(dataDir, `${key}.json`);
  const dataPath = (key) => path.join(dataDir, `${key}.bin`);

  async function remove(key) {
    await Promise.all([
      fsp.rm(metaPath(key), { force: true }),
      fsp.rm(dataPath(key), { force: true }),
    ]);
  }

  return {
    dataPath,
    remove,
    async read(key) {
      let meta;
      try {
        meta = JSON.parse(await fsp.readFile(metaPath(key), 'utf8'));
      } catch (err) {
        if (err.code === 'ENOENT') {
          return null;
        }
        throw err;
      }
      try {
        const { size } = await fsp.stat(dataPath(key));
        return { ...meta, offset: size };
      } catch (err) {
        if (err.code === 'ENOENT') {
          await remove(key);
          return null;
        }
        throw err;
      }
    },
    async create(key, meta) {
      await fsp.writeFile(dataPath(key), Buffer.alloc(0));
      await fsp.writeFile(`${metaPath(key)}.tmp`, JSON.stringify(meta));
      await fsp.rename(`${metaPath(key)}.tmp`, metaPath(key));
    },
    async sweep(nowMs) {
      let removed = 0;
      const names = await fsp.readdir(dataDir);
      for (const name of names) {
        const full = path.join(dataDir, name);
        if (name.endsWith('.json')) {
          try {
            const meta = JSON.parse(await fsp.readFile(full, 'utf8'));
            if (!(meta.expiresAt > nowMs)) {
              await remove(name.slice(0, -'.json'.length));
              removed += 1;
            }
          } catch {
            await fsp.rm(full, { force: true });
          }
        } else if (name.endsWith('.bin') || name.endsWith('.json.tmp')) {
          const base = name.endsWith('.bin') ? name.slice(0, -'.bin'.length) : null;
          const orphan = base === null || !names.includes(`${base}.json`);
          if (orphan) {
            const { mtimeMs } = await fsp.stat(full).catch(() => ({ mtimeMs: nowMs }));
            if (nowMs - mtimeMs > 3600_000) {
              await fsp.rm(full, { force: true });
              removed += 1;
            }
          }
        }
      }
      return removed;
    },
  };
}

// ------------------------------------------------------------------------------ the service

export function createTusService(config, {
  s3, now = () => Date.now(), log = (line) => console.log(`[tus] ${line}`),
} = {}) {
  const store = createStore(config.dataDir);
  const locks = new Map();
  const storageHealth = { ok: false, detail: 'not probed yet' };
  const timers = [];

  // One request at a time per key, in arrival order, like Signal's per-upload durable object.
  async function withLock(key, fn) {
    const previous = locks.get(key) || Promise.resolve();
    let release;
    const mine = new Promise((resolve) => {
      release = resolve;
    });
    const tail = previous.then(() => mine);
    locks.set(key, tail);
    await previous;
    try {
      return await fn();
    } finally {
      release();
      if (locks.get(key) === tail) {
        locks.delete(key);
      }
    }
  }

  function authorize(req, key) {
    const claims = verifyToken(req.headers.authorization, config.tokenSecret, {
      audience: NAMESPACE,
      maxAgeSeconds: config.maxTokenAgeSeconds,
      nowSeconds: Math.floor(now() / 1000),
    });
    if (claims.sub !== key) {
      throw new HttpError(401, 'credentials are for another upload');
    }
    if (!KEY_PATTERN.test(key)) {
      throw new HttpError(400, 'bad upload key');
    }
    return claims;
  }

  function requireTusResumable(req) {
    if (req.headers['tus-resumable'] !== TUS_VERSION) {
      throw new HttpError(412, `Tus-Resumable ${TUS_VERSION} required`);
    }
  }

  function expiresHeader(meta) {
    return new Date(meta.expiresAt).toUTCString();
  }

  // Appends the request body to the staged file. A body that stops early (the client went away)
  // keeps what arrived: that is what HEAD reports and where PATCH resumes. A body that runs past
  // Upload-Length discards the upload, as upstream does.
  async function appendBody(req, key, offset, uploadLength) {
    const handle = await fsp.open(store.dataPath(key), 'a');
    let written = offset;
    try {
      for await (const chunk of req) {
        if (written + chunk.length > uploadLength) {
          throw new HttpError(413, 'body exceeds Upload-Length');
        }
        try {
          await handle.write(chunk);
        } catch (err) {
          throw new StorageError(`staging write failed: ${err.message}`);
        }
        written += chunk.length;
      }
    } catch (err) {
      if (err instanceof HttpError) {
        await handle.close();
        await store.remove(key);
        throw err;
      }
      if (err instanceof StorageError) {
        await handle.close();
        log(`${redact(key)} ${err.message}`);
        throw new HttpError(500, 'could not stage the upload');
      }
      log(`${redact(key)} body ended early at ${written} bytes (${err.code || err.message})`);
    }
    await handle.close().catch(() => {});
    return written;
  }

  // The last byte is in: hash the staged file, write it to MinIO, then forget it.
  async function finalize(key, meta) {
    const file = store.dataPath(key);
    const hash = crypto.createHash('sha256');
    for await (const chunk of fs.createReadStream(file)) {
      hash.update(chunk);
    }
    const digest = hash.digest();
    if (meta.checksum && !Buffer.from(meta.checksum, 'base64').equals(digest)) {
      await store.remove(key);
      throw new HttpError(415, 'the X-Signal-Checksum-Sha256 did not match the uploaded bytes');
    }
    try {
      await s3.putFile(`${NAMESPACE}/${key}`, file, meta.uploadLength, digest.toString('hex'));
    } catch (err) {
      log(`${redact(key)} storage write failed: ${err.message}`);
      throw new HttpError(500, 'storage write failed');
    }
    await store.remove(key);
    log(`${redact(key)} stored ${meta.uploadLength} bytes at ${NAMESPACE}/`);
  }

  async function create(req, res) {
    requireTusResumable(req);
    // Authenticate before looking at anything else the client sent.
    const claims = verifyToken(req.headers.authorization, config.tokenSecret, {
      audience: NAMESPACE,
      maxAgeSeconds: config.maxTokenAgeSeconds,
      nowSeconds: Math.floor(now() / 1000),
    });
    const key = parseUploadMetadata(req.headers['upload-metadata']).filename;
    if (key === undefined) {
      throw new HttpError(400, 'bad filename metadata');
    }
    if (claims.sub !== key) {
      throw new HttpError(401, 'credentials are for another upload');
    }
    if (!KEY_PATTERN.test(key)) {
      throw new HttpError(400, 'bad upload key');
    }
    res.locals.key = key;

    const contentType = req.headers['content-type'];
    if (contentType !== undefined && contentType !== OFFSET_OCTET_STREAM) {
      throw new HttpError(415, `create only supports ${OFFSET_OCTET_STREAM}`);
    }
    const withBody = hasRequestBody(req);
    if (withBody && contentType === undefined) {
      throw new HttpError(415, `a body requires Content-Type: ${OFFSET_OCTET_STREAM}`);
    }
    if (req.headers['upload-defer-length'] !== undefined) {
      throw new HttpError(400, 'Upload-Defer-Length is not supported');
    }
    const uploadLength = parseLength(req.headers['upload-length']);
    if (uploadLength === undefined || Number.isNaN(uploadLength)) {
      throw new HttpError(400, 'must contain Upload-Length header');
    }
    if (uploadLength > claims.maxLen || uploadLength > config.maxUploadBytes) {
      throw new HttpError(413, 'Upload-Length exceeds maximum upload size');
    }
    const checksum = parseChecksum(req.headers[CHECKSUM_HEADER]);

    await withLock(key, async () => {
      const existing = await store.read(key);
      if (existing && existing.offset > 0) {
        await store.remove(key);
        throw new HttpError(409, 'object already exists');
      }
      const meta = {
        uploadLength,
        checksum,
        createdAt: now(),
        expiresAt: now() + config.uploadExpirySeconds * 1000,
      };
      await store.create(key, meta);
      const offset = withBody ? await appendBody(req, key, 0, uploadLength) : 0;
      if (offset === uploadLength) {
        await finalize(key, meta);
      }
      res.locals.bytes = offset;
      reply(res, 201, {
        Location: `${config.publicUploadUri}/${NAMESPACE}/${key}`,
        'Upload-Offset': String(offset),
        'Upload-Expires': expiresHeader(meta),
      });
    });
  }

  async function head(req, res, key) {
    requireTusResumable(req);
    authorize(req, key);
    await withLock(key, async () => {
      const state = await store.read(key);
      if (state) {
        if (state.offset === state.uploadLength) {
          // Every byte is here but the write to MinIO failed earlier: try it again now, so the
          // client never hears "complete" for an object nobody can download.
          await finalize(key, state);
        }
        reply(res, 200, {
          'Upload-Offset': String(state.offset),
          'Upload-Length': String(state.uploadLength),
          'Upload-Expires': expiresHeader(state),
          'Cache-Control': 'no-store',
        });
        return;
      }
      let stored;
      try {
        stored = await s3.headObject(`${NAMESPACE}/${key}`);
      } catch (err) {
        log(`${redact(key)} storage read failed: ${err.message}`);
        throw new HttpError(500, 'storage read failed');
      }
      if (!stored) {
        throw new HttpError(404, 'no such upload');
      }
      reply(res, 200, {
        'Upload-Offset': String(stored.size),
        'Upload-Length': String(stored.size),
        'Cache-Control': 'no-store',
      });
    });
  }

  async function patch(req, res, key) {
    requireTusResumable(req);
    const claims = authorize(req, key);
    if (req.headers['content-type'] !== OFFSET_OCTET_STREAM) {
      throw new HttpError(415, `PATCH requires Content-Type: ${OFFSET_OCTET_STREAM}`);
    }
    const headerOffset = parseLength(req.headers['upload-offset']);
    if (headerOffset === undefined || Number.isNaN(headerOffset)) {
      throw new HttpError(400, 'must contain Upload-Offset header');
    }
    const headerLength = parseLength(req.headers['upload-length']);
    await withLock(key, async () => {
      const state = await store.read(key);
      if (!state) {
        throw new HttpError(404, 'no such upload');
      }
      if (state.offset !== headerOffset) {
        throw new HttpError(409, 'incorrect upload offset');
      }
      if (headerLength !== undefined && headerLength !== state.uploadLength) {
        throw new HttpError(400, 'upload length cannot change');
      }
      if (state.uploadLength > claims.maxLen) {
        await store.remove(key);
        throw new HttpError(413, 'Upload-Length exceeds maximum upload size');
      }
      const offset = await appendBody(req, key, state.offset, state.uploadLength);
      if (offset === state.uploadLength) {
        await finalize(key, state);
      }
      res.locals.bytes = offset - state.offset;
      reply(res, 204, {
        'Upload-Offset': String(offset),
        'Upload-Expires': expiresHeader(state),
      });
    });
  }

  function options(res) {
    reply(res, 204, {
      'Tus-Version': TUS_VERSION,
      'Tus-Extension': 'creation,creation-with-upload',
      'Tus-Max-Size': String(config.maxUploadBytes),
    });
  }

  function reply(res, status, headers = {}, body = undefined) {
    if (res.headersSent || res.destroyed) {
      return;
    }
    res.writeHead(status, { 'Tus-Resumable': TUS_VERSION, ...headers });
    res.end(body);
  }

  function replyError(req, res, err) {
    const status = err instanceof HttpError ? err.status : 500;
    const message = err instanceof HttpError ? err.message : 'internal error';
    if (!(err instanceof HttpError)) {
      log(`internal error: ${err.stack || err}`);
    }
    const headers = { 'Content-Type': 'text/plain; charset=utf-8' };
    if (req.method === 'POST' || req.method === 'PATCH') {
      // The body may still be arriving; do not read the rest of it just to throw it away.
      headers.Connection = 'close';
    }
    reply(res, status, headers, req.method === 'HEAD' ? undefined : `${message}\n`);
  }

  async function route(req, res) {
    const { pathname } = new URL(req.url, 'http://tus.invalid');

    if (pathname === '/healthz') {
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        throw new HttpError(405, 'method not allowed');
      }
      const status = storageHealth.ok ? 200 : 503;
      res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(req.method === 'HEAD' ? undefined : `${storageHealth.ok ? 'ok' : `storage: ${storageHealth.detail}`}\n`);
      return;
    }

    if (pathname === COLLECTION_PATH || pathname === `${COLLECTION_PATH}/`) {
      if (req.method === 'OPTIONS') {
        options(res);
        return;
      }
      if (req.method === 'POST') {
        await create(req, res);
        return;
      }
      throw new HttpError(405, 'method not allowed');
    }

    if (pathname.startsWith(`${COLLECTION_PATH}/`)) {
      let key;
      try {
        key = decodeURIComponent(pathname.slice(COLLECTION_PATH.length + 1));
      } catch {
        throw new HttpError(400, 'bad upload key');
      }
      res.locals.key = key;
      if (req.method === 'OPTIONS') {
        options(res);
        return;
      }
      if (req.method === 'HEAD') {
        await head(req, res, key);
        return;
      }
      if (req.method === 'PATCH') {
        await patch(req, res, key);
        return;
      }
      throw new HttpError(405, 'method not allowed');
    }

    throw new HttpError(404, 'not found');
  }

  const server = http.createServer({
    // Uploads may take long; only silence is limited (server.timeout below).
    requestTimeout: 0,
    // Longer than Caddy's upstream keep-alive (2 minutes), so Caddy never reuses a connection
    // this server is about to close.
    keepAliveTimeout: 180_000,
    headersTimeout: 190_000,
  }, (req, res) => {
    const started = now();
    res.locals = { key: null, bytes: 0 };
    res.on('close', () => {
      if (req.url === '/healthz') {
        return;
      }
      const label = req.url.startsWith(COLLECTION_PATH) ? COLLECTION_PATH : '(other)';
      log(`${req.method} ${label} ${redact(res.locals.key)} -> ${res.headersSent ? res.statusCode : 'no response'}`
        + ` ${res.locals.bytes}B ${now() - started}ms`);
    });
    route(req, res).catch((err) => replyError(req, res, err));
  });
  server.timeout = 120_000;

  async function probeStorage() {
    try {
      await s3.headObject(PROBE_KEY);
      if (!storageHealth.ok) {
        log('storage reachable: the tus MinIO key can read under attachments/');
      }
      storageHealth.ok = true;
      storageHealth.detail = 'ok';
    } catch (err) {
      if (storageHealth.ok || storageHealth.detail !== err.message) {
        log(`storage NOT usable: ${err.message} (check SWARM_TUS_S3_* in tus.env and re-run minio-bootstrap)`);
      }
      storageHealth.ok = false;
      storageHealth.detail = err.message;
    }
  }

  async function sweep() {
    try {
      const removed = await store.sweep(now());
      if (removed > 0) {
        log(`removed ${removed} expired or orphaned staging file(s)`);
      }
    } catch (err) {
      log(`sweep failed: ${err.message}`);
    }
  }

  return {
    server,
    probeStorage,
    sweep,
    storageHealth,
    startBackground() {
      probeStorage();
      sweep();
      timers.push(setInterval(probeStorage, 60_000).unref());
      timers.push(setInterval(sweep, 3600_000).unref());
    },
    stop() {
      timers.forEach(clearInterval);
      return new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

// ------------------------------------------------------------------------------ main

async function main() {
  let config;
  try {
    config = loadConfig();
  } catch (err) {
    console.error(`[tus] FATAL: ${err.message}. See docs/STAGING.md, section 8a.`);
    process.exit(78);
  }
  await fsp.mkdir(config.dataDir, { recursive: true });
  await fsp.access(config.dataDir, fs.constants.W_OK);

  const service = createTusService(config, { s3: createS3Client(config.s3) });
  service.server.listen(config.port, '0.0.0.0', () => {
    console.log(`[tus] listening on :${config.port}; uploads for ${config.publicUploadUri}/${NAMESPACE};`
      + ` objects to ${config.s3.endpoint} bucket ${config.s3.bucket} under ${NAMESPACE}/;`
      + ` max ${config.maxUploadBytes} bytes, tokens valid ${config.maxTokenAgeSeconds}s`);
  });
  service.startBackground();

  const shutdown = (signal) => {
    console.log(`[tus] ${signal}: closing`);
    service.stop().then(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
