import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { gzipSync } from 'node:zlib';

const require = createRequire(import.meta.url);

// What one call from a page may carry, and the console levels kept.
const MAX_PAYLOAD_CHARS = 8 * 1024 * 1024;
const CONSOLE_LEVELS = new Set(['error', 'warning']);
const CONSOLE_TEXT_LIMIT = 2000;
// Room left in a batch for the envelope around its events.
const ENVELOPE_BYTES = 1024;
// How long a page holds rrweb events before handing them over.
export const PAGE_FLUSH_MS = 250;

/**
 * The browser build of @rrweb/record, as the source of a script.
 *
 * @returns {string}
 */
export function rrwebSource() {
  return readFileSync(join(dirname(require.resolve('@rrweb/record')), 'record.umd.min.cjs'), 'utf8');
}

// Text inside an editable element. maskAllInputs covers only input,
// textarea and select values, and text typed into a contenteditable host
// (a rich-text editor, say) is recorded as DOM text instead.
export const EDITABLE_TEXT = '[contenteditable]:not([contenteditable="false"])';

/**
 * Returns the init script that records each page with rrweb and hands its
 * events, as JSON text, to the binding named `binding`. Input values, and
 * the text of contenteditable elements and their descendants, are masked
 * before an event leaves the page. The bundle runs with a module object of
 * its own, so it defines no global the page could reach.
 *
 * @param {{ binding: string, rrweb: string, flushMs?: number, flushEvents?: number }} options
 * @returns {string}
 */
export function initScript({ binding, rrweb, flushMs = PAGE_FLUSH_MS, flushEvents = 50 }) {
  return `(() => {
  const deliver = window[${JSON.stringify(binding)}];
  if (typeof deliver !== 'function') return;
  const rrwebRecord = (function () {
    var module = { exports: {} };
    var exports = module.exports;
    ${rrweb}
    return module.exports;
  })();
  let buffer = [];
  let timer = null;
  const flush = () => {
    timer = null;
    if (buffer.length === 0) return;
    const batch = buffer;
    buffer = [];
    try { deliver(JSON.stringify(batch)); } catch (error) {}
  };
  rrwebRecord.record({
    emit(event) {
      buffer.push(event);
      if (buffer.length >= ${flushEvents}) flush();
      else if (timer === null) timer = setTimeout(flush, ${flushMs});
    },
    maskAllInputs: true,
    maskTextSelector: ${JSON.stringify(EDITABLE_TEXT)},
    recordCrossOriginIframes: true,
    sampling: { mousemove: 50, scroll: 150, input: 'last' },
  });
  addEventListener('pagehide', flush);
})();`;
}

/**
 * Used to group recorded events into batches the recording ingest accepts:
 * at most `maxEvents` events and `maxBytes` bytes of JSON each. A batch is
 * handed to `onBatch` as soon as it is full, or `flushMs` after its first
 * event. An event too large for any batch is dropped.
 */
export class EventBatcher {
  constructor({ maxEvents, maxBytes, flushMs = 1000, onBatch, onDrop = () => {}, now = Date.now }) {
    this.maxEvents = maxEvents;
    this.maxBytes = Math.max(maxBytes - ENVELOPE_BYTES, 1);
    this.flushMs = flushMs;
    this.onBatch = onBatch;
    this.onDrop = onDrop;
    this.now = now;
    this.parts = [];
    this.bytes = 0;
    this.timer = null;
  }

  /**
   * @param {{ kind: string, timestamp: number, data: object }} event
   */
  add(event) {
    const part = JSON.stringify(event);
    const size = Buffer.byteLength(part) + 1;
    if (size > this.maxBytes) {
      this.onDrop(event, 'larger than a batch may be');
      return;
    }
    if (this.parts.length >= this.maxEvents || this.bytes + size > this.maxBytes) this.flush();

    this.parts.push(part);
    this.bytes += size;
    if (this.parts.length >= this.maxEvents) this.flush();
    else if (this.timer === null) this.timer = setTimeout(() => this.flush(), this.flushMs);
  }

  flush() {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    if (this.parts.length === 0) return;

    const body = `{"sent_at":${this.now()},"recording_events":[${this.parts.join(',')}]}`;
    const count = this.parts.length;
    this.parts = [];
    this.bytes = 0;
    this.onBatch(body, count);
  }
}

/**
 * Used to post batches to the recording ingest, gzipped, one at a time and
 * in order. A failed post is retried with backoff; a batch the ingest
 * refuses is dropped; a refused token stops the uploads, since every later
 * batch would be refused too.
 */
export class Uploader {
  constructor({ url, token, fetch = globalThis.fetch, log = () => {}, retries = 3, backoffMs = 500, maxQueue = 50 }) {
    this.url = url;
    this.token = token;
    this.fetch = fetch;
    this.log = log;
    this.retries = retries;
    this.backoffMs = backoffMs;
    this.maxQueue = maxQueue;
    this.queue = [];
    this.running = null;
    this.stopped = false;
    this.dropped = 0;
  }

  enqueue(body, count) {
    if (this.stopped) {
      this.dropped += count;
      return;
    }
    if (this.queue.length >= this.maxQueue) {
      const oldest = this.queue.shift();
      this.dropped += oldest.count;
      this.log(`recording: dropped a batch of ${oldest.count} events, the upload queue is full`);
    }
    this.queue.push({ body: gzipSync(body), count });
    this.running ??= this.run();
  }

  async run() {
    try {
      while (this.queue.length > 0 && !this.stopped) {
        await this.post(this.queue.shift());
      }
    } finally {
      this.running = null;
    }
  }

