// Tests for the CDN3 upload service. Run with:  node --test deploy/staging/tus/test/
//
// No network and no MinIO: a small in-process S3 stand-in records what the service writes and
// checks each request's SigV4 signature with the service's own signer. The requests the tests
// make are shaped exactly like the desktop's (ts/util/uploads/tusProtocol.node.ts) and the tokens
// exactly like the chat server's JwtGenerator (HS256; aud, sub, iat, maxLen).

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { after, before, beforeEach, describe, test } from 'node:test';

import {
  createS3Client, createTusService, loadConfig, parseUploadMetadata, signV4, verifyToken,
} from '../server.mjs';

const SECRET = crypto.randomBytes(32);
const S3_ACCESS = 'swarmtustest';
const S3_SECRET = crypto.randomBytes(20).toString('hex');
const BUCKET = 'swarm-cdn';

function b64url(value) {
  return Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');
}

// Same shape as org.whispersystems.textsecuregcm.auth.JwtGenerator via java-jwt.
function makeToken(claims, { secret = SECRET, header = { alg: 'HS256', typ: 'JWT' } } = {}) {
  const h = b64url(header);
  const p = b64url(claims);
  const sig = crypto.createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url');
  return `${h}.${p}.${sig}`;
}

function newKey() {
  return crypto.randomBytes(15).toString('base64url');
}

function formFor(key, maxLen, extra = {}) {
  const token = makeToken({ aud: 'attachments', sub: key, iat: Math.floor(Date.now() / 1000), maxLen, ...extra });
  return {
    Authorization: `Bearer ${token}`,
    'Upload-Metadata': `filename ${Buffer.from(key).toString('base64')}`,
  };
}

// ------------------------------------------------------------------ S3 stand-in

function startFakeS3() {
  const objects = new Map();
  const state = { failPuts: false, requests: [] };
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) {
      chunks.push(chunk);
    }
    const body = Buffer.concat(chunks);
    state.requests.push({ method: req.method, url: req.url, headers: req.headers });

    // Verify the signature the way MinIO would, from the headers it actually received.
    const auth = req.headers.authorization || '';
    const match = /^AWS4-HMAC-SHA256 Credential=([^/]+)\/(\d{8})\/([^/]+)\/s3\/aws4_request, SignedHeaders=([^,]+), Signature=([0-9a-f]{64})$/.exec(auth);
    if (!match || match[1] !== S3_ACCESS) {
      res.writeHead(403).end('<Error><Code>AccessDenied</Code></Error>');
      return;
    }
    const signedNames = match[4].split(';');
    const signedHeaders = Object.fromEntries(signedNames.map((n) => [n, req.headers[n]]));
    const amz = req.headers['x-amz-date'];
    const date = new Date(`${amz.slice(0, 4)}-${amz.slice(4, 6)}-${amz.slice(6, 8)}T${amz.slice(9, 11)}:${amz.slice(11, 13)}:${amz.slice(13, 15)}Z`);
    const expected = signV4({
      method: req.method,
      canonicalUri: req.url,
      headers: signedHeaders,
      payloadHash: req.headers['x-amz-content-sha256'],
      accessKey: S3_ACCESS,
      secretKey: S3_SECRET,
      region: match[3],
      date,
    });
    if (expected.signature !== match[5]) {
      res.writeHead(403).end('<Error><Code>SignatureDoesNotMatch</Code></Error>');
      return;
    }
    const prefix = `/${BUCKET}/`;
    if (!req.url.startsWith(prefix)) {
      res.writeHead(404).end();
      return;
    }
    const objectKey = decodeURIComponent(req.url.slice(prefix.length));
    if (req.method === 'PUT') {
      if (state.failPuts) {
        res.writeHead(503).end('<Error><Code>ServiceUnavailable</Code></Error>');
        return;
      }
      const hash = crypto.createHash('sha256').update(body).digest('hex');
      if (hash !== req.headers['x-amz-content-sha256']) {
        res.writeHead(400).end('<Error><Code>XAmzContentSHA256Mismatch</Code></Error>');
        return;
      }
      objects.set(objectKey, { body, contentType: req.headers['content-type'] });
      res.writeHead(200).end();
      return;
    }
    if (req.method === 'HEAD') {
      const object = objects.get(objectKey);
      if (!object) {
        res.writeHead(404).end();
        return;
      }
      res.writeHead(200, { 'Content-Length': object.body.length }).end();
      return;
    }
    res.writeHead(405).end();
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, objects, state, port: server.address().port }));
  });
}

