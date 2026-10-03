/**
 * Records one visit to a conversation in the Run Agent workbench into a
 * dashboard recording, which replays in the conversation's browser lane.
 *
 * A capture belongs to one conversation. `start()` starts a recording of it
 * (POST /api/session_recordings), loads rrweb's recorder from its own bundle
 * and records the page. Events are posted to
 * the recording in batches (POST /api/session_recordings/:id/events), one
 * request at a time. `stop()` stops the recorder at once and then posts what
 * it still holds.
 *
 * States, reported through `onStateChange`:
 *   - idle:      not started
 *   - starting:  creating the recording, then loading the recorder
 *   - recording: the page is being recorded
 *   - stopped:   stop() was called
 *   - off:       the host turned capture off (403)
 *   - limit:     a batch was over the recording's caps (413)
 *   - failed:    the recording could not be created, the recorder did not
 *                load, or the server refused a batch
 */

// Elements rrweb records as empty boxes, with no attributes but their class
// and no content: credential fields and displays, and the CSRF token the
// page's head carries.
export const CAPTURE_BLOCK_SELECTOR = '[data-aa-secret], meta[name="csrf-token"]';

export const FLUSH_INTERVAL_MS = 5000;

// Under RecordingEvent::DEFAULT_LIMITS. `chars` counts UTF-16 units, each at
// most three UTF-8 bytes, so a batch stays under the 1 MB batch cap.
export const BATCH_LIMITS = Object.freeze({ events: 500, chars: 256 * 1024 });

// fetch refuses a keepalive request whose body is over 64 KB.
export const KEEPALIVE_MAX_CHARS = 16 * 1024;

// Sends of one batch that fail on the network or with a 5xx or 429 before it
// is dropped.
export const MAX_ATTEMPTS = 3;

/**
 * Returns the options to start rrweb's `record` with.
 *
 * @param {(event: object) => void} emit receives each rrweb event
 * @returns {object}
 */
export function captureRecordOptions(emit) {
  return {
    emit,
    maskAllInputs: true,
    blockSelector: CAPTURE_BLOCK_SELECTOR,
    slimDOMOptions: 'all',
    sampling: { scroll: 150, input: 'last' },
  };
}

/**
 * Returns one rrweb event as a `recording_events` entry, in JSON.
 *
 * @param {{ timestamp: number }} event
 * @returns {string}
 */
export function serializeEvent(event) {
  return JSON.stringify({ kind: 'rrweb', timestamp: event.timestamp, data: event });
}

/**
 * Returns the body of one batch: `entries` (from serializeEvent) under
 * `recording_events`, sent at `sentAt` in epoch milliseconds.
 *
 * @param {string[]} entries
 * @param {number} sentAt
 * @returns {string}
 */
export function batchBody(entries, sentAt) {
  return `{"sent_at":${Math.floor(sentAt)},"recording_events":[${entries.join(',')}]}`;
}

/**
 * Returns how many entries from the head of `queue` make the next batch:
 * as many as fit `limits`, and always at least one.
 *
 * @param {string[]} queue serialized entries
 * @param {{ events: number, chars: number }} [limits]
 * @returns {number}
 */
export function batchSize(queue, limits = BATCH_LIMITS) {
  let chars = 0;
  let count = 0;
  for (const entry of queue) {
    if (count >= limits.events) break;
    if (count > 0 && chars + entry.length > limits.chars) break;
    chars += entry.length + 1;
    count += 1;
  }
  return count;
}

/**
 * Returns what to do after the server answered a batch or the recording's
 * creation with `status`: `sent`, `retry` (a 5xx or 429), or the state the
 * capture ends in (`off`, `limit`, `failed`).
 *
 * @param {number} status
 * @returns {'sent'|'retry'|'off'|'limit'|'failed'}
 */
export function batchOutcome(status) {
  if (status >= 200 && status < 300) return 'sent';
  if (status === 403) return 'off';
  if (status === 413) return 'limit';
  if (status === 429 || status >= 500) return 'retry';
  return 'failed';
}

/**
 * Creates the capture of one conversation.
 *
 * @param {object} options
 * @param {number|string} options.contextId the conversation (AgentContext id)
 * @param {() => Promise<{ record: Function }>} options.loadRecorder loads the
 *   recorder bundle
 * @param {(path: string, init: object) => Promise<Response>} options.fetch
 *   sends a request to the dashboard API
 * @param {() => number} [options.now] epoch milliseconds
 * @param {{ setInterval: Function, clearInterval: Function }} [options.timers]
 * @param {EventTarget} [options.target] the window, whose `pagehide` posts
 *   what the capture holds
 * @param {(state: string) => void} [options.onStateChange]
 * @param {{ events: number, chars: number }} [options.limits]
 * @param {number} [options.flushIntervalMs]
 * @returns {{ start: () => Promise<void>, stop: () => Promise<void>, flush: (options?: { final?: boolean }) => Promise<void>, readonly state: string }}
 */
