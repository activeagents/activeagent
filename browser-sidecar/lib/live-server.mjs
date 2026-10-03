import { randomUUID } from 'node:crypto';

import { WebSocket, WebSocketServer } from 'ws';

import { inputCommand } from './input.mjs';

export const LIVE_PATH = '/live';

// The close codes a viewer is told why it was disconnected with. The 4xxx
// codes are this protocol's own.
export const CLOSE_CODES = Object.freeze({
  stopping: 1001,
  unauthorized: 4401,
  authTimeout: 4408,
  full: 4429,
});

const AUTH_TIMEOUT_MS = 5000;
const MAX_MESSAGE_BYTES = 64 * 1024;
const MAX_CONNECTIONS = 8;
// A viewer whose socket holds more than this unsent misses frames until it
// has caught up, and is then sent the latest one.
const MAX_BUFFERED_BYTES = 2 * 1024 * 1024;
const CATCH_UP_MS = 250;
const TERMINATE_AFTER_MS = 1000;
const INPUT_TYPES = new Set(['mouse', 'wheel', 'key', 'text']);

function parse(data, isBinary) {
  if (isBinary) return null;
  try {
    const message = JSON.parse(data.toString('utf8'));
    return message && typeof message === 'object' && !Array.isArray(message) ? message : null;
  } catch {
    return null;
  }
}

/**
 * Used to serve the live view: the page on screen as a stream of frames to
 * everyone watching, and the input of the one person who holds control
 * (ControlLock) relayed to it.
 *
 * A connection proves who it is with the ticket in its first message
 * (TicketVerifier), and is closed with CLOSE_CODES.unauthorized, before
 * anything is sent to it, when that message is anything else. A view ticket
 * lets it watch; a control ticket also lets it take control.
 *
 * Viewer to sidecar, as JSON text:
 *   { type: "auth", ticket }            first, and only first
 *   { type: "take_control", ticket? }   a control ticket turns a watching connection into one that may take control
 *   { type: "hand_back" }
 *   mouse, wheel, key and text input    see input.mjs; dropped unless this connection holds control
 *
 * Sidecar to viewer:
 *   { type: "ready", can_control, control, agent, page }   once the ticket is accepted
 *   { type: "frame", data, width, height }                  a JPEG as base64, and the page's size in CSS pixels
 *   { type: "control", held, mine, by, since }              who holds control, by name
 *   { type: "agent", waiting, tool, since }                 an agent's call is waiting for control to be handed back
 *   { type: "page", page: { url, tab, tabs } }              the page on screen changed
 *   { type: "error", code, message }                        a request this connection may not make
 *
 * Relayed input is never logged or recorded. Taking and handing back
 * control are, through `onMarker`.
 */