// ------------------------------------------------------------------ HTTP helpers

function request(port, method, urlPath, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString() }));
    });
    req.on('error', reject);
    if (body !== undefined) {
      req.end(body);
    } else {
      req.end();
    }
  });
}

// The desktop's creation-with-upload: a stream body, so Node sends it chunked.
function createWithUpload(port, key, data, headers) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1',
      port,
      method: 'POST',
      path: '/upload/attachments',
      headers: {
        ...headers,
        'Tus-Resumable': '1.0.0',
        'Upload-Length': String(data.length),
        'Upload-Metadata': `filename ${Buffer.from(key).toString('base64')}`,
        'Content-Type': 'application/offset+octet-stream',
      },
    }, (res) => {
      res.resume();
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers }));
    });
    req.on('error', reject);
    // Two writes, so the body really is chunked.
    req.write(data.subarray(0, Math.floor(data.length / 2)));
    req.end(data.subarray(Math.floor(data.length / 2)));
  });
}

async function waitFor(predicate, timeoutMs = 5000) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if (await predicate()) {
      return;
    }
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error('timed out waiting');
}

// ------------------------------------------------------------------ unit tests

describe('signV4', () => {
  test('matches the GET Object example in the AWS SigV4 documentation', () => {
    const { signature, signedHeaders } = signV4({
      method: 'GET',
      canonicalUri: '/test.txt',
      headers: {
        host: 'examplebucket.s3.amazonaws.com',
        range: 'bytes=0-9',
        'x-amz-content-sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'x-amz-date': '20130524T000000Z',
      },
      payloadHash: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      accessKey: 'AKIAIOSFODNN7EXAMPLE',
      secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
      region: 'us-east-1',
      date: new Date('2013-05-24T00:00:00Z'),
    });
    assert.equal(signedHeaders, 'host;range;x-amz-content-sha256;x-amz-date');
    assert.equal(signature, 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41');
  });
});

describe('verifyToken', () => {
  const now = Math.floor(Date.now() / 1000);
  const opts = { audience: 'attachments', maxAgeSeconds: 7 * 24 * 3600, nowSeconds: now };
  const good = { aud: 'attachments', sub: 'k'.repeat(20), iat: now, maxLen: 100 };

  test('accepts the chat server token', () => {
    assert.deepEqual(verifyToken(`Bearer ${makeToken(good)}`, SECRET, opts), { sub: good.sub, maxLen: 100 });
  });
  test('accepts an audience array', () => {
    assert.equal(verifyToken(`Bearer ${makeToken({ ...good, aud: ['attachments'] })}`, SECRET, opts).sub, good.sub);
  });
  const rejects = (name, auth, status) => test(name, () => {
    assert.throws(() => verifyToken(auth, SECRET, opts), (err) => err.status === status);
  });
  rejects('no header', undefined, 401);
  rejects('Basic credentials', 'Basic dXNlcjpwYXNz', 400);
  rejects('wrong secret', `Bearer ${makeToken(good, { secret: crypto.randomBytes(32) })}`, 401);
  rejects('alg none', `Bearer ${makeToken(good, { header: { alg: 'none' } }).replace(/\.[^.]*$/, '.x')}`, 401);
  rejects('HS512 header', `Bearer ${makeToken(good, { header: { alg: 'HS512' } })}`, 401);
  rejects('backups audience', `Bearer ${makeToken({ ...good, aud: 'backups' })}`, 401);
  rejects('older than 7 days', `Bearer ${makeToken({ ...good, iat: now - 8 * 24 * 3600 })}`, 401);
  rejects('issued in the future', `Bearer ${makeToken({ ...good, iat: now + 3600 })}`, 401);
  rejects('no maxLen', `Bearer ${makeToken({ aud: 'attachments', sub: good.sub, iat: now })}`, 401);
  rejects('no sub', `Bearer ${makeToken({ aud: 'attachments', iat: now, maxLen: 1 })}`, 401);
  rejects('tampered payload', `Bearer ${(() => {
    const [h, , s] = makeToken(good).split('.');
    return `${h}.${b64url({ ...good, maxLen: 10 ** 9 })}.${s}`;
  })()}`, 401);
});

describe('parseUploadMetadata', () => {
  test('reads the filename', () => {
    assert.equal(parseUploadMetadata(`filename ${Buffer.from('abc').toString('base64')}`).filename, 'abc');
  });
  test('skips keys without values and other keys', () => {
    assert.equal(parseUploadMetadata(`is_confidential,filename ${Buffer.from('k').toString('base64')},x eA==`).filename, 'k');
  });
  test('rejects non-base64', () => {
    assert.throws(() => parseUploadMetadata('filename not*base64'), (err) => err.status === 400);
  });
});

describe('loadConfig', () => {
  test('refuses to start without its secrets', () => {
    assert.throws(() => loadConfig({}), /SWARM_TUS_TOKEN_SECRET is not set.*TUS_PUBLIC_UPLOAD_URI is not set.*SWARM_TUS_S3_ACCESS_KEY is not set/);
  });
  test('refuses a token secret that is not 32 bytes', () => {
    assert.throws(() => loadConfig({
      SWARM_TUS_TOKEN_SECRET: Buffer.alloc(16).toString('base64'),
      TUS_PUBLIC_UPLOAD_URI: 'https://cdn.example/upload',
      SWARM_TUS_S3_ACCESS_KEY: 'a',
      SWARM_TUS_S3_SECRET_KEY: 'b',
    }), /exactly 32 bytes/);
  });
});

// ------------------------------------------------------------------ the service, end to end

describe('upload service', () => {
  let s3;
  let service;
  let port;
  let dataDir;

  before(async () => {
    s3 = await startFakeS3();
    dataDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'swarm-tus-'));
    const config = loadConfig({
      SWARM_TUS_TOKEN_SECRET: SECRET.toString('base64'),
      TUS_PUBLIC_UPLOAD_URI: 'https://cdn.chat.swarm.green/upload/',
      TUS_DATA_DIR: dataDir,
      TUS_MAX_UPLOAD_BYTES: String(1024 * 1024),
      TUS_S3_ENDPOINT: `http://127.0.0.1:${s3.port}`,
      TUS_S3_BUCKET: BUCKET,
      SWARM_TUS_S3_ACCESS_KEY: S3_ACCESS,
      SWARM_TUS_S3_SECRET_KEY: S3_SECRET,
    });
    service = createTusService(config, { s3: createS3Client(config.s3), log: () => {} });
    await new Promise((resolve) => service.server.listen(0, '127.0.0.1', resolve));
    port = service.server.address().port;
  });

  after(async () => {
    await service.stop();
    s3.server.close();
    await fsp.rm(dataDir, { recursive: true, force: true });
  });

  beforeEach(() => {
    s3.state.failPuts = false;
  });

  test('OPTIONS describes the server without credentials', async () => {
    const res = await request(port, 'OPTIONS', '/upload/attachments');
    assert.equal(res.status, 204);
    assert.equal(res.headers['tus-version'], '1.0.0');
    assert.match(res.headers['tus-extension'], /creation-with-upload/);
    assert.equal(res.headers['tus-max-size'], String(1024 * 1024));
  });

  test('creation-with-upload stores the object before answering 201', async () => {
    const key = newKey();
    const data = crypto.randomBytes(3872);
    const res = await createWithUpload(port, key, data, formFor(key, data.length));
    assert.equal(res.status, 201);
    assert.equal(res.headers.location, `https://cdn.chat.swarm.green/upload/attachments/${key}`);
    assert.equal(res.headers['upload-offset'], String(data.length));
    assert.equal(res.headers['tus-resumable'], '1.0.0');
    const stored = s3.objects.get(`attachments/${key}`);
    assert.ok(stored, 'object is in the bucket');
    assert.ok(stored.body.equals(data));
    assert.equal(stored.contentType, 'application/octet-stream');
    assert.deepEqual(await fsp.readdir(dataDir), [], 'nothing left in the staging area');

    // A HEAD after completion answers from the bucket, so a client that lost the 201 stops.
    const head = await request(port, 'HEAD', `/upload/attachments/${key}`, {
      headers: { ...formFor(key, data.length), 'Tus-Resumable': '1.0.0' },
    });
    assert.equal(head.status, 200);
    assert.equal(head.headers['upload-offset'], String(data.length));
    assert.equal(head.headers['cache-control'], 'no-store');
  });

  test('a broken POST resumes with HEAD and PATCH at <location>/<key>, as the desktop does', async () => {
    const key = newKey();
    const data = crypto.randomBytes(200_000);
    const half = 120_000;
    const form = formFor(key, data.length);

    await new Promise((resolve) => {
      const req = http.request({
        host: '127.0.0.1',
        port,
        method: 'POST',
        path: '/upload/attachments',
        headers: {
          ...form,
          'Tus-Resumable': '1.0.0',
          'Upload-Length': String(data.length),
          'Content-Type': 'application/offset+octet-stream',
        },
      });
      req.on('error', () => resolve());
      req.write(data.subarray(0, half));
      waitFor(async () => {
        const st = await fsp.stat(path.join(dataDir, `${key}.bin`)).catch(() => null);
        return st && st.size === half;
      }).then(() => {
        req.destroy();
        resolve();
      });
    });

    let head;
    await waitFor(async () => {
      head = await request(port, 'HEAD', `/upload/attachments/${key}`, {
        headers: { ...form, 'Tus-Resumable': '1.0.0' },
      });
      return head.status === 200 && head.headers['upload-offset'] === String(half);
    });
    assert.equal(head.headers['upload-length'], String(data.length));
    assert.equal(s3.objects.has(`attachments/${key}`), false);

    const wrong = await request(port, 'PATCH', `/upload/attachments/${key}`, {
      headers: { ...form, 'Tus-Resumable': '1.0.0', 'Upload-Offset': '0', 'Content-Type': 'application/offset+octet-stream' },
      body: data.subarray(0),
    });
    assert.equal(wrong.status, 409);

    const patch = await request(port, 'PATCH', `/upload/attachments/${key}`, {
      headers: { ...form, 'Tus-Resumable': '1.0.0', 'Upload-Offset': String(half), 'Content-Type': 'application/offset+octet-stream' },
      body: data.subarray(half),
    });
    assert.equal(patch.status, 204);
    assert.equal(patch.headers['upload-offset'], String(data.length));
    assert.ok(s3.objects.get(`attachments/${key}`).body.equals(data));
  });

  test('a token for another key is refused (401) and nothing is written', async () => {
    const key = newKey();
    const data = crypto.randomBytes(100);
    const res = await createWithUpload(port, key, data, formFor(newKey(), 100));
    assert.equal(res.status, 401);
    assert.equal(s3.objects.has(`attachments/${key}`), false);
  });

  test('no token: 401; Basic credentials: 400; no Tus-Resumable: 412', async () => {
    const key = newKey();
    const noAuth = await createWithUpload(port, key, Buffer.alloc(10), {});
    assert.equal(noAuth.status, 401);
    const basic = await createWithUpload(port, key, Buffer.alloc(10), { Authorization: 'Basic dTpw' });
    assert.equal(basic.status, 400);
    const noVersion = await request(port, 'HEAD', `/upload/attachments/${key}`, { headers: formFor(key, 10) });
    assert.equal(noVersion.status, 412);
  });

  test('Upload-Length above maxLen is 413; a body past Upload-Length is 413 and discarded', async () => {
    const key = newKey();
    const tooLong = await createWithUpload(port, key, crypto.randomBytes(101), formFor(key, 100));
    assert.equal(tooLong.status, 413);

    const key2 = newKey();
    const res = await request(port, 'POST', '/upload/attachments', {
      headers: {
        ...formFor(key2, 1000),
        'Tus-Resumable': '1.0.0',
        'Upload-Length': '10',
        'Content-Type': 'application/offset+octet-stream',
      },
      body: crypto.randomBytes(20),
    });
    assert.equal(res.status, 413);
    assert.equal(fs.existsSync(path.join(dataDir, `${key2}.json`)), false);
  });

  test('a wrong Content-Type is 415', async () => {
    const key = newKey();
    const res = await request(port, 'POST', '/upload/attachments', {
      headers: { ...formFor(key, 10), 'Tus-Resumable': '1.0.0', 'Upload-Length': '10', 'Content-Type': 'text/plain' },
      body: Buffer.alloc(10),
    });
    assert.equal(res.status, 415);
  });

  test('HEAD for an unknown key is 404', async () => {
    const key = newKey();
    const res = await request(port, 'HEAD', `/upload/attachments/${key}`, {
      headers: { ...formFor(key, 10), 'Tus-Resumable': '1.0.0' },
    });
    assert.equal(res.status, 404);
  });

  test('a failed bucket write is a 500, keeps the bytes, and the next HEAD completes it', async () => {
    const key = newKey();
    const data = crypto.randomBytes(5000);
    s3.state.failPuts = true;
    const res = await createWithUpload(port, key, data, formFor(key, data.length));
    assert.equal(res.status, 500);
    assert.equal(s3.objects.has(`attachments/${key}`), false);
    assert.equal(fs.statSync(path.join(dataDir, `${key}.bin`)).size, data.length);

    s3.state.failPuts = false;
    const head = await request(port, 'HEAD', `/upload/attachments/${key}`, {
      headers: { ...formFor(key, data.length), 'Tus-Resumable': '1.0.0' },
    });
    assert.equal(head.status, 200);
    assert.equal(head.headers['upload-offset'], String(data.length));
    assert.ok(s3.objects.get(`attachments/${key}`).body.equals(data));
  });

  test('a matching X-Signal-Checksum-Sha256 is accepted, a wrong one is 415', async () => {
    const key = newKey();
    const data = crypto.randomBytes(64);
    const good = crypto.createHash('sha256').update(data).digest('base64');
    const ok = await createWithUpload(port, key, data, { ...formFor(key, 64), 'X-Signal-Checksum-Sha256': good });
    assert.equal(ok.status, 201);

    const key2 = newKey();
    const bad = await createWithUpload(port, key2, data, {
      ...formFor(key2, 64), 'X-Signal-Checksum-Sha256': crypto.randomBytes(32).toString('base64'),
    });
    assert.equal(bad.status, 415);
    assert.equal(s3.objects.has(`attachments/${key2}`), false);
  });

  test('a second POST for a key that already holds bytes is 409', async () => {
    const key = newKey();
    const form = formFor(key, 100);
    const first = await request(port, 'POST', '/upload/attachments', {
      headers: { ...form, 'Tus-Resumable': '1.0.0', 'Upload-Length': '100', 'Content-Type': 'application/offset+octet-stream' },
      body: Buffer.alloc(40),
    });
    assert.equal(first.status, 201);
    assert.equal(first.headers['upload-offset'], '40');
    const second = await createWithUpload(port, key, Buffer.alloc(100), form);
    assert.equal(second.status, 409);
  });

  test('paths outside /upload/attachments are 404, other namespaces too', async () => {
    assert.equal((await request(port, 'GET', '/attachments/abc')).status, 404);
    assert.equal((await request(port, 'POST', '/upload/backups', { headers: { 'Tus-Resumable': '1.0.0' } })).status, 404);
    assert.equal((await request(port, 'GET', '/upload/attachments')).status, 405);
  });

  test('the storage probe reports a usable bucket', async () => {
    await service.probeStorage();
    assert.equal(service.storageHealth.ok, true);
    const res = await request(port, 'GET', '/healthz');
    assert.equal(res.status, 200);
  });
});