export function createSessionCapture({
  contextId,
  loadRecorder,
  fetch: request,
  now = Date.now,
  timers = globalThis,
  target = globalThis,
  onStateChange = () => {},
  limits = BATCH_LIMITS,
  flushIntervalMs = FLUSH_INTERVAL_MS,
}) {
  const queue = [];
  let queuedChars = 0;
  let state = 'idle';
  let recordingId = null;
  let stopRecorder = null;
  let takeFullSnapshot = null;
  let interval = null;
  let stopped = false;
  let halted = false;
  let draining = null;
  let attempts = 0;

  function setState(next) {
    if (state === next) return;
    state = next;
    onStateChange(next);
  }

  function clearQueue() {
    queue.length = 0;
    queuedChars = 0;
  }

  function release() {
    if (stopRecorder) stopRecorder();
    stopRecorder = null;
    takeFullSnapshot = null;
    if (interval !== null) timers.clearInterval(interval);
    interval = null;
    target?.removeEventListener?.('pagehide', onPageHide);
  }

  function halt(next) {
    halted = true;
    clearQueue();
    release();
    setState(next);
  }

  function enqueue(event) {
    if (stopped || halted) return;
    const entry = serializeEvent(event);
    queue.push(entry);
    queuedChars += entry.length + 1;
    if (queue.length >= limits.events || queuedChars >= limits.chars) flush();
  }

  async function send(entries, final) {
    const body = batchBody(entries, now());
    try {
      const response = await request(`/api/session_recordings/${encodeURIComponent(recordingId)}/events`, {
        method: 'POST',
        // text/plain, so Rails leaves the body for the ingest to parse
        // rather than parsing it into params first.
        headers: { 'Content-Type': 'text/plain' },
        body,
        keepalive: final && body.length <= KEEPALIVE_MAX_CHARS,
      });
      return batchOutcome(response.status);
    } catch {
      return 'retry';
    }
  }

  async function drain(final) {
    while (queue.length > 0 && !halted) {
      const entries = queue.splice(0, batchSize(queue, limits));
      const chars = entries.reduce((total, entry) => total + entry.length + 1, 0);
      queuedChars -= chars;

      const outcome = await send(entries, final);
      if (outcome === 'sent') {
        attempts = 0;
        continue;
      }
      if (outcome !== 'retry') {
        halt(outcome);
        return;
      }

      attempts += 1;
      if (final || attempts >= MAX_ATTEMPTS) {
        // Every queued event builds on the DOM the dropped batch described,
        // so they go too, and a new full snapshot starts the replay over.
        attempts = 0;
        clearQueue();
        if (takeFullSnapshot) takeFullSnapshot();
        return;
      }
      queue.unshift(...entries);
      queuedChars += chars;
      return;
    }
  }

  function flush({ final = false } = {}) {
    if (recordingId === null || halted) return Promise.resolve();
    if (!draining) draining = drain(final).finally(() => { draining = null; });
    return draining;
  }

  function onPageHide() {
    flush({ final: true });
  }

  async function start() {
    if (state !== 'idle' || stopped) return;
    setState('starting');

    let response;
    try {
      response = await request('/api/session_recordings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ agent_context_id: contextId }),
      });
    } catch {
      if (!stopped) halt('failed');
      return;
    }
    if (stopped) return;
    if (!response.ok) {
      halt(batchOutcome(response.status) === 'off' ? 'off' : 'failed');
      return;
    }

    const data = await response.json().catch(() => null);
    if (stopped) return;
    recordingId = data?.recording?.id ?? null;
    if (recordingId === null) {
      halt('failed');
      return;
    }

    let record;
    try {
      ({ record } = await loadRecorder());
    } catch {
      if (!stopped) halt('failed');
      return;
    }
    if (stopped) return;

    let stopRecording = null;
    try {
      stopRecording = typeof record === 'function' ? record(captureRecordOptions(enqueue)) : null;
    } catch {
      stopRecording = null;
    }
    if (typeof stopRecording !== 'function') {
      halt('failed');
      return;
    }
    stopRecorder = stopRecording;
    takeFullSnapshot = () => record.takeFullSnapshot?.();
    interval = timers.setInterval(() => flush(), flushIntervalMs);
    target?.addEventListener?.('pagehide', onPageHide);
    setState('recording');
  }

  async function stop() {
    if (stopped) return;
    stopped = true;
    release();
    if (halted) return;

    setState('stopped');
    if (draining) await draining;
    await flush({ final: true });
  }

  return {
    start,
    stop,
    flush,
    get state() {
      return state;
    },
  };
}
