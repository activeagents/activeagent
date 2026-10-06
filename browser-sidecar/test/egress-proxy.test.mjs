import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';

import { startEgressProxy } from '../lib/egress-proxy.mjs';
import { NetworkPolicy } from '../lib/network-policy.mjs';

function listen(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

// A server that records what it receives and answers with it.
async function echo() {
  const server = await listen((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      server.received.push({ method: request.method, url: request.url, headers: request.headers, body: Buffer.concat(chunks).toString() });
      response.writeHead(200, { 'content-type': 'text/plain', 'x-upstream': 'yes' });
      response.end(`echo ${request.method} ${request.url}`);
    });
  });
  server.received = [];
  return server;
}

async function proxyFor(appServer, options = {}) {
  const policy = new NetworkPolicy({ appOrigin: `http://127.0.0.1:${appServer.address().port}`, ...options });
  const proxy = await startEgressProxy({ policy });
  const { port } = new URL(proxy.url);
  return { proxy, port: Number(port) };
}

// Sends `path`, an absolute URL, through the proxy the way a browser does.
function viaProxy(port, path, { method = 'GET', body = null, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const target = new URL(path);
    const request = http.request({ host: '127.0.0.1', port, method, path, headers: { host: target.host, 'proxy-connection': 'keep-alive', ...headers } });
    request.on('response', (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString() }));
    });
    request.on('error', reject);
    request.end(body);
  });
}

// Opens a CONNECT tunnel to `authority` and, when it opens, sends one GET
// through it.
function tunnel(port, authority) {
  return new Promise((resolve, reject) => {
    const request = http.request({ host: '127.0.0.1', port, method: 'CONNECT', path: authority });
    request.on('connect', (response, socket) => {
      if (response.statusCode !== 200) {
        socket.destroy();
        resolve({ status: response.statusCode, body: null });
        return;
      }
      let body = '';
      socket.on('data', (chunk) => {
        body += chunk;
      });
      socket.on('end', () => resolve({ status: 200, body }));
      socket.write(`GET /through HTTP/1.1\r\nhost: ${authority}\r\nconnection: close\r\n\r\n`);
    });
    request.on('error', reject);
    request.end();
  });
}

test('a request to the app is passed on, without the hop-by-hop headers', async (t) => {
  const app = await echo();
  const { proxy, port } = await proxyFor(app);
  t.after(async () => {
    await proxy.close();
    app.close();
  });

  const response = await viaProxy(port, `http://127.0.0.1:${app.address().port}/orders?page=2`, {
    method: 'POST', body: 'name=acme', headers: { 'content-type': 'application/x-www-form-urlencoded', cookie: 'session=1' },
  });

  assert.equal(response.status, 200);
  assert.equal(response.body, 'echo POST /orders?page=2');
  assert.equal(response.headers['x-upstream'], 'yes');
  const [received] = app.received;
  assert.equal(received.body, 'name=acme');
  assert.equal(received.headers.cookie, 'session=1');
  assert.equal(received.headers.host, `127.0.0.1:${app.address().port}`);
  assert.equal(received.headers['proxy-connection'], undefined);
});

test('a request to a private address is refused and never sent', async (t) => {
  const app = await echo();
  const privateService = await echo();
  const { proxy, port } = await proxyFor(app);
  t.after(async () => {
    await proxy.close();
    app.close();
    privateService.close();
  });

  const response = await viaProxy(port, `http://127.0.0.1:${privateService.address().port}/`);

  assert.equal(response.status, 403);
  assert.match(response.body, /Blocked by the sandbox browser: 127\.0\.0\.1:\d+ is a loopback, link-local or private address/);
  assert.deepEqual(privateService.received, []);
  assert.equal((await viaProxy(port, 'http://localhost:1/')).status, 403);
});

test('a tunnel is opened to the app and refused to a private address', async (t) => {
  const app = await echo();
  const privateService = await echo();
  const { proxy, port } = await proxyFor(app);
  t.after(async () => {
    await proxy.close();
    app.close();
    privateService.close();
  });

  const opened = await tunnel(port, `127.0.0.1:${app.address().port}`);
  assert.equal(opened.status, 200);
  assert.match(opened.body, /echo GET \/through/);

  assert.equal((await tunnel(port, `127.0.0.1:${privateService.address().port}`)).status, 403);
  assert.equal((await tunnel(port, 'no-port.example.com')).status, 403);
  assert.deepEqual(privateService.received, []);
});

test('a host name is connected to at the address that was checked, not looked up again', async (t) => {
  const app = await echo();
  const upstream = await echo();
  // public.test resolves only through this policy, to an address the test
  // counts as public; a second lookup through the system would fail.
  const { proxy, port } = await proxyFor(app, {
    resolve: async (hostname) => (hostname === 'public.test' ? ['127.0.0.1'] : []),
    isPrivate: () => false,
  });
  t.after(async () => {
    await proxy.close();
    app.close();
    upstream.close();
  });

  const response = await viaProxy(port, `http://public.test:${upstream.address().port}/page`);
  assert.equal(response.status, 200);
  assert.equal(upstream.received[0].headers.host, `public.test:${upstream.address().port}`);

  const opened = await tunnel(port, `public.test:${upstream.address().port}`);
  assert.equal(opened.status, 200);
  assert.equal(upstream.received.length, 2);
});

test('a direct request to the proxy is not proxied', async (t) => {
  const app = await echo();
  const { proxy, port } = await proxyFor(app);
  t.after(async () => {
    await proxy.close();
    app.close();
  });

  const response = await new Promise((resolve) => {
    http.get({ host: '127.0.0.1', port, path: '/' }, (answer) => {
      answer.resume();
      resolve(answer.statusCode);
    });
  });
  assert.equal(response, 400);
});