  async post(batch) {
    for (let attempt = 0; attempt <= this.retries; attempt += 1) {
      let status;
      try {
        const response = await this.fetch(this.url, {
          method: 'POST',
          headers: {
            authorization: `Bearer ${this.token}`,
            'content-type': 'application/json',
            'content-encoding': 'gzip',
          },
          body: batch.body,
        });
        status = response.status;
        if (status < 300) return;
        if (status === 401 || status === 403) {
          this.stopped = true;
          this.dropped += batch.count + this.queue.reduce((total, queued) => total + queued.count, 0);
          this.queue = [];
          this.log(`recording: the ingest refused the recording token (HTTP ${status}); recording stopped`);
          return;
        }
        if (status < 500 && status !== 429) {
          this.dropped += batch.count;
          this.log(`recording: the ingest refused a batch of ${batch.count} events (HTTP ${status})`);
          return;
        }
      } catch (error) {
        status = error.code ?? error.name;
      }
      if (attempt < this.retries) await new Promise((resolve) => setTimeout(resolve, this.backoffMs * 2 ** attempt));
      else this.log(`recording: gave up on a batch of ${batch.count} events (${status})`);
    }
    this.dropped += batch.count;
  }

  /**
   * Waits for queued batches to post, up to `timeoutMs`.
   *
   * @param {number} timeoutMs
   */
  async drain(timeoutMs) {
    let timer;
    const deadline = new Promise((resolve) => {
      timer = setTimeout(resolve, timeoutMs);
    });
    try {
      while (this.running) {
        const done = await Promise.race([this.running.then(() => true), deadline.then(() => false)]);
        if (!done) return;
      }
    } finally {
      clearTimeout(timer);
    }
  }
}

// A marker's URL without its query or fragment, which can carry tokens.
function markerUrl(url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol === 'http:' || parsed.protocol === 'https:') return `${parsed.origin}${parsed.pathname}`;
    return url === 'about:blank' ? url : null;
  } catch {
    return null;
  }
}

function validRrwebEvent(event) {
  return event !== null && typeof event === 'object' && Number.isInteger(event.type) && Number.isFinite(event.timestamp);
}

/**
 * Used to record a browser context into a session recording: rrweb from every
 * page's main frame, console errors and warnings, and markers for pages
 * opening, navigating and closing.
 */
export class Recorder {
  /**
   * @param {object} options
   * @param {{ url: string, token: string, batchEvents: number, batchBytes: number }} options.recording
   * @param {(message: string) => void} [options.log]
   * @param {typeof fetch} [options.fetch]
   */
  constructor({ recording, log = () => {}, fetch = globalThis.fetch }) {
    this.log = log;
    this.binding = `__aa_${randomBytes(8).toString('hex')}`;
    this.uploader = new Uploader({ url: recording.url, token: recording.token, fetch, log });
    this.batcher = new EventBatcher({
      maxEvents: recording.batchEvents,
      maxBytes: recording.batchBytes,
      onBatch: (body, count) => this.uploader.enqueue(body, count),
      onDrop: (_event, reason) => log(`recording: dropped an event ${reason}`),
    });
    this.tabs = new WeakMap();
    this.nextTab = 1;
  }

  /**
   * Starts recording `context`: every page opened from now on, in every frame.
   *
   * @param {import('playwright').BrowserContext} context
   */
  async attach(context) {
    await context.exposeBinding(this.binding, (source, payload) => this.receive(source, payload));
    await context.addInitScript({ content: initScript({ binding: this.binding, rrweb: rrwebSource() }) });

    context.on('console', (message) => this.console(message));
    context.on('page', (page) => this.watch(page));
    for (const page of context.pages()) this.watch(page);
  }

  tab(page) {
    if (!this.tabs.has(page)) this.tabs.set(page, this.nextTab++);
    return this.tabs.get(page);
  }

  watch(page) {
    const tab = this.tab(page);
    this.marker({ label: 'page_opened', tab, url: markerUrl(page.url()) });
    page.on('framenavigated', (frame) => {
      if (frame === page.mainFrame()) this.marker({ label: 'navigated', tab, url: markerUrl(frame.url()) });
    });
    page.on('close', () => this.marker({ label: 'page_closed', tab }));
  }

  marker(data) {
    this.batcher.add({ kind: 'marker', timestamp: Date.now(), data });
  }

  console(message) {
    if (!CONSOLE_LEVELS.has(message.type())) return;

    const page = message.page();
    this.batcher.add({
      kind: 'console',
      timestamp: Date.now(),
      data: { level: message.type(), text: message.text().slice(0, CONSOLE_TEXT_LIMIT), tab: page ? this.tab(page) : null },
    });
  }

  /**
   * Takes a batch of rrweb events a page handed to the binding. Only a main
   * frame's are kept: rrweb in a child frame passes its events up to the main
   * frame's recorder instead.
   *
   * @param {{ page?: object, frame?: object }} source
   * @param {unknown} payload JSON text of an array of rrweb events
   */
  receive(source, payload) {
    if (!source?.page || source.frame !== source.page.mainFrame()) return;
    if (typeof payload !== 'string' || payload.length > MAX_PAYLOAD_CHARS) return;

    let events;
    try {
      events = JSON.parse(payload);
    } catch {
      return;
    }
    if (!Array.isArray(events)) return;

    const tab = this.tab(source.page);
    for (const event of events) {
      if (validRrwebEvent(event)) this.batcher.add({ kind: 'rrweb', timestamp: event.timestamp, data: { ...event, tab } });
    }
  }

  /**
   * Sends what is buffered and waits for it to post, up to `timeoutMs`.
   *
   * @param {number} timeoutMs
   */
  async close(timeoutMs) {
    this.batcher.flush();
    await this.uploader.drain(timeoutMs);
    if (this.uploader.dropped > 0) this.log(`recording: ${this.uploader.dropped} events were not stored`);
  }
}
