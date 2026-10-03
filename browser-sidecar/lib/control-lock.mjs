import { EventEmitter } from 'node:events';

// The Playwright MCP tools that only look at the browser. Every other tool
// changes the page, and waits while a person holds control.
export const OBSERVING_TOOLS = new Set([
  'browser_snapshot',
  'browser_take_screenshot',
  'browser_console_messages',
  'browser_network_requests',
  'browser_network_request',
  'browser_find',
  'browser_generate_locator',
  'browser_wait_for',
  'browser_verify_element_visible',
  'browser_verify_list_visible',
  'browser_verify_text_visible',
  'browser_verify_value',
  'browser_pdf_save',
  'browser_get_config',
]);

// The _meta key a refused call's result names the person driving under.
export const TAKEOVER_META = 'activeagents/takeover';

/**
 * Whether the tool call `name` with `args` would change what the browser
 * shows.
 *
 * @param {string} name
 * @param {object} [args]
 */
export function changesPage(name, args = {}) {
  if (name === 'browser_tabs') return args?.action !== 'list';
  return !OBSERVING_TOOLS.has(name);
}

/**
 * Used to let one person at a time drive the browser by hand. While someone
 * holds control, an agent's call that changes the page waits for them to
 * hand it back (#admit).
 *
 * A holder is identified by the key of their connection, and is a
 * `{ key, user: { id, name }, since }`. A user with an id may move control
 * between their own connections: a second tab, or a reconnect.
 *
 * Events:
 *   change         (holder, previous, reason) whenever the holder changes;
 *                  reason is "taken", "moved", "handed_back", "disconnected"
 *                  or "closed"
 *   agent_waiting  ({ tool, since }) an agent's call began to wait
 *   agent_done     ({ tool, admitted }) it stopped waiting, run or refused
 */
export class ControlLock extends EventEmitter {
  /**
   * @param {object} [options]
   * @param {number} [options.graceMs] how long control stays with a holder whose connection dropped
   * @param {() => number} [options.now] epoch milliseconds
   */
  constructor({ graceMs = 10_000, now = Date.now } = {}) {
    super();
    this.graceMs = graceMs;
    this.now = now;
    this.holder = null;
    this.graceTimer = null;
    this.waiting = new Set();
    this.closed = false;
  }

  /**
   * Gives control to the connection `key`, for `user`, unless another
   * person holds it.
   *
   * @param {string} key
   * @param {{ id: string|null, name: string|null }} user
   * @returns {{ holder: object, taken: boolean }} taken is false when someone else holds it
   */
  acquire(key, user) {
    const previous = this.holder;
    if (this.closed) return { holder: previous, taken: false };
    if (previous?.key === key) return { holder: previous, taken: true };
    if (previous && !(previous.user.id !== null && previous.user.id === user.id)) return { holder: previous, taken: false };

    this.clearGrace();
    this.holder = { key, user, since: previous?.since ?? this.now() };
    this.emit('change', this.holder, previous, previous ? 'moved' : 'taken');
    return { holder: this.holder, taken: true };
  }

  /**
   * Takes control from the connection `key`, when it holds it.
   *
   * @param {string} key
   * @param {string} [reason]
   * @returns {boolean} whether it held control
   */
  release(key, reason = 'handed_back') {
    if (this.holder?.key !== key) return false;

    this.clearGrace();
    const previous = this.holder;
    this.holder = null;
    this.emit('change', null, previous, reason);
    return true;
  }

  /**
   * Notes that the connection `key` closed: when it holds control, control
   * is released after the grace period, unless its user takes it up again
   * from another connection first.
   *
   * @param {string} key
   */
  disconnected(key) {
    if (this.holder?.key !== key) return;

    this.clearGrace();
    this.graceTimer = setTimeout(() => this.release(key, 'disconnected'), this.graceMs);
    this.graceTimer.unref?.();
  }

  /**
   * Lets an agent's tool call through, at once when it does not change the
   * page or nobody holds control, and otherwise once control is handed back
   * within `waitMs`.
   *
   * @param {string} name the tool
   * @param {object} args its arguments
   * @param {number} waitMs
   * @returns {Promise<object|null>} null to run the call, or the holder it is refused for
   */
  async admit(name, args, waitMs) {
    if (!this.holder || !changesPage(name, args)) return null;

    const wait = { tool: name, since: this.now() };
    const deadline = wait.since + waitMs;
    let holder = this.holder;
    this.waiting.add(wait);
    this.emit('agent_waiting', wait);
    // Someone may take control again between its release and this call
    // going ahead, so the wait goes on until control is free at that moment.
    while (this.holder && !this.closed && deadline > this.now()) {
      holder = this.holder;
      if (!(await this.waitUntilFree(deadline - this.now()))) break;
    }
    const refused = this.holder || this.closed ? (this.holder ?? holder) : null;
    this.waiting.delete(wait);
    this.emit('agent_done', { tool: name, admitted: refused === null });
    return refused;
  }

  /**
   * Resolves true once nobody holds control, or false after `timeoutMs`.
   *
   * @param {number} timeoutMs
   * @returns {Promise<boolean>}
   */
  waitUntilFree(timeoutMs) {
    if (!this.holder) return Promise.resolve(true);
    if (this.closed) return Promise.resolve(false);

    return new Promise((resolve) => {
      const finish = (free) => {
        clearTimeout(timer);
        this.off('change', onChange);
        this.off('closed', onClosed);
        resolve(free);
      };
      const onChange = (holder) => {
        if (!holder) finish(true);
      };
      const onClosed = () => finish(false);
      const timer = setTimeout(() => finish(false), timeoutMs);
      this.on('change', onChange);
      this.on('closed', onClosed);
    });
  }

  // The longest-waiting agent call, or null.
  get agentWaiting() {
    const [first] = this.waiting;
    return first ?? null;
  }

  // Releases control for good, refusing the agent calls still waiting: the
  // browser is stopping.
  close() {
    if (this.closed) return;
    this.closed = true;
    this.emit('closed');
    if (this.holder) this.release(this.holder.key, 'closed');
    this.clearGrace();
  }

  clearGrace() {
    if (this.graceTimer !== null) clearTimeout(this.graceTimer);
    this.graceTimer = null;
  }
}
