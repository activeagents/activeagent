import { randomUUID } from 'node:crypto';
import { readFile, realpath } from 'node:fs/promises';
import { sep } from 'node:path';

// Never offered and never called: browser_run_code_unsafe runs JavaScript in
// this process, where the tokens are.
export const DENIED_TOOLS = new Set(['browser_run_code_unsafe']);

// The tool argument holding the URL a tool opens, for the tools that open one.
const NAVIGATION_ARGUMENTS = {
  browser_navigate: () => 'url',
  browser_tabs: (args) => (args.action === 'new' && args.url !== undefined ? 'url' : null),
};

const JSONRPC = '2.0';
// A page snapshot an action wrote to a file, and how much of one is inlined.
const SNAPSHOT_LINK = /(?:- )?\[Snapshot\]\(([^)\n]+)\)/g;
const SNAPSHOT_LIMIT = 256 * 1024;

function rpcError(id, code, message) {
  return { jsonrpc: JSONRPC, id: id ?? null, error: { code, message } };
}

function toolError(id, text) {
  return { jsonrpc: JSONRPC, id, result: { content: [{ type: 'text', text: `### Error\n${text}` }], isError: true } };
}

function isRequest(message) {
  return typeof message.method === 'string' && message.id !== undefined && message.id !== null;
}

// The server side of one MCP session, held in memory: a request goes in
// through `request` and its response comes back through the server's call to
// `send`.
// Notifications and requests the server sends on its own are dropped, since
// a JSON response has nowhere to carry them.
class MemoryTransport {
  constructor(timeoutMs) {
    this.timeoutMs = timeoutMs;
    this.pending = new Map();
  }

  async start() {}

  async send(message) {
    const isResponse = message && message.id !== undefined && ('result' in message || 'error' in message);
    if (!isResponse) return;

    const waiter = this.pending.get(message.id);
    if (!waiter) return;
    this.pending.delete(message.id);
    clearTimeout(waiter.timer);
    waiter.resolve(message);
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    for (const [id, waiter] of this.pending) {
      clearTimeout(waiter.timer);
      waiter.resolve(rpcError(id, -32000, 'The session closed'));
    }
    this.pending.clear();
    this.onclose?.();
  }

  request(message) {
    if (this.closed) return Promise.resolve(rpcError(message.id, -32000, 'The session closed'));
    if (this.pending.has(message.id)) return Promise.resolve(rpcError(message.id, -32600, 'A request with this id is in flight'));

    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(message.id);
        resolve(rpcError(message.id, -32001, 'The request timed out'));
      }, this.timeoutMs);
      this.pending.set(message.id, { resolve, timer });
      this.onmessage?.(message);
    });
  }

  notify(message) {
    this.onmessage?.(message);
  }
}

/**
 * Used to serve MCP over plain JSON responses: each POST carries one JSON-RPC
 * message and gets the response back as the body.
 *
 * Every session gets its own server from `connect`, all of them driving the
 * same browser. The gateway reads each message on its way in and out, so a
 * denied tool is neither listed nor called, a navigation is checked against
 * the network policy before it reaches the browser, and the client declares
 * no capability the server would call back for (such as roots, which would
 * move where files are read from).
 *
 * Playwright MCP writes the page snapshot an action produces to a file and
 * answers with a link to it, which a client on another machine cannot open.
 * With `snapshotDir` set, a link to a file in that directory is replaced by
 * the snapshot itself.
 *
 * With `guard` set, a tool call during which a page was redirected off the
 * app gets an error instead of its result, which could describe that page.
 */
export class McpGateway {
  /**
   * @param {object} options
   * @param {() => Promise<{ connect(transport: object): Promise<void>, close(): Promise<void> }>} options.connect
   *   returns a new MCP server for a session
   * @param {{ navigationTarget(url: string): { url: string, refusal: string | null } }} options.policy
   * @param {Set<string>} [options.deniedTools]
   * @param {number} [options.maxSessions] sessions kept at once; the least recently used idle one is closed for a new one
   * @param {number} [options.idleMs] how long an unused session is kept
   * @param {number} [options.requestTimeoutMs] how long a request may take
   * @param {string} [options.snapshotDir] the real path of the directory snapshots are written to
   * @param {{ escapes: number, refusalSince(since: number): Promise<string | null> }} [options.guard] a NavigationGuard
   */
  constructor({
    connect, policy, deniedTools = DENIED_TOOLS, maxSessions = 8, idleMs = 30 * 60_000, requestTimeoutMs = 120_000, snapshotDir = null,
    guard = null,
  }) {
    this.connect = connect;
    this.policy = policy;
    this.guard = guard;
    this.snapshotDir = snapshotDir;
    this.deniedTools = deniedTools;
    this.maxSessions = maxSessions;
    this.idleMs = idleMs;
    this.requestTimeoutMs = requestTimeoutMs;
    this.sessions = new Map();
    this.uses = 0;
  }

