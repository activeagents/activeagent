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
 * Whether the holders' users `a` and `b` are the same person. A user with no
 * id is nobody in particular, so is never the same as anyone.
 *
 * @param {{ id: string|null }} a
 * @param {{ id: string|null }} b
 */
export function sameUser(a, b) {
  return a.id !== null && a.id === b.id;
}

// How many control changes the journal keeps.
export const JOURNAL_LIMIT = 50;

/**
 * Used to let one person at a time drive the browser by hand. While someone
 * holds control, an agent's call that changes the page waits for them to
 * hand it back (#admit).
 *
 * A holder is identified by the key of their connection, and is a
 * `{ key, user: { id, name }, since }`. A user with an id may move control
 * between their own connections: a second tab, or a reconnect.
 *
 * Every change of holder is also kept in a short journal (#journal,
 * #changesSince), so an agent can be told that a person drove the browser
 * since its last call: the page may not be what it last saw.
 *
 * Events:
 *   change         (holder, previous, reason) whenever the holder changes;
 *                  reason is "taken", "moved", "handed_back", "disconnected"
 *                  or "closed"
 *   agent_waiting  ({ tool, since, client }) an agent's call began to wait
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
    this.journal = [];
    this.journalSeq = 0;
    this.on('change', (holder, previous, reason) => this.record(holder, previous, reason));
  }

  // Notes a change of holder in the journal. Control moving between one
  // user's connections changes nothing an agent would need to hear of.
  record(holder, previous, reason) {
    if (holder && previous) return;
    const user = (holder ?? previous)?.user ?? { id: null, name: null };
    this.journalSeq += 1;
    this.journal.push({ seq: this.journalSeq, at: this.now(), type: holder ? 'taken' : 'released', reason, user: user.name ?? null });
    if (this.journal.length > JOURNAL_LIMIT) this.journal.splice(0, this.journal.length - JOURNAL_LIMIT);
  }

  /**
   * The control changes after `seq`, oldest first.
   *
   * @param {number} seq
   * @returns {Array<{ seq: number, at: number, type: 'taken'|'released', reason: string, user: string|null }>}
   */
  changesSince(seq) {
    return this.journal.filter((entry) => entry.seq > seq);
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
    if (previous && !sameUser(previous.user, user)) return { holder: previous, taken: false };

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
   * @param {string|null} [client] who is calling, as the live view names them ("Claude Code · turn 3")
   * @returns {Promise<{ holder: object }|{ stopping: true }|null>} null to run the call; otherwise why it
   *   is refused: the holder who kept control past `waitMs`, or `stopping` when the lock closed meanwhile
   */
  async admit(name, args, waitMs, client = null) {
    if (!this.holder || !changesPage(name, args)) return null;

    const wait = { tool: name, since: this.now(), client };
    const deadline = wait.since + waitMs;
    this.waiting.add(wait);
    this.emit('agent_waiting', wait);
    // Someone may take control again between its release and this call
    // going ahead, so the wait goes on until control is free at that moment.
    while (this.holder && !this.closed && deadline > this.now()) {
      if (!(await this.waitUntilFree(deadline - this.now()))) break;
    }
    let refusal = null;
    if (this.closed) refusal = { stopping: true };
    else if (this.holder) refusal = { holder: this.holder };
    this.waiting.delete(wait);
    this.emit('agent_done', { tool: name, admitted: refusal === null });
    return refusal;
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
