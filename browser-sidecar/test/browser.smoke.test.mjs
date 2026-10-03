import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { gunzipSync } from 'node:zlib';

import { chromium } from 'playwright';
import { WebSocket } from 'ws';

import { TAKEOVER_META } from '../lib/control-lock.mjs';
import { parseConfig } from '../lib/config.mjs';
import { signTicket, ticketKey } from '../lib/live-ticket.mjs';
import { NetworkPolicy } from '../lib/network-policy.mjs';
import { startSidecar } from '../lib/sidecar.mjs';

// The sidecar end to end with a real Chromium. Skipped when Chromium is not
// installed (`npx playwright install chromium`).
const installed = existsSync(chromium.executablePath());
const skip = !installed && 'Chromium is not installed';
const BIN = new URL('../bin/browser-sidecar.mjs', import.meta.url).pathname;
const TOKEN = 'smoke-browser-token-0123456789abcdef0123';
const SECRET = 'hunter2-typed-password';
const NOTE = 'typed-into-a-rich-text-editor';
const PRIVATE_BODY = 'PRIVATE-SERVICE-SECRET';
const FOREIGN_BODY = 'FOREIGN-ORIGIN-SECRET';

const FIXTURE = `<!doctype html><title>Fixture</title><h1>Orders</h1>
<label>Password <input type="password"></label>
<div role="textbox" aria-label="Notes" contenteditable="true"></div>`;

