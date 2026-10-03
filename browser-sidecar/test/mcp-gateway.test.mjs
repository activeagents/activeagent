import assert from 'node:assert/strict';
import { mkdtemp, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { ControlLock, TAKEOVER_META } from '../lib/control-lock.mjs';
import { McpGateway } from '../lib/mcp-gateway.mjs';
import { NetworkPolicy } from '../lib/network-policy.mjs';

// Stands in for a Playwright MCP server: answers initialize and tools/list,
// and echoes a tool call's arguments, or a canned text, back as its result.
class FakeServer {
  constructor(log, { callText } = {}) {
    this.log = log;
    this.callText = callText;
    this.closed = false;
  }

  async connect(transport) {
    this.transport = transport;
    transport.onmessage = (message) => {
      this.log.push(message);
      if (message.id === undefined) return;

      let result;
      if (message.method === 'initialize') result = { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'fake' } };
      else if (message.method === 'tools/list') {
        result = { tools: ['browser_navigate', 'browser_run_code_unsafe', 'browser_snapshot'].map((name) => ({ name, inputSchema: { type: 'object' } })) };
      } else if (message.method === 'tools/call') {
        result = { content: [{ type: 'text', text: this.callText ?? JSON.stringify(message.params.arguments) }] };
      }
      void transport.send({ jsonrpc: '2.0', id: message.id, result });
    };
    await transport.start();
  }

  async close() {
    this.closed = true;
  }
}

function gateway(options = {}) {
  const log = [];
  const servers = [];
  const instance = new McpGateway({
    connect: async () => {
      const server = new FakeServer(log, options);
      servers.push(server);
      return server;
    },
    policy: new NetworkPolicy({ appOrigin: 'http://127.0.0.1:3000', resolve: async () => [] }),
    ...options.gateway,
  });
  return { instance, log, servers };
}

async function session(instance) {
  const response = await instance.handle({
    jsonrpc: '2.0', id: 1, method: 'initialize',
    params: { protocolVersion: '2025-03-26', capabilities: { roots: { listChanged: true }, sampling: {} }, clientInfo: { name: 'test' } },
  });
  assert.equal(response.status, 200);
  return response.headers['mcp-session-id'];
}

function call(instance, id, name, args) {
  return instance.handle({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name, arguments: args } }, id);
}

test('initialize opens a session, without the capabilities the client declared', async () => {
  const { instance, log } = gateway();
  const id = await session(instance);

  assert.match(id, /^[0-9a-f-]{36}$/);
  assert.deepEqual(log[0].params.capabilities, {});
  assert.equal(log[0].params.clientInfo.name, 'test');
});

test('a message needs a session, and an unknown one is not found', async () => {
  const { instance } = gateway();

  assert.equal((await instance.handle({ jsonrpc: '2.0', id: 3, method: 'tools/list' })).status, 400);
  assert.equal((await instance.handle({ jsonrpc: '2.0', id: 3, method: 'tools/list' }, 'no-such-session')).status, 404);
  assert.equal((await instance.handle([{ jsonrpc: '2.0', id: 3, method: 'tools/list' }], 'x')).status, 400);
  assert.equal((await instance.handle({ id: 3, method: 'tools/list' }, 'x')).status, 400);
});

test('a notification is passed on and acknowledged', async () => {
  const { instance, log } = gateway();
  const id = await session(instance);

  const response = await instance.handle({ jsonrpc: '2.0', method: 'notifications/initialized' }, id);

  assert.equal(response.status, 202);
  assert.equal(log.at(-1).method, 'notifications/initialized');
});

test('a denied tool is neither listed nor called', async () => {
  const { instance, log } = gateway();
  const id = await session(instance);

  const listed = await instance.handle({ jsonrpc: '2.0', id: 2, method: 'tools/list' }, id);
  assert.deepEqual(listed.body.result.tools.map((tool) => tool.name), ['browser_navigate', 'browser_snapshot']);

  const before = log.length;
  const called = await call(instance, id, 'browser_run_code_unsafe', { code: 'async () => process.env' });
  assert.equal(called.body.result.isError, true);
  assert.match(called.body.result.content[0].text, /not available/);
  assert.equal(log.length, before, 'the server never saw the call');
});

test('a navigation off the app is refused before it reaches the browser, and a path is made absolute', async () => {
  const { instance, log } = gateway();
  const id = await session(instance);
  const before = log.length;

  for (const url of ['https://example.com/', 'http://169.254.169.254/latest', 'file:///etc/passwd']) {
    const refused = await call(instance, id, 'browser_navigate', { url });
    assert.equal(refused.body.result.isError, true, url);
  }
  const newTab = await call(instance, id, 'browser_tabs', { action: 'new', url: 'http://10.0.0.1/' });
  assert.equal(newTab.body.result.isError, true);
  assert.equal(log.length, before);

  const allowed = await call(instance, id, 'browser_navigate', { url: '/orders', _meta: { cwd: '/' } });
  assert.deepEqual(JSON.parse(allowed.body.result.content[0].text), { url: 'http://127.0.0.1:3000/orders' });
  const listTabs = await call(instance, id, 'browser_tabs', { action: 'list' });
  assert.deepEqual(JSON.parse(listTabs.body.result.content[0].text), { action: 'list' });
});

