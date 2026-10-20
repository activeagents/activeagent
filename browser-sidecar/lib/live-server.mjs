import { randomUUID } from 'node:crypto';

import { WebSocket, WebSocketServer } from 'ws';

import { sameUser } from './control-lock.mjs';
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
const UPLOAD_TYPES = new Set(['file_upload', 'file_chunk', 'file_cancel']);

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
 * anything is sent to it, when that message is anything else. Either mode of
 * ticket lets it watch. Each request to take control carries a control
 * ticket of its own, issued to the same user.
 *
 * Viewer to sidecar, as JSON text:
 *   { type: "auth", ticket }            first, and only first
 *   { type: "take_control", ticket }    a control ticket issued to the user the connection authenticated as
 *   { type: "hand_back" }
 *   mouse, wheel, key and text input    see input.mjs; dropped unless this connection holds control
 *   { type: "file_upload", chooser, files: [{ name, size }] }   answers the file chooser on offer (FileChooserRelay);
 *   { type: "file_chunk", chooser, data }                       then its files' bytes, in order, base64, at most
 *                                                               32 KiB each before encoding
 *   { type: "file_cancel", chooser }                            refused unless this connection holds control
 *
 * Sidecar to viewer:
 *   { type: "ready", control, agent, page, file_chooser, person_request }   once the ticket is accepted
 *   { type: "frame", data, width, height }                  a JPEG as base64, and the page's size in CSS pixels
 *   { type: "control", held, mine, yours, by, since }       who holds control, by name; mine when this
 *                                                           connection does, yours when its user does on any
 *   { type: "agent", waiting, tool, since, client }         an agent's call is waiting for control to be handed back;
 *                                                           client names the agent ("Claude Code · turn 3"), or null
 *   { type: "person_requested", request }                   an agent asked for a person to take over:
 *                                                           { reason, client, at }, or null once someone does
 *   { type: "page", page: { url, tab, tabs } }              the page on screen changed
 *   { type: "file_chooser", chooser }                       the page asked the person driving for files:
 *                                                           { id, multiple, accept, since, max_files,
 *                                                           max_file_bytes }, or null once answered or withdrawn
 *   { type: "file_upload", chooser, status, received, total, code, message }
 *                                                           to the uploader: "progress", "done" or "failed"
 *   { type: "error", code, message }                        a request this connection may not make
 *
 * Relayed input is never logged or recorded, nor are the files a person
 * uploads. Taking and handing back control are, through `onMarker`, and so
 * is an upload's file count and size.
 */