function listen(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

function origin(server) {
  return `http://127.0.0.1:${server.address().port}`;
}

// An app that serves FIXTURE at /, redirects /r to `redirectTo()`, and
// answers a WebSocket at /cable with one "hello" frame.
async function fixtureApp(redirectTo) {
  const app = await listen((request, response) => {
    if (request.url === '/r') {
      response.writeHead(302, { location: redirectTo() });
      response.end();
      return;
    }
    response.writeHead(200, { 'content-type': 'text/html' });
    response.end(FIXTURE);
  });
  app.on('upgrade', (request, socket) => {
    const accept = createHash('sha1').update(`${request.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: ${accept}\r\n\r\n`);
    socket.write(Buffer.from([0x81, 5, ...Buffer.from('hello')]));
  });
  return app;
}

// A server that counts its requests and answers each with a page of `body`.
async function counted(body) {
  const server = await listen((request, response) => {
    server.hits += 1;
    response.writeHead(200, { 'content-type': 'text/html' });
    response.end(`<!doctype html><title>${body}</title><p>${body}</p>`);
  });
  server.hits = 0;
  return server;
}

function mcpClient(endpoint) {
  let sessionId;
  let nextId = 1;
  const rpc = async (method, params) => {
    const response = await fetch(endpoint, {
      method: 'POST',
      headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', ...(sessionId ? { 'mcp-session-id': sessionId } : {}) },
      body: JSON.stringify({ jsonrpc: '2.0', id: nextId++, method, params }),
    });
    sessionId ??= response.headers.get('mcp-session-id');
    return (await response.json()).result;
  };
  return {
    initialize: () => rpc('initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'smoke', version: '1' } }),
    tools: async () => (await rpc('tools/list', {})).tools.map((tool) => tool.name),
    call: (name, args = {}) => rpc('tools/call', { name, arguments: args }),
  };
}

function text(result) {
  return result.content.map((block) => block.text ?? '').join('\n');
}

// Waits for the page the sidecar opens on start to finish loading, so that
// navigation does not cut the test's first one short.
async function untilAppOpened(mcp) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (text(await mcp.call('browser_tabs', { action: 'list' })).includes('[Fixture]')) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('the app never opened');
}

function chromiumProcesses(profileRoot) {
  return execFileSync('ps', ['-axo', 'args'], { encoding: 'utf8' }).split('\n').filter((line) => line.includes(profileRoot));
}

test('a real browser: guarded, pinned to the app, recorded with masked inputs, gone after SIGTERM', { skip }, async (t) => {
  const privateService = await counted(PRIVATE_BODY);
  const app = await fixtureApp(() => `${origin(privateService)}/`);
  const batches = [];
  const ingest = await listen((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      batches.push(JSON.parse(gunzipSync(Buffer.concat(chunks)).toString()));
      response.writeHead(201);
      response.end('{}');
    });
  });
  const workdir = await mkdtemp(join(tmpdir(), 'sidecar-smoke-'));
  t.after(async () => {
    app.close();
    ingest.close();
    privateService.close();
    await rm(workdir, { recursive: true, force: true });
  });

  const sidecar = spawn(process.execPath, [BIN, 'serve'], { stdio: ['pipe', 'pipe', 'inherit'] });
  t.after(() => sidecar.exitCode === null && sidecar.kill('SIGKILL'));
  sidecar.stdin.end(JSON.stringify({
    token: TOKEN,
    app_url: origin(app),
    workdir,
    recording: { url: `${origin(ingest)}/events`, token: `aarec_${'r'.repeat(32)}` },
  }));
  const ready = await new Promise((resolve, reject) => {
    let output = '';
    sidecar.stdout.on('data', (chunk) => {
      output += chunk;
      if (output.includes('\n')) resolve(JSON.parse(output.split('\n')[0]));
    });
    sidecar.on('exit', (code) => reject(new Error(`the sidecar exited with ${code}`)));
  });
  assert.equal(ready.ready, true);
  const endpoint = `http://127.0.0.1:${ready.port}/mcp`;

  const processes = chromiumProcesses(workdir);
  assert.ok(processes.length > 0, 'Chromium runs with a profile under the workdir');
  assert.ok(processes.some((line) => line.includes('--remote-debugging-pipe')));
  assert.ok(processes.every((line) => !line.includes('--remote-debugging-port')));
  assert.ok(processes.some((line) => line.includes('--proxy-server=http://127.0.0.1:')), 'Chromium connects through the egress proxy');

  assert.equal((await fetch(endpoint, { method: 'POST', body: '{}' })).status, 401);

  const mcp = mcpClient(endpoint);
  await mcp.initialize();
  await untilAppOpened(mcp);

  const tools = await mcp.tools();
  assert.ok(tools.includes('browser_navigate'));
  assert.ok(!tools.includes('browser_run_code_unsafe'));

  assert.equal((await mcp.call('browser_navigate', { url: 'https://example.com/' })).isError, true);

  const redirected = await mcp.call('browser_navigate', { url: '/r' });
  assert.equal(redirected.isError, true, 'a redirect to a private address is an error');
  assert.match(text(redirected), new RegExp(`redirected to ${origin(privateService)}`));
  assert.ok(!JSON.stringify(redirected).includes(PRIVATE_BODY));

  const opened = await mcp.call('browser_navigate', { url: '/' });
  assert.match(text(opened), /heading "Orders"/, 'the snapshot comes back inline');

  const fetched = await mcp.call('browser_evaluate', { function: "() => fetch('/r').then((r) => r.text()).catch((e) => 'failed: ' + e.message)" });
  assert.ok(!JSON.stringify(fetched).includes(PRIVATE_BODY), 'a fetch redirected to a private address gets nothing from it');
  assert.equal(privateService.hits, 0, 'nothing reached the private address');

  const socket = await mcp.call('browser_evaluate', {
    function: `() => new Promise((resolve) => {
      const ws = new WebSocket(location.origin.replace('http', 'ws') + '/cable');
      ws.onmessage = (event) => resolve('received ' + event.data);
      ws.onerror = () => resolve('failed');
    })`,
  });
  assert.match(text(socket), /received hello/, "the app's own WebSocket goes through");

  const candidates = await mcp.call('browser_evaluate', {
    function: `() => new Promise((resolve) => {
      const found = [];
      const peer = new RTCPeerConnection({ iceServers: [{ urls: 'stun:10.0.0.1:3478' }] });
      peer.createDataChannel('probe');
      peer.onicecandidate = (event) => (event.candidate ? found.push(event.candidate.candidate) : resolve(found.join(' | ') || 'none'));
      peer.createOffer().then((offer) => peer.setLocalDescription(offer));
      setTimeout(() => resolve(found.join(' | ') || 'none'), 3000);
    })`,
  });
  assert.doesNotMatch(text(candidates), /udp/i, 'WebRTC gathers no UDP candidates around the proxy');

  const snapshot = text(await mcp.call('browser_snapshot'));
  const password = /textbox "Password" \[ref=([^\]]+)\]/.exec(snapshot)[1];
  const notes = /textbox "Notes" \[ref=([^\]]+)\]/.exec(snapshot)[1];
  await mcp.call('browser_type', { target: password, text: SECRET });
  await mcp.call('browser_type', { target: notes, text: NOTE });
  await new Promise((resolve) => setTimeout(resolve, 500));

  const exited = new Promise((resolve) => sidecar.on('exit', resolve));
  sidecar.kill('SIGTERM');
  assert.equal(await exited, 0);

  assert.deepEqual(await readdir(workdir), [], 'the profile, uploads and output are removed');
  assert.deepEqual(chromiumProcesses(workdir), []);

  const events = batches.flatMap((batch) => batch.recording_events);
  assert.ok(events.some((event) => event.kind === 'rrweb' && event.data.type === 2), 'a full snapshot was recorded');
  assert.ok(events.some((event) => event.kind === 'marker' && event.data.label === 'page_closed'));
  const recorded = JSON.stringify(batches);
  assert.ok(!recorded.includes(SECRET), 'the typed password is masked');
  assert.ok(!recorded.includes(NOTE), 'text typed into a contenteditable element is masked');
});

