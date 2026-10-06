import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import test from 'node:test';

import { acceptedHosts } from '../lib/guard.mjs';
import { createHttpServer } from '../lib/http-server.mjs';

const TOKEN = 'browser-token-0123456789abcdef0123456789';

async function start({ storageState = null } = {}) {
  const calls = [];
  const gateway = {
    async handle(message, sessionId) {
      calls.push({ message, sessionId });
      return { status: 200, headers: { 'mcp-session-id': 'session-1' }, body: { jsonrpc: '2.0', id: message.id, result: {} } };
    },
    async closeSession(id) {
      calls.push({ closed: id });
      return id === 'session-1';
    },
  };
  let hosts = new Set();
  const server = createHttpServer({ rules: () => ({ token: TOKEN, hosts }), gateway, version: '9.9.9', storageState });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  hosts = acceptedHosts('127.0.0.1', port);
  return { server, port, calls };
}

function send(port, { method = 'GET', path = '/health', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request({ host: '127.0.0.1', port, method, path, headers: { host: `127.0.0.1:${port}`, ...headers } }, (response) => {
      let text = '';
      response.on('data', (chunk) => (text += chunk));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: text ? JSON.parse(text) : null }));
    });
    request.on('error', reject);
    if (body !== undefined) request.write(body);
    request.end();
  });
}

// The status line a raw WebSocket upgrade request is answered with.
function upgrade(port, headers, path = '/mcp') {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => {
      const lines = [
        `GET ${path} HTTP/1.1`,
        'Connection: Upgrade',
        'Upgrade: websocket',
        'Sec-WebSocket-Version: 13',
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
        ...Object.entries(headers).map(([name, value]) => `${name}: ${value}`),
      ];
      socket.write(`${lines.join('\r\n')}\r\n\r\n`);
    });
    let text = '';
    socket.on('data', (chunk) => (text += chunk));
    socket.on('end', () => resolve(text.split('\r\n')[0]));
    socket.on('error', reject);
  });
}

const auth = { authorization: `Bearer ${TOKEN}` };

test('every request needs the token', async (t) => {
  const { server, port, calls } = await start();
  t.after(() => server.close());

  assert.equal((await send(port)).status, 401);
  assert.equal((await send(port, { headers: { authorization: 'Bearer wrong' } })).status, 401);
  assert.equal((await send(port, { method: 'POST', path: '/mcp', body: '{}' })).status, 401);
  assert.equal(calls.length, 0);

  const health = await send(port, { headers: auth });
  assert.equal(health.status, 200);
  assert.deepEqual(health.body, { status: 'ok', version: '9.9.9' });
  assert.equal(health.headers['access-control-allow-origin'], undefined);
});

test('the storage state is read with the token only, and only when the sidecar serves it', async (t) => {
  const state = { cookies: [{ name: 'session', value: 'abc', domain: '127.0.0.1', path: '/' }], origins: [] };
  const { server, port } = await start({ storageState: async () => state });
  t.after(() => server.close());

  assert.equal((await send(port, { path: '/storage-state' })).status, 401);
  const read = await send(port, { path: '/storage-state', headers: auth });
  assert.equal(read.status, 200);
  assert.deepEqual(read.body, { storage_state: state });
  assert.equal(read.headers['cache-control'], 'no-store');

  const { server: plain, port: plainPort } = await start();
  t.after(() => plain.close());
  assert.equal((await send(plainPort, { path: '/storage-state', headers: auth })).status, 404);
});

test('a foreign Host or any Origin is refused, even with the token', async (t) => {
  const { server, port, calls } = await start();
  t.after(() => server.close());

  const rebound = await send(port, { method: 'POST', path: '/mcp', headers: { ...auth, host: `attacker.test:${port}` }, body: '{}' });
  assert.equal(rebound.status, 403);
  assert.equal(rebound.body.error, 'Host not allowed');

  const fromPage = await send(port, { method: 'POST', path: '/mcp', headers: { ...auth, origin: 'http://127.0.0.1:3000' }, body: '{}' });
  assert.equal(fromPage.status, 403);
  assert.equal(fromPage.body.error, 'Origin not allowed');

  const preflight = await send(port, { method: 'OPTIONS', path: '/mcp', headers: { origin: 'http://127.0.0.1:3000' } });
  assert.equal(preflight.status, 403);
  assert.equal(calls.length, 0);
});

test('a JSON-RPC message reaches the gateway with its session', async (t) => {
  const { server, port, calls } = await start();
  t.after(() => server.close());

  const response = await send(port, {
    method: 'POST', path: '/mcp', headers: { ...auth, 'mcp-session-id': 'session-1', 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 4, method: 'tools/list' }),
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers['mcp-session-id'], 'session-1');
  assert.deepEqual(calls, [{ message: { jsonrpc: '2.0', id: 4, method: 'tools/list' }, sessionId: 'session-1' }]);

  assert.equal((await send(port, { method: 'POST', path: '/mcp', headers: auth, body: 'not json' })).status, 400);
  assert.equal((await send(port, { method: 'GET', path: '/mcp', headers: auth })).status, 405);
  assert.equal((await send(port, { method: 'GET', path: '/elsewhere', headers: auth })).status, 404);
  assert.equal((await send(port, { method: 'DELETE', path: '/mcp', headers: { ...auth, 'mcp-session-id': 'session-1' } })).status, 200);
  assert.equal((await send(port, { method: 'DELETE', path: '/mcp', headers: { ...auth, 'mcp-session-id': 'other' } })).status, 404);
});

test('a body over the limit is refused', async (t) => {
  const { server, port } = await start();
  t.after(() => server.close());

  const response = await send(port, { method: 'POST', path: '/mcp', headers: auth, body: 'x'.repeat(5 * 1024 * 1024) }).catch((error) => error);
  assert.ok(response instanceof Error || response.status === 413);
});

test('a WebSocket upgrade is checked like any request, and there is nothing to upgrade to', async (t) => {
  const { server, port } = await start();
  t.after(() => server.close());

  assert.equal(await upgrade(port, { Host: `127.0.0.1:${port}` }), 'HTTP/1.1 401 Unauthorized');
  assert.equal(await upgrade(port, { Host: `attacker.test:${port}`, Authorization: `Bearer ${TOKEN}` }), 'HTTP/1.1 403 Forbidden');
  assert.equal(
    await upgrade(port, { Host: `127.0.0.1:${port}`, Origin: 'http://127.0.0.1:3000', Authorization: `Bearer ${TOKEN}` }),
    'HTTP/1.1 403 Forbidden',
  );
  assert.equal(await upgrade(port, { Host: `127.0.0.1:${port}`, Authorization: `Bearer ${TOKEN}` }), 'HTTP/1.1 404 Not Found');
});

test('without a live view, its path is no upgrade either', async (t) => {
  const { server, port } = await start();
  t.after(() => server.close());

  const live = (headers) => upgrade(port, { Host: `127.0.0.1:${port}`, ...headers }, '/live');
  assert.equal(await live({ Origin: 'http://localhost:3000' }), 'HTTP/1.1 403 Forbidden');
  assert.equal(await live({ Authorization: `Bearer ${TOKEN}` }), 'HTTP/1.1 404 Not Found');
});
