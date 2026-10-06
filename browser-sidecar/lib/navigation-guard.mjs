// How many of the latest escapes are kept to name in a refusal.
const KEPT_ESCAPES = 10;

/**
 * Used to keep every tab on the sandbox app. A navigation that starts
 * elsewhere never leaves (see NetworkPolicy#allows), but Chromium follows an
 * HTTP redirect from an app page without asking the policy again, and the
 * egress proxy only refuses private addresses. A tab that lands on another
 * origin that way has escaped. It is closed at once, which also discards
 * what Playwright MCP collected from it (its requests and console messages),
 * and the escape is counted so the MCP gateway can withhold the result of
 * any tool call it happened during. When it was the only tab, a blank one is
 * opened first, so the browser keeps a page.
 */
export class NavigationGuard {
  /**
   * @param {object} options
   * @param {{ onApp(url: string): boolean }} options.policy
   * @param {(message: string) => void} [options.log]
   */
  constructor({ policy, log = () => {} }) {
    this.policy = policy;
    this.log = log;
    this.escapes = 0;
    this.recent = [];
    this.pages = new Set();
    this.closing = new Set();
  }

  /**
   * Watches every page `context` has and opens.
   *
   * @param {import('playwright').BrowserContext} context
   */
  attach(context) {
    this.context = context;
    for (const page of context.pages()) this.watch(page);
    context.on('page', (page) => this.watch(page));
  }

  watch(page) {
    this.pages.add(page);
    page.on('close', () => this.pages.delete(page));
    page.on('framenavigated', (frame) => {
      if (frame !== page.mainFrame() || this.policy.onApp(frame.url())) return;

      const { origin } = new URL(frame.url());
      this.escapes += 1;
      this.recent = [...this.recent, { count: this.escapes, origin }].slice(-KEPT_ESCAPES);
      this.log(`closed a page that was redirected to ${origin}`);
      const closing = this.close(page);
      this.closing.add(closing);
      closing.finally(() => this.closing.delete(closing));
    });
  }

  async close(page) {
    try {
      if (this.context.pages().every((other) => other === page)) await this.context.newPage();
      await page.close();
    } catch {
      // The browser is closing.
    }
  }

  /**
   * Why a tool call that began when `escapes` was `since` may not return its
   * result: a page escaped while it ran, or one is still off the app. Null
   * when neither. Resolves once the escaped pages are closed, so the next
   * call finds the browser on a page it may use.
   *
   * @param {number} since
   * @returns {Promise<string | null>}
   */
  async refusalSince(since) {
    await Promise.all(this.closing);
    const origins = new Set(this.recent.filter((escape) => escape.count > since).map((escape) => escape.origin));
    for (const page of this.pages) {
      if (!this.policy.onApp(page.url())) origins.add(new URL(page.url()).origin);
    }
    if (this.escapes === since && origins.size === 0) return null;

    const where = origins.size > 0 ? ` to ${[...origins].join(', ')}` : '';
    return `A page was redirected${where}, outside the sandbox app, and was closed. ` +
      'This browser may only show pages of the sandbox app, so the result of this call is withheld.';
  }
}
