// Tests for the TURN credential service:
//   node --test deploy/staging/turn-credentials/test/server.test.mjs
// Node's built-in test runner only; nothing to install.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import test from 'node:test';

import {
  API_PATH,
  MAX_TTL_SECONDS,
  createServer,
  loadConfig,
  mintCredentials,
  parseTtl,
  turnCredential,
} from '../server.mjs';

const TOKEN = 'a'.repeat(64);
const SECRET = '0123456789abcdef0123456789abcdef';
const env = {
  SWARM_TURN_API_TOKEN: TOKEN,
  SWARM_TURN_STATIC_AUTH_SECRET: SECRET,
  SWARM_TURN_URLS: 'turn:sfu.example:3478, turn:sfu.example:3478?transport=tcp',
};

test('coturn TURN REST credential = base64(HMAC-SHA1(secret, username))', () => {
  // Vector computed independently (Python hmac/hashlib) for this secret and username.
  assert.equal(turnCredential(Buffer.from(SECRET), '1700000000:swarm-test'), 'uvVGKI1jcbx2hUPICFDOP/3//NY=');
});

test('loadConfig refuses missing or short secrets and parses the URL list', () => {
  assert.throws(() => loadConfig({}), /SWARM_TURN_API_TOKEN.*SWARM_TURN_STATIC_AUTH_SECRET/);
  assert.throws(() => loadConfig({ ...env, SWARM_TURN_API_TOKEN: 'unset' }), /SWARM_TURN_API_TOKEN/);
  const config = loadConfig(env);
  assert.deepEqual(config.urls, ['turn:sfu.example:3478', 'turn:sfu.example:3478?transport=tcp']);
  assert.equal(config.port, 8080);
});

test('minted username carries the expiry, and the ttl is capped', () => {
  const config = loadConfig(env);
  const now = 1_800_000_000_000;
  const minted = mintCredentials(config, 86400, now);
  const { username, credential, urls } = minted.body.iceServers;
  assert.match(username, /^1800086400:[A-Za-z0-9_-]{16}$/);
  assert.equal(credential, turnCredential(config.secret, username));
  assert.deepEqual(urls, config.urls);
  const capped = mintCredentials(config, 10 * MAX_TTL_SECONDS, now);
  assert.equal(capped.ttl, MAX_TTL_SECONDS);
  assert.equal(capped.expiry, now / 1000 + MAX_TTL_SECONDS);
  assert.notEqual(capped.body.iceServers.username, username);
});

test('parseTtl accepts only {"ttl": positive integer}', () => {
  assert.equal(parseTtl('{"ttl":86400}'), 86400);
  for (const bad of ['', 'nope', '{}', '{"ttl":0}', '{"ttl":-5}', '{"ttl":1.5}', '{"ttl":"86400"}']) {
    assert.throws(() => parseTtl(bad), e => e.status === 400, bad);
  }
});

test('HTTP: 201 in Cloudflare\'s shape with the right token; 401, 405, 404, 400 otherwise', async () => {
  const lines = [];
  const server = createServer(loadConfig(env), line => lines.push(line));
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (headers, body) => fetch(`${base}${API_PATH}`, { method: 'POST', headers, body });
  try {
    const ok = await post({ Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' }, '{"ttl":86400}');
    assert.equal(ok.status, 201);
    const json = await ok.json();
    assert.equal(typeof json.iceServers.username, 'string');
    assert.equal(json.iceServers.credential, turnCredential(Buffer.from(SECRET), json.iceServers.username));
    const expiry = Number(json.iceServers.username.split(':')[0]);
    assert.ok(Math.abs(expiry - (Date.now() / 1000 + 86400)) < 5);

    assert.equal((await post({ Authorization: 'Bearer wrong' }, '{"ttl":60}')).status, 401);
    assert.equal((await post({ Authorization: `Bearer ${TOKEN}x` }, '{"ttl":60}')).status, 401);
    assert.equal((await post({}, '{"ttl":60}')).status, 401);
    assert.equal((await post({ Authorization: `Basic ${TOKEN}` }, '{"ttl":60}')).status, 401);
    const get = await fetch(`${base}${API_PATH}`, { headers: { Authorization: `Bearer ${TOKEN}` } });
    assert.equal(get.status, 405);
    assert.equal(get.headers.get('allow'), 'POST');
    assert.equal((await fetch(`${base}/v1/turn`, { method: 'POST' })).status, 404);
    assert.equal((await post({ Authorization: `Bearer ${TOKEN}` }, '{"ttl":"x"}')).status, 400);
    assert.equal((await fetch(`${base}/healthz`)).status, 200);

    // The log never contains the token, the secret, or a credential.
    const all = lines.join('\n');
    assert.ok(!all.includes(TOKEN) && !all.includes(SECRET) && !all.includes(json.iceServers.credential));
    assert.ok(!all.includes(json.iceServers.username));
    assert.match(all, /POST \/credentials\/generate 201 ttl=86400 expires=/);
  } finally {
    server.close();
  }
});