test('a page redirected off the app is closed, and no tool shows any part of it', { skip }, async (t) => {
  const foreign = await counted(FOREIGN_BODY);
  const app = await fixtureApp(() => `${origin(foreign)}/landing`);
  const workdir = await mkdtemp(join(tmpdir(), 'sidecar-redirect-'));
  const cwd = process.cwd();
  // Every address counts as public here, so the proxy lets the foreign
  // origin through and only the navigation guard stands in the way.
  const policy = new NetworkPolicy({ appOrigin: origin(app), isPrivate: () => false });
  const sidecar = await startSidecar(parseConfig({ token: TOKEN, app_url: origin(app), workdir }), { policy, log: () => {} });
  t.after(async () => {
    await sidecar.close();
    process.chdir(cwd);
    app.close();
    foreign.close();
    await rm(workdir, { recursive: true, force: true });
  });

  const mcp = mcpClient(`http://127.0.0.1:${sidecar.port}/mcp`);
  await mcp.initialize();
  await untilAppOpened(mcp);

  const redirected = await mcp.call('browser_navigate', { url: '/r' });
  assert.equal(redirected.isError, true);
  assert.match(text(redirected), new RegExp(`redirected to ${origin(foreign)}, outside the sandbox app, and was closed`));
  assert.ok(!JSON.stringify(redirected).includes(FOREIGN_BODY));
  assert.equal(foreign.hits, 1, 'Chromium followed the redirect');

  for (const [name, args] of [['browser_tabs', { action: 'list' }], ['browser_network_requests', {}], ['browser_snapshot', {}]]) {
    const result = JSON.stringify(await mcp.call(name, args));
    assert.ok(!result.includes(FOREIGN_BODY) && !result.includes(origin(foreign)), `${name} shows nothing of the closed page`);
  }

  assert.match(text(await mcp.call('browser_navigate', { url: '/' })), /heading "Orders"/, 'the browser goes on to open the app');
});