test('a snapshot file in the snapshot directory is inlined, and any other path is left alone', async () => {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'gateway-snapshots-')));
  const outside = await realpath(await mkdtemp(join(tmpdir(), 'gateway-outside-')));
  try {
    await writeFile(join(dir, 'page.yml'), '- heading "Orders" [ref=e1]');
    await writeFile(join(outside, 'secret.yml'), 'not for the model');
    const text = `### Page\n- Page URL: http://127.0.0.1:3000/\n### Snapshot\n- [Snapshot](${join(dir, 'page.yml')})\n- [Snapshot](${join(outside, 'secret.yml')})\n- [Snapshot](${join(dir, '..', 'x.yml')})`;
    const { instance } = gateway({ callText: text, gateway: { snapshotDir: dir } });
    const id = await session(instance);

    const result = (await call(instance, id, 'browser_click', { target: 'e1' })).body.result.content[0].text;

    assert.match(result, /### Snapshot\n```yaml\n- heading "Orders" \[ref=e1\]\n```/);
    assert.ok(!result.includes('not for the model'));
    assert.ok(result.includes(`[Snapshot](${join(outside, 'secret.yml')})`));
  } finally {
    await rm(dir, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  }
});

test('the least recently used idle session is closed to make room', async () => {
  const { instance, servers } = gateway({ gateway: { maxSessions: 2 } });
  const first = await session(instance);
  const second = await session(instance);
  await call(instance, first, 'browser_snapshot', {});

  const third = await session(instance);

  assert.ok(third);
  assert.equal(servers[1].closed, true);
  assert.equal((await instance.handle({ jsonrpc: '2.0', id: 9, method: 'tools/list' }, second)).status, 404);
  assert.equal((await instance.handle({ jsonrpc: '2.0', id: 9, method: 'tools/list' }, first)).status, 200);
});

test('closing a session closes its server', async () => {
  const { instance, servers } = gateway();
  const id = await session(instance);

  assert.equal(await instance.closeSession(id), true);
  assert.equal(servers[0].closed, true);
  assert.equal(await instance.closeSession(id), false);
});

test("a tool call during which a page escaped the app gets the guard's refusal instead of its result", async () => {
  const guard = {
    escapes: 0,
    async refusalSince(since) {
      return this.escapes > since ? 'A page was redirected outside the sandbox app' : null;
    },
  };
  const { instance } = gateway({ callText: 'FOREIGN PAGE', gateway: { guard } });
  const id = await session(instance);

  assert.equal((await call(instance, id, 'browser_snapshot', {})).body.result.content[0].text, 'FOREIGN PAGE');

  const escaping = call(instance, id, 'browser_click', { target: 'e1' });
  guard.escapes += 1;
  const { body } = await escaping;

  assert.equal(body.result.isError, true);
  assert.equal(body.result.content[0].text, '### Error\nA page was redirected outside the sandbox app');
  assert.equal((await call(instance, id, 'browser_snapshot', {})).body.result.content[0].text, 'FOREIGN PAGE');
});

test('while a person holds control, a call that changes the page waits for them to hand it back', async () => {
  const lock = new ControlLock();
  const { instance, log } = gateway({ gateway: { lock, agentWaitMs: 5000 } });
  const id = await session(instance);
  lock.acquire('viewer-1', { id: '1', name: 'Ada' });

  const looked = await call(instance, id, 'browser_snapshot', {});
  assert.equal(looked.body.result.isError, undefined, 'a call that only looks goes ahead');

  const before = log.length;
  const clicked = call(instance, id, 'browser_click', { target: 'e2' });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(log.length, before, 'the call has not reached the browser');
  lock.release('viewer-1');

  assert.equal((await clicked).body.result.isError, undefined);
  assert.equal(log.at(-1).params.name, 'browser_click');
});

test('a call that changes the page is refused, naming who drives, when control is not handed back in time', async () => {
  const lock = new ControlLock();
  const { instance, log } = gateway({ gateway: { lock, agentWaitMs: 30 } });
  const id = await session(instance);
  lock.acquire('viewer-1', { id: '1', name: 'Ada' });
  const before = log.length;

  const refused = await call(instance, id, 'browser_navigate', { url: '/orders' });

  assert.equal(refused.body.result.isError, true);
  assert.match(refused.body.result.content[0].text, /Ada is driving this browser by hand and did not hand it back within 0 seconds\. Nothing was done\./);
  const meta = refused.body.result._meta[TAKEOVER_META];
  assert.equal(meta.held_by, 'Ada');
  assert.equal(meta.since, new Date(lock.holder.since).toISOString());
  assert.ok(meta.waited_ms >= 30);
  assert.equal(log.length, before, 'the browser never saw the call');
});

test('a successful call is reported once it is done', async () => {
  const calls = [];
  const { instance } = gateway({ gateway: { afterCall: (name, args) => calls.push([name, args]) } });
  const id = await session(instance);

  await call(instance, id, 'browser_tabs', { action: 'select', index: 1 });
  await call(instance, id, 'browser_run_code_unsafe', { code: '1' });

  assert.deepEqual(calls, [['browser_tabs', { action: 'select', index: 1 }]]);
});
