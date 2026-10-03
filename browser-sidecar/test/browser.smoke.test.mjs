import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { gunzipSync } from 'node:zlib';

import { chromium } from 'playwright';

// The sidecar end to end with a real Chromium, run as the engine runs it.
// Skipped when Chromium is not installed (`npx playwright install chromium`).
const installed = existsSync(chromium.executablePath());
const BIN = new URL('../bin/browser-sidecar.mjs', import.meta.url).pathname;
const TOKEN = 'smoke-browser-token-0123456789abcdef0123';
const SECRET = 'hunter2-typed-password';

function listen(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

function chromiumProcesses(profileRoot) {
  return execFileSync('ps', ['-axo', 'args'], { encoding: 'utf8' }).split('\n').filter((line) => line.includes(profileRoot));
}

test('a real browser: guarded, pinned to the app, recorded with masked inputs, gone after SIGTERM', { skip: !installed && 'Chromium is not installed' }, async (t) => {
  const app = await listen((request, response) => {
    response.writeHead(200, { 'content-type': 'text/html' });
    response.end('<!doctype html><title>Fixture</title><h1>Orders</h1><label>Password <input type="password"></label>');
  });
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
    await rm(workdir, { recursive: true, force: true });
  });

  const sidecar = spawn(process.execPath, [BIN, 'serve'], { stdio: ['pipe', 'pipe', 'inherit'] });
  t.after(() => sidecar.exitCode === null && sidecar.kill('SIGKILL'));
  sidecar.stdin.end(JSON.stringify({
    token: TOKEN,
    app_url: `http://127.0.0.1:${app.address().port}`,
    workdir,
    recording: { url: `http://127.0.0.1:${ingest.address().port}/events`, token: `aarec_${'r'.repeat(32)}` },
  }));
  const ready = await new Promise((resolve, reject) => {
    let text = '';
    sidecar.stdout.on('data', (chunk) => {
      text += chunk;
      if (text.includes('\n')) resolve(JSON.parse(text.split('\n')[0]));
    });
    sidecar.on('exit', (code) => reject(new Error(`the sidecar exited with ${code}`)));
  });
  assert.equal(ready.ready, true);
  const endpoint = `http://127.0.0.1:${ready.port}/mcp`;

  const processes = chromiumProcesses(workdir);
  assert.ok(processes.length > 0, 'Chromium runs with a profile under the workdir');
  assert.ok(processes.some((line) => line.includes('--remote-debugging-pipe')));
  assert.ok(processes.every((line) => !line.includes('--remote-debugging-port')));

  assert.equal((await fetch(endpoint, { method: 'POST', body: '{}' })).status, 401);

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
  await rpc('initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'smoke', version: '1' } });

  const tools = (await rpc('tools/list', {})).tools.map((tool) => tool.name);
  assert.ok(tools.includes('browser_navigate'));
  assert.ok(!tools.includes('browser_run_code_unsafe'));

  const refused = await rpc('tools/call', { name: 'browser_navigate', arguments: { url: 'https://example.com/' } });
  assert.equal(refused.isError, true);

  const opened = await rpc('tools/call', { name: 'browser_navigate', arguments: { url: '/' } });
  assert.match(opened.content[0].text, /heading "Orders"/, 'the snapshot comes back inline');

  const snapshot = (await rpc('tools/call', { name: 'browser_snapshot', arguments: {} })).content[0].text;
  const ref = /textbox "Password" \[ref=([^\]]+)\]/.exec(snapshot)[1];
  await rpc('tools/call', { name: 'browser_type', arguments: { target: ref, text: SECRET } });
  await new Promise((resolve) => setTimeout(resolve, 500));

  const exited = new Promise((resolve) => sidecar.on('exit', resolve));
  sidecar.kill('SIGTERM');
  assert.equal(await exited, 0);

  assert.deepEqual(await readdir(workdir), [], 'the profile, uploads and output are removed');
  assert.deepEqual(chromiumProcesses(workdir), []);

  const events = batches.flatMap((batch) => batch.recording_events);
  assert.ok(events.some((event) => event.kind === 'rrweb' && event.data.type === 2), 'a full snapshot was recorded');
  assert.ok(events.some((event) => event.kind === 'marker' && event.data.label === 'page_closed'));
  assert.ok(!JSON.stringify(batches).includes(SECRET), 'the typed password is masked');
});
