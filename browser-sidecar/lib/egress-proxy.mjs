import http from 'node:http';
import net from 'node:net';

// Headers that belong to one hop and are never passed across the proxy.
const HOP_BY_HOP = new Set([
  'connection', 'proxy-connection', 'keep-alive', 'proxy-authorization', 'proxy-authenticate', 'te', 'trailer', 'transfer-encoding', 'upgrade',
]);

function endToEndHeaders(headers) {
  const named = String(headers.connection ?? '').toLowerCase().split(',').map((name) => name.trim());
  return Object.fromEntries(Object.entries(headers).filter(([name]) => !HOP_BY_HOP.has(name) && !named.includes(name)));
}

// "example.com:443" or "[::1]:8080" as a host and port, or null.
function authority(text) {
  const match = /^(\[[^\]]+\]|[^:]+):(\d{1,5})$/.exec(text ?? '');
  if (!match) return null;
  const port = Number(match[2]);
  return port > 0 && port < 65536 ? { hostname: match[1], port } : null;
}

function refuse(response, status, reason) {
  response.writeHead(status, { 'content-type': 'text/plain; charset=utf-8', connection: 'close' });
  response.end(`Blocked by the sandbox browser: ${reason}\n`);
}

/**
 * Starts the forward proxy every connection the browser opens goes through,
 * and returns once it listens on loopback. Each plain HTTP request and each
 * CONNECT tunnel (HTTPS and WebSockets) is checked with
 * `policy.destination`, and the upstream connection is made to the address
 * that check returned, never to a name resolved again. A refused request is
 * answered 403; a refused tunnel is never opened.
 *
 * @param {object} options
 * @param {{ destination(hostname: string, port: number): Promise<{ address: string | null, refusal: string | null }> }} options.policy
 * @param {(message: string) => void} [options.log]
 * @returns {Promise<{ url: string, close: () => Promise<void> }>}
 */
export async function startEgressProxy({ policy, log = () => {} }) {
  const agent = new http.Agent({ keepAlive: true });
  const sockets = new Set();
  const track = (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  };

  const server = http.createServer(async (request, response) => {
    let target;
    try {
      target = new URL(request.url);
    } catch {
      return refuse(response, 400, 'not a proxy request');
    }
    if (target.protocol !== 'http:') return refuse(response, 400, `${target.protocol} requests are not proxied`);

    const port = Number(target.port || 80);
    const { address, refusal } = await policy.destination(target.hostname, port);
    if (refusal) {
      log(`refused a request: ${refusal}`);
      return refuse(response, 403, refusal);
    }

    const upstream = http.request({
      host: address,
      port,
      method: request.method,
      path: `${target.pathname}${target.search}`,
      headers: endToEndHeaders(request.headers),
      setHost: false,
      agent,
    });
    upstream.on('response', (answer) => {
      response.writeHead(answer.statusCode, answer.statusMessage, endToEndHeaders(answer.headers));
      answer.pipe(response);
    });
    upstream.on('error', (error) => {
      if (response.headersSent) response.destroy();
      else refuse(response, 502, `${target.host} could not be reached (${error.code ?? error.message})`);
    });
    response.on('close', () => {
      if (!response.writableFinished) upstream.destroy();
    });
    request.pipe(upstream);
  });

  server.on('connection', track);
  server.on('connect', async (request, socket, head) => {
    socket.on('error', () => {});
    const requested = authority(request.url);
    const { address, refusal } = requested
      ? await policy.destination(requested.hostname, requested.port)
      : { address: null, refusal: `${request.url} is not a host and port` };
    if (refusal) {
      log(`refused a connection: ${refusal}`);
      socket.end('HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\nconnection: close\r\n\r\n');
      return;
    }

    const upstream = net.connect(requested.port, address);
    track(upstream);
    upstream.on('error', () => socket.destroy());
    socket.on('close', () => upstream.destroy());
    upstream.once('connect', () => {
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length > 0) upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });

  return {
    url: `http://127.0.0.1:${server.address().port}`,
    close: async () => {
      await new Promise((resolve) => {
        server.close(() => resolve());
        for (const socket of sockets) socket.destroy();
      });
      agent.destroy();
    },
  };
}