export class LiveServer {
  /**
   * @param {object} options
   * @param {{ verify(ticket: unknown): object }} options.verifier a TicketVerifier
   * @param {import('./control-lock.mjs').ControlLock} options.lock
   * @param {import('./screencast.mjs').Screencast} options.screencast
   * @param {import('./file-upload.mjs').FileChooserRelay} [options.uploads] answers pages' file choosers
   * @param {(data: object) => void} [options.onMarker] given a takeover's start and end, to record
   * @param {(message: string) => void} [options.log]
   * @param {number} [options.authTimeoutMs] how long a connection may take to send its ticket
   * @param {number} [options.maxConnections]
   */
  constructor({ verifier, lock, screencast, uploads = null, onMarker = () => {}, log = () => {}, authTimeoutMs = AUTH_TIMEOUT_MS, maxConnections = MAX_CONNECTIONS }) {
    this.verifier = verifier;
    this.lock = lock;
    this.screencast = screencast;
    this.uploads = uploads;
    this.onMarker = onMarker;
    this.log = log;
    this.authTimeoutMs = authTimeoutMs;
    this.maxConnections = maxConnections;
    this.wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES, perMessageDeflate: false });
    this.connections = new Set();
    this.viewers = new Map();
    this.catchUp = null;
    this.closed = false;
    this.personRequest = null;

    lock.on('change', (holder, previous, reason) => this.controlChanged(holder, previous, reason));
    lock.on('agent_waiting', () => this.broadcast({ type: 'agent', ...this.agentState() }));
    lock.on('agent_done', () => this.broadcast({ type: 'agent', ...this.agentState() }));
    uploads?.on('change', (chooser) => this.broadcast({ type: 'file_chooser', chooser }));
    uploads?.on('unavailable', ({ reason }) => {
      const holder = this.holderViewer();
      if (holder) this.send(holder, { type: 'error', code: 'uploads_off', message: reason });
    });
    uploads?.on('progress', ({ id, key, received, total }) => {
      const viewer = [...this.viewers.values()].find((candidate) => candidate.id === key);
      if (viewer) this.send(viewer, { type: 'file_upload', chooser: id, status: 'progress', received, total });
    });
    uploads?.on('uploaded', ({ user, files, bytes }) => this.onMarker({ label: 'file_uploaded', source: 'human', user, files, bytes }));
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

    const { sub, name } = result.claims;
    const viewer = { id: randomUUID(), ws, user: { id: sub, name }, behind: false };
    this.viewers.set(ws, viewer);
    ws.on('message', (data, isBinary) => this.receive(viewer, parse(data, isBinary)));

    this.send(viewer, {
      type: 'ready', control: this.controlState(viewer), agent: this.agentState(), page: this.screencast.pageInfo,
      file_chooser: this.uploads?.state ?? null, person_request: this.personRequest,
    });
    if (this.screencast.lastFrame) this.sendFrame(viewer, JSON.stringify(frameMessage(this.screencast.lastFrame)));
    void this.screencast.start();
  }

  receive(viewer, message) {
    if (!message) return;

    if (message.type === 'take_control') this.takeControl(viewer, message.ticket);
    else if (message.type === 'hand_back') this.lock.release(viewer.id);
    else if (INPUT_TYPES.has(message.type)) this.relay(viewer, message);
    else if (UPLOAD_TYPES.has(message.type)) void this.answerChooser(viewer, message);
  }

  // A ticket per request, rather than one per connection, means a person
  // whose permission is withdrawn cannot take control again on a connection
  // they opened before.
  takeControl(viewer, ticket) {
    const { claims } = this.verifier.verify(ticket);
    if (claims?.mode !== 'control' || claims.sub !== viewer.user.id) {
      this.send(viewer, { type: 'error', code: 'view_only', message: 'Taking over this browser needs a control ticket issued to you' });
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

  // A file chooser's answer, from the person driving: its files, their
  // bytes, or a cancel. The relay refuses anyone else.
  async answerChooser(viewer, message) {
    if (!this.uploads) {
      this.send(viewer, { type: 'error', code: 'uploads_off', message: 'File uploads are turned off for this browser' });
      return;
    }

    const chooser = typeof message.chooser === 'string' ? message.chooser : null;
    try {
      if (message.type === 'file_cancel') {
        await this.uploads.cancel(viewer.id, chooser);
        return;
      }
      const result = message.type === 'file_upload'
        ? await this.uploads.begin(viewer.id, { chooser, files: message.files })
        : await this.uploads.chunk(viewer.id, { chooser, data: message.data });
      if (result.done) this.send(viewer, { type: 'file_upload', chooser, status: 'done' });
    } catch (error) {
      if (!error.code) this.log(`live view: an upload failed: ${error.message}`);
      this.send(viewer, {
        type: 'file_upload', chooser, status: 'failed', code: error.code ?? 'upload_failed',
        message: error.code ? error.message : 'The upload failed',
      });
    }
  }

  holderViewer() {
    const key = this.lock.holder?.key;
    return key ? [...this.viewers.values()].find((viewer) => viewer.id === key) ?? null : null;
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
    if (!holder) return { held: false, mine: false, yours: false, by: null, since: null };

    const mine = holder.key === viewer.id;
    return { held: true, mine, yours: mine || sameUser(holder.user, viewer.user), by: holder.user.name, since: holder.since };
  }

  agentState() {
    const waiting = this.lock.agentWaiting;
    return waiting
      ? { waiting: true, tool: waiting.tool, since: waiting.since, client: waiting.client ?? null }
      : { waiting: false, tool: null, since: null, client: null };
  }

  /**
   * Tells everyone watching that an agent asked for a person to take over
   * (McpGateway's REQUEST_PERSON_TOOL). The request stands until someone
   * takes control.
   *
   * @param {{ reason: string, client: string|null }} request
   */
  personRequested({ reason, client }) {
    this.personRequest = { reason, client, at: Date.now() };
    this.broadcast({ type: 'person_requested', request: this.personRequest });
    this.onMarker({ label: 'person_requested', source: 'agent', client, reason });
  }

  // Control moving between connections of one user is no takeover of its own.
  controlChanged(holder, previous, reason) {
    for (const viewer of this.viewers.values()) this.send(viewer, { type: 'control', ...this.controlState(viewer) });
    if (holder && this.personRequest) {
      this.personRequest = null;
      this.broadcast({ type: 'person_requested', request: null });
    }

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
