import http from 'node:http';

import { liveRefusal, refusal } from './guard.mjs';
import { LIVE_PATH } from './live-server.mjs';

// Larger than any tool call the engine sends.
export const MAX_BODY_BYTES = 4 * 1024 * 1024;

function respond(response, status, body, headers = {}) {
  const text = body === undefined ? '' : JSON.stringify(body);
  response.writeHead(status, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
    ...headers,
  });
  response.end(text);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(Object.assign(new Error('The body is too large'), { status: 413 }));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

function pathOf(request) {
  try {
    return new URL(request.url, 'http://sidecar').pathname;
  } catch {
    return null;
  }
}

function rejectUpgrade(socket, status) {
  socket.end(`HTTP/1.1 ${status} ${http.STATUS_CODES[status]}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
}

/**
 * Creates the sidecar's HTTP server:
 *
 *   GET    /health         { status: "ok", version }
 *   POST   /mcp            one JSON-RPC message, answered as JSON (McpGateway)
 *   DELETE /mcp            ends the session named by Mcp-Session-Id
 *   GET    /live           the live view's WebSocket (LiveServer), when `live` is given
 *   GET    /storage-state  the browser's cookies and localStorage for the
 *                          app's origin, so a sign-in can be kept
 *
 * Every request, and every WebSocket upgrade other than the live view's, is
 * checked by guard.refusal before anything else happens. The live view's
 * upgrade is checked by guard.liveRefusal instead, and any other upgrade is
 * refused.
 *
 * @param {object} options
 * @param {() => { token: string, hosts: Set<string>, origins?: Set<string>, liveOrigins?: Set<string> }} options.rules
 *   what the guards check against, read per request since the port is known only once listening
 * @param {{ handle: Function, closeSession: Function }} options.gateway
 * @param {string} options.version
 * @param {{ handleUpgrade: Function } | null} [options.live] a LiveServer
 * @param {() => Promise<object>} [options.storageState] returns what GET /storage-state answers
 * @returns {import('node:http').Server}
 */
export function createHttpServer({ rules, gateway, version, live = null, storageState = null }) {
  const server = http.createServer(async (request, response) => {
    const denied = refusal(request, rules());
    if (denied) return respond(response, denied.status, { error: denied.message });

    const path = new URL(request.url, 'http://sidecar').pathname;
    try {
      if (path === '/health' && request.method === 'GET') return respond(response, 200, { status: 'ok', version });
      if (path === '/storage-state' && request.method === 'GET' && storageState) {
        return respond(response, 200, { storage_state: await storageState() });
      }
      if (path !== '/mcp') return respond(response, 404, { error: 'Not found' });

      const sessionId = request.headers['mcp-session-id'];
      if (request.method === 'DELETE') {
        const closed = typeof sessionId === 'string' && (await gateway.closeSession(sessionId));
        return respond(response, closed ? 200 : 404, closed ? { closed: true } : { error: 'Session not found' });
      }
      if (request.method !== 'POST') return respond(response, 405, { error: 'POST JSON-RPC here' }, { allow: 'POST, DELETE' });

      let message;
      try {
        message = JSON.parse(await readBody(request));
      } catch (error) {
        if (error.status) throw error;
        return respond(response, 400, { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'The body is not JSON' } });
      }

      const result = await gateway.handle(message, typeof sessionId === 'string' ? sessionId : undefined);
      return respond(response, result.status, result.body, result.headers);
    } catch (error) {
      if (!response.headersSent) respond(response, error.status ?? 500, { error: error.status ? error.message : 'Internal error' });
      if (!error.status) process.stderr.write(`browser-sidecar: ${error.stack ?? error}\n`);
    }
  });

  server.on('upgrade', (request, socket, head) => {
    const current = rules();
    if (live && pathOf(request) === LIVE_PATH) {
      const denied = liveRefusal(request, { hosts: current.hosts, origins: current.liveOrigins ?? new Set() });
      if (denied) rejectUpgrade(socket, denied.status);
      else live.handleUpgrade(request, socket, head);
      return;
    }

    rejectUpgrade(socket, (refusal(request, current) ?? { status: 404 }).status);
  });
  server.on('clientError', (_error, socket) => socket.destroy());

  return server;
}