test('watch live and take over: frames of the page on screen, input from the person in control, agent calls held meanwhile', { skip }, async (t) => {
  const dashboard = 'http://dashboard.test:3000';
  const typed = 'typed-in-the-live-view';
  const app = await fixtureApp(() => '/');
  const batches = [];
  const ingest = await listen((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      batches.push(JSON.parse(gunzipSync(Buffer.concat(chunks)).toString()));
      response.writeHead(201);
      response.end('{}');
    });
  });
  const workdir = await mkdtemp(join(tmpdir(), 'sidecar-live-'));
  const cwd = process.cwd();
  const config = parseConfig({
    token: TOKEN,
    app_url: origin(app),
    workdir,
    recording: { url: `${origin(ingest)}/events`, token: `aarec_${'r'.repeat(32)}` },
    live: { session_id: 'live-session', origins: [dashboard], agent_wait_ms: 200, release_grace_ms: 200 },
  });
  const sidecar = await startSidecar(config, { log: () => {} });
  t.after(async () => {
    await sidecar.close();
    process.chdir(cwd);
    app.close();
    ingest.close();
    await rm(workdir, { recursive: true, force: true });
  });

  const mcp = mcpClient(`http://127.0.0.1:${sidecar.port}/mcp`);
  await mcp.initialize();
  await untilAppOpened(mcp);

  const ws = new WebSocket(`ws://127.0.0.1:${sidecar.port}/live`, { origin: dashboard });
  const received = [];
  ws.on('message', (data) => received.push(JSON.parse(data.toString())));
  await new Promise((resolve, reject) => {
    ws.on('open', resolve);
    ws.on('error', reject);
  });
  const latest = async (type, predicate = () => true) => {
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const found = received.findLast((message) => message.type === type && predicate(message));
      if (found) return found;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`no ${type} message`);
  };
  const iat = Math.floor(Date.now() / 1000);
  ws.send(JSON.stringify({
    type: 'auth',
    ticket: signTicket(ticketKey(TOKEN), { v: 1, sid: 'live-session', sub: '1', name: 'Ada', mode: 'control', iat, exp: iat + 30, jti: 'smoke-ticket-0123456789' }),
  }));

  assert.equal((await latest('ready')).control.held, false);
  const frame = await latest('frame');
  assert.ok(Buffer.from(frame.data, 'base64').subarray(0, 2).equals(Buffer.from([0xff, 0xd8])), 'a frame is a JPEG');
  assert.deepEqual([frame.width, frame.height], [1280, 800]);

  const center = text(await mcp.call('browser_evaluate', {
    function: "() => { const box = document.querySelector('[contenteditable]').getBoundingClientRect(); return `center ${box.x + box.width / 2} ${box.y + box.height / 2}`; }",
  })).match(/center ([\d.]+) ([\d.]+)/);
  const point = { x: Number(center[1]) / frame.width, y: Number(center[2]) / frame.height };

  ws.send(JSON.stringify({
    type: 'take_control',
    ticket: signTicket(ticketKey(TOKEN), { v: 1, sid: 'live-session', sub: '1', name: 'Ada', mode: 'control', iat, exp: iat + 30, jti: 'smoke-ticket-control-0123456789' }),
  }));
  assert.equal((await latest('control')).mine, true);

  const refused = await mcp.call('browser_navigate', { url: '/' });
  assert.equal(refused.isError, true, 'an agent call that changes the page is held, then refused');
  assert.match(text(refused), /Ada is driving this browser by hand/);
  assert.equal(refused._meta[TAKEOVER_META].held_by, 'Ada');
  assert.match(text(await mcp.call('browser_snapshot')), /heading "Orders"/, 'a call that only looks goes ahead');

  ws.send(JSON.stringify({ type: 'mouse', action: 'down', ...point, button: 'left', clickCount: 1 }));
  ws.send(JSON.stringify({ type: 'mouse', action: 'up', ...point, button: 'left', clickCount: 1 }));
  for (const key of 'ab') {
    ws.send(JSON.stringify({ type: 'key', action: 'down', key, code: `Key${key.toUpperCase()}` }));
    ws.send(JSON.stringify({ type: 'key', action: 'up', key, code: `Key${key.toUpperCase()}` }));
  }
  ws.send(JSON.stringify({ type: 'text', text: typed }));
  await new Promise((resolve) => setTimeout(resolve, 300));

  ws.send(JSON.stringify({ type: 'hand_back' }));
  assert.equal((await latest('control', (state) => !state.held)).held, false);
  const entered = text(await mcp.call('browser_evaluate', { function: "() => document.querySelector('[contenteditable]').textContent" }));
  assert.ok(entered.includes(`ab${typed}`), `the person's clicks and keys reached the page: ${entered}`);

  const opened = await mcp.call('browser_tabs', { action: 'new', url: '/' });
  assert.notEqual(opened.isError, true, 'once handed back, the agent drives again');
  assert.equal((await latest('page', (message) => message.page?.tabs === 2)).page.tab, 2, 'the live view follows the new tab');
  await mcp.call('browser_tabs', { action: 'select', index: 0 });
  assert.equal((await latest('page', (message) => message.page?.tab === 1)).page.tabs, 2, 'and the tab the agent selects');

  ws.close();
  await sidecar.close();

  const events = batches.flatMap((batch) => batch.recording_events);
  const takeovers = events.filter((event) => event.kind === 'marker' && event.data.source === 'human');
  assert.deepEqual(takeovers.map((event) => [event.data.label, event.data.user.name]), [['takeover_started', 'Ada'], ['takeover_ended', 'Ada']]);
  assert.ok(!JSON.stringify(batches).includes(typed), 'what the person typed is masked in the recording');
});