  /**
   * Answers one POSTed message.
   *
   * @param {unknown} message the parsed body
   * @param {string | undefined} sessionId the Mcp-Session-Id header
   * @returns {Promise<{ status: number, headers?: object, body?: object }>}
   */
  async handle(message, sessionId) {
    if (!message || typeof message !== 'object' || Array.isArray(message) || message.jsonrpc !== JSONRPC) {
      return { status: 400, body: rpcError(null, -32600, 'The body must be one JSON-RPC 2.0 message') };
    }

    if (message.method === 'initialize') return this.initialize(message);

    if (!sessionId) return { status: 400, body: rpcError(message.id, -32600, 'Mcp-Session-Id header is required') };
    const session = this.sessions.get(sessionId);
    if (!session) return { status: 404, body: rpcError(message.id, -32001, 'Session not found') };

    if (!isRequest(message)) {
      if (typeof message.method === 'string') session.transport.notify(message);
      return { status: 202 };
    }

    const inbound = this.inbound(message);
    if (inbound.answer) return { status: 200, body: inbound.answer };

    this.touch(session);
    session.busy += 1;
    const escapes = this.guard?.escapes ?? 0;
    try {
      const response = await session.transport.request(inbound.message);
      const refusal = message.method === 'tools/call' ? await this.guard?.refusalSince(escapes) : null;
      if (refusal) return { status: 200, body: toolError(message.id, refusal) };

      return { status: 200, body: await this.outbound(message, response) };
    } finally {
      session.busy -= 1;
      this.touch(session);
    }
  }

  async initialize(message) {
    if (!isRequest(message)) return { status: 400, body: rpcError(null, -32600, 'initialize must be a request') };
    this.closeIdleSessions();
    if (this.sessions.size >= this.maxSessions && !this.closeLeastRecentlyUsed()) {
      return { status: 503, body: rpcError(message.id, -32000, 'Too many sessions are busy; try again shortly') };
    }

    const server = await this.connect();
    const transport = new MemoryTransport(this.requestTimeoutMs);
    await server.connect(transport);

    const id = randomUUID();
    const session = { server, transport, busy: 1 };
    this.touch(session);
    this.sessions.set(id, session);
    try {
      const params = { ...(message.params ?? {}), capabilities: {} };
      const response = await transport.request({ ...message, params });
      if (response.error) {
        await this.closeSession(id);
        return { status: 200, body: response };
      }
      return { status: 200, headers: { 'mcp-session-id': id }, body: response };
    } finally {
      session.busy -= 1;
    }
  }

  // The message as the server should see it, or the answer to give without
  // asking the server at all.
  inbound(message) {
    if (message.method !== 'tools/call') return { message };

    const name = message.params?.name;
    if (this.deniedTools.has(name)) return { answer: toolError(message.id, `The ${name} tool is not available in this browser`) };

    const args = { ...(message.params?.arguments ?? {}) };
    // _meta can move the directory file names resolve against.
    delete args._meta;

    const argument = NAVIGATION_ARGUMENTS[name]?.(args);
    if (argument) {
      const target = this.policy.navigationTarget(args[argument]);
      if (target.refusal) return { answer: toolError(message.id, target.refusal) };
      args[argument] = target.url;
    }

    return { message: { ...message, params: { ...message.params, arguments: args } } };
  }

  async outbound(request, response) {
    if (request.method === 'tools/list' && Array.isArray(response.result?.tools)) {
      const tools = response.result.tools.filter((tool) => !this.deniedTools.has(tool.name));
      return { ...response, result: { ...response.result, tools } };
    }
    if (request.method === 'tools/call' && this.snapshotDir && Array.isArray(response.result?.content)) {
      const content = await Promise.all(response.result.content.map((block) => this.inlineSnapshots(block)));
      return { ...response, result: { ...response.result, content } };
    }
    return response;
  }

  async inlineSnapshots(block) {
    if (block?.type !== 'text' || typeof block.text !== 'string' || !block.text.includes('[Snapshot](')) return block;

    const snapshots = new Map();
    for (const [, path] of block.text.matchAll(SNAPSHOT_LINK)) snapshots.set(path, await this.readSnapshot(path));

    const text = block.text.replace(SNAPSHOT_LINK, (link, path) => {
      const snapshot = snapshots.get(path);
      return snapshot === null ? link : `\`\`\`yaml\n${snapshot}\n\`\`\``;
    });
    return { ...block, text };
  }

  // The snapshot at `path`, cut to SNAPSHOT_LIMIT, or null when the path is
  // not a file in snapshotDir.
  async readSnapshot(path) {
    try {
      const resolved = await realpath(path);
      if (!resolved.startsWith(`${this.snapshotDir}${sep}`)) return null;

      const text = await readFile(resolved, 'utf8');
      return text.length > SNAPSHOT_LIMIT ? `${text.slice(0, SNAPSHOT_LIMIT)}\n# … (truncated, ${text.length} characters in all)` : text;
    } catch {
      return null;
    }
  }

  // lastUsed is when, for the idle timeout; use orders sessions by recency,
  // which two uses in the same millisecond still tell apart.
  touch(session) {
    session.lastUsed = Date.now();
    session.use = ++this.uses;
  }

  closeIdleSessions() {
    const cutoff = Date.now() - this.idleMs;
    for (const [id, session] of this.sessions) {
      if (session.busy === 0 && session.lastUsed < cutoff) void this.closeSession(id);
    }
  }

  closeLeastRecentlyUsed() {
    const idle = [...this.sessions].filter(([, session]) => session.busy === 0).sort(([, a], [, b]) => a.use - b.use);
    if (idle.length === 0) return false;

    void this.closeSession(idle[0][0]);
    return true;
  }

  /**
   * Closes one session's server. The browser stays open.
   *
   * @param {string} id
   * @returns {Promise<boolean>} whether there was such a session
   */
  async closeSession(id) {
    const session = this.sessions.get(id);
    if (!session) return false;

    this.sessions.delete(id);
    await session.server.close().catch(() => {});
    await session.transport.close();
    return true;
  }

  async closeAll() {
    await Promise.all([...this.sessions.keys()].map((id) => this.closeSession(id)));
  }
}