export class LiveServer {
  /**
   * @param {object} options
   * @param {{ verify(ticket: unknown): object }} options.verifier a TicketVerifier
   * @param {import('./control-lock.mjs').ControlLock} options.lock
   * @param {import('./screencast.mjs').Screencast} options.screencast
   * @param {(data: object) => void} [options.onMarker] given a takeover's start and end, to record
   * @param {(message: string) => void} [options.log]
   * @param {number} [options.authTimeoutMs] how long a connection may take to send its ticket
   * @param {number} [options.maxConnections]
   */
  constructor({ verifier, lock, screencast, onMarker = () => {}, log = () => {}, authTimeoutMs = AUTH_TIMEOUT_MS, maxConnections = MAX_CONNECTIONS }) {
    this.verifier = verifier;
    this.lock = lock;
    this.screencast = screencast;
    this.onMarker = onMarker;
    this.log = log;
    this.authTimeoutMs = authTimeoutMs;
    this.maxConnections = maxConnections;
    this.wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES, perMessageDeflate: false });
    this.connections = new Set();
    this.viewers = new Map();
    this.catchUp = null;
    this.closed = false;

    lock.on('change', (holder, previous, reason) => this.controlChanged(holder, previous, reason));
    lock.on('agent_waiting', () => this.broadcast({ type: 'agent', ...this.agentState() }));
    lock.on('agent_done', () => this.broadcast({ type: 'agent', ...this.agentState() }));
  }

  /**
   * Accepts a WebSocket upgrade that guard.liveRefusal let through.
   *
   * @param {import('node:http').IncomingMessage} request
   * @param {import('node:stream').Duplex} socket
   * @param {Buffer} head
   */
  handleUpgrade(request, socket, head) {
    if (this.closed) {
      socket.destroy();
      return;
    }
    this.wss.handleUpgrade(request, socket, head, (ws) => this.accept(ws));
  }

  accept(ws) {
    ws.on('error', () => {});
    if (this.connections.size >= this.maxConnections) {
      ws.close(CLOSE_CODES.full, 'Too many viewers');
      return;
    }

    this.connections.add(ws);
    const timer = setTimeout(() => ws.close(CLOSE_CODES.authTimeout, 'No ticket'), this.authTimeoutMs);
    timer.unref?.();
    ws.once('message', (data, isBinary) => {
      clearTimeout(timer);
      this.authenticate(ws, parse(data, isBinary));
    });
    ws.on('close', () => {
      clearTimeout(timer);
      this.connections.delete(ws);
      this.leave(ws);
    });
  }

  authenticate(ws, message) {
    const result = message?.type === 'auth' ? this.verifier.verify(message.ticket) : { refusal: 'no ticket first' };
    if (result.refusal) {
      this.log(`live view: refused a viewer (${result.refusal})`);
      ws.close(CLOSE_CODES.unauthorized, result.refusal);
      return;
    }

    const { sub, name, mode } = result.claims;
    const viewer = { id: randomUUID(), ws, user: { id: sub, name }, canControl: mode === 'control', behind: false };
    this.viewers.set(ws, viewer);
    ws.on('message', (data, isBinary) => this.receive(viewer, parse(data, isBinary)));

    this.send(viewer, { type: 'ready', can_control: viewer.canControl, control: this.controlState(viewer), agent: this.agentState(), page: this.screencast.pageInfo });
    if (this.screencast.lastFrame) this.sendFrame(viewer, JSON.stringify(frameMessage(this.screencast.lastFrame)));
    void this.screencast.start();
  }

  receive(viewer, message) {
    if (!message) return;

    if (message.type === 'take_control') this.takeControl(viewer, message.ticket);
    else if (message.type === 'hand_back') this.lock.release(viewer.id);
    else if (INPUT_TYPES.has(message.type)) this.relay(viewer, message);
  }

  takeControl(viewer, ticket) {
    if (!viewer.canControl && ticket !== undefined) {
      const { claims } = this.verifier.verify(ticket);
      viewer.canControl = claims?.mode === 'control' && claims.sub === viewer.user.id;
    }
    if (!viewer.canControl) {
      this.send(viewer, { type: 'error', code: 'view_only', message: 'This view can watch the browser but not take it over' });
      return;
    }

    const { taken, holder } = this.lock.acquire(viewer.id, viewer.user);
    if (!taken) this.send(viewer, { type: 'error', code: 'held', message: `${holder?.user.name ?? 'Someone else'} is driving the browser` });
  }

  relay(viewer, message) {
    if (this.lock.holder?.key !== viewer.id) return;

    const command = inputCommand(message, this.screencast.metadata);
    if (!command) return;
    this.screencast.dispatch(...command).catch(() => this.log(`live view: ${command[0]} was not delivered`));
  }

  leave(ws) {
    const viewer = this.viewers.get(ws);
    if (!viewer) return;

    this.viewers.delete(ws);
    this.lock.disconnected(viewer.id);
    if (this.viewers.size === 0) void this.screencast.stop();
  }

  controlState(viewer) {
    const holder = this.lock.holder;
    if (!holder) return { held: false, mine: false, by: null, since: null };
    return { held: true, mine: holder.key === viewer.id, by: holder.user.name, since: holder.since };
  }

  agentState() {
    const waiting = this.lock.agentWaiting;
    return waiting ? { waiting: true, tool: waiting.tool, since: waiting.since } : { waiting: false, tool: null, since: null };
  }

  // Control moving between connections of one user is no takeover of its own.
  controlChanged(holder, previous, reason) {
    for (const viewer of this.viewers.values()) this.send(viewer, { type: 'control', ...this.controlState(viewer) });

    if (holder && !previous) this.onMarker({ label: 'takeover_started', source: 'human', user: holder.user });
    else if (!holder && previous) this.onMarker({ label: 'takeover_ended', source: 'human', user: previous.user, reason });
  }

  /**
   * Sends a frame the screencast produced to everyone watching.
   *
   * @param {{ data: string, metadata: object }} frame
   */
  frame(frame) {
    const text = JSON.stringify(frameMessage(frame));
    for (const viewer of this.viewers.values()) this.sendFrame(viewer, text);
  }

  // Tells everyone watching which page is on screen.
  pageChanged() {
    this.broadcast({ type: 'page', page: this.screencast.pageInfo });
  }

  sendFrame(viewer, text) {
    if (viewer.ws.readyState !== WebSocket.OPEN) return;
    if (viewer.ws.bufferedAmount > MAX_BUFFERED_BYTES) {
      viewer.behind = true;
      this.scheduleCatchUp();
      return;
    }
    viewer.behind = false;
    viewer.ws.send(text);
  }

  scheduleCatchUp() {
    if (this.catchUp) return;

    this.catchUp = setInterval(() => {
      const behind = [...this.viewers.values()].filter((viewer) => viewer.behind);
      if (behind.length === 0 || !this.screencast.lastFrame) {
        clearInterval(this.catchUp);
        this.catchUp = null;
        return;
      }
      const text = JSON.stringify(frameMessage(this.screencast.lastFrame));
      for (const viewer of behind) this.sendFrame(viewer, text);
    }, CATCH_UP_MS);
    this.catchUp.unref?.();
  }

  send(viewer, message) {
    if (viewer.ws.readyState === WebSocket.OPEN) viewer.ws.send(JSON.stringify(message));
  }

  broadcast(message) {
    for (const viewer of this.viewers.values()) this.send(viewer, message);
  }

  // Ends every connection and releases control, refusing the agent calls
  // still waiting for it: the browser is stopping.
  close() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.catchUp);
    this.catchUp = null;

    this.lock.close();
    for (const ws of this.connections) {
      ws.close(CLOSE_CODES.stopping, 'The browser stopped');
      setTimeout(() => ws.terminate(), TERMINATE_AFTER_MS).unref?.();
    }
    this.wss.close();
  }
}

function frameMessage({ data, metadata }) {
  return { type: 'frame', data, width: metadata.deviceWidth, height: metadata.deviceHeight };
}
