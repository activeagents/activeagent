// What each frame is, as Page.startScreencast takes it. Frames are scaled
// down to fit; the metadata keeps the page's own size for input.
export const SCREENCAST_OPTIONS = { format: 'jpeg', quality: 60, maxWidth: 1280, maxHeight: 800, everyNthFrame: 1 };

// A page's URL without its query or fragment, which can carry tokens.
export function pageUrl(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:' ? `${parsed.origin}${parsed.pathname}` : url === 'about:blank' ? url : null;
  } catch {
    return null;
  }
}

/**
 * Used to stream the page on screen as JPEG frames, over the Chrome DevTools
 * Protocol (Page.startScreencast), and to send it input.
 *
 * The page on screen is the newest open page: a tab or popup that opens
 * takes the screen, and when the page on screen closes, the newest one left
 * does. #follow puts another page on screen.
 *
 * Chromium sends a frame only when the page changes, and stops sending until
 * each one is acknowledged, so every frame is acknowledged as it arrives and
 * the latest is kept (#lastFrame) for a viewer who joins while the page is
 * still.
 */
export class Screencast {
  /**
   * @param {object} options
   * @param {import('playwright').BrowserContext} options.context
   * @param {(frame: { data: string, metadata: object }) => void} options.onFrame
   * @param {() => void} [options.onPageChange] called when the page on screen, or its address, changes
   * @param {(message: string) => void} [options.log]
   * @param {object} [options.screencastOptions]
   */
  constructor({ context, onFrame, onPageChange = () => {}, log = () => {}, screencastOptions = SCREENCAST_OPTIONS }) {
    this.context = context;
    this.onFrame = onFrame;
    this.onPageChange = onPageChange;
    this.log = log;
    this.screencastOptions = screencastOptions;
    this.page = null;
    this.session = null;
    this.streaming = false;
    this.lastFrame = null;
    // Each change of page or of streaming runs after the one before.
    this.queue = Promise.resolve();
  }

  // Starts following the context's pages.
  attach() {
    const watch = (page) => {
      page.on('close', () => {
        if (page === this.page) void this.follow(this.newestPage());
      });
      page.on('framenavigated', (frame) => {
        if (page === this.page && frame === page.mainFrame()) this.onPageChange();
      });
    };
    for (const page of this.context.pages()) watch(page);
    this.context.on('page', (page) => {
      watch(page);
      void this.follow(page);
    });
    return this.follow(this.newestPage());
  }

  newestPage() {
    const open = this.context.pages().filter((page) => !page.isClosed());
    return open.at(-1) ?? null;
  }

  // The page on screen as a viewer is told of it.
  get pageInfo() {
    if (!this.page) return null;
    const pages = this.context.pages().filter((page) => !page.isClosed());
    return { url: pageUrl(this.page.url()), tab: pages.indexOf(this.page) + 1, tabs: pages.length };
  }

  get metadata() {
    return this.lastFrame?.metadata ?? null;
  }

  /**
   * Puts `page` on screen.
   *
   * @param {import('playwright').Page | null} page
   */
  follow(page) {
    return this.enqueue(async () => {
      if (page === this.page) return;
      await this.detach();
      this.page = page;
      this.onPageChange();
      if (page && this.streaming) await this.startOn(page);
    });
  }

  /**
   * Puts the page at `index` among the open pages on screen.
   *
   * @param {number} index
   */
  followIndex(index) {
    const page = this.context.pages().filter((candidate) => !candidate.isClosed())[index];
    return page ? this.follow(page) : Promise.resolve();
  }

  // Starts streaming the page on screen.
  start() {
    return this.enqueue(async () => {
      if (this.streaming) return;
      this.streaming = true;
      if (this.page) await this.startOn(this.page);
    });
  }

  // Stops streaming; the last frame is kept.
  stop() {
    return this.enqueue(async () => {
      this.streaming = false;
      await this.detach();
    });
  }

  /**
   * Sends one CDP command to the page on screen.
   *
   * @param {string} method
   * @param {object} params
   */
  async dispatch(method, params) {
    const session = this.session ?? (await this.enqueue(() => this.sessionFor(this.page)));
    if (!session) return;
    await session.send(method, params);
  }

  async sessionFor(page) {
    if (!page || page.isClosed()) return null;
    if (this.session) return this.session;

    const session = await this.context.newCDPSession(page);
    session.on('Page.screencastFrame', ({ data, metadata, sessionId }) => {
      session.send('Page.screencastFrameAck', { sessionId }).catch(() => {});
      if (session !== this.session || !this.streaming) return;

      this.lastFrame = { data, metadata };
      this.onFrame(this.lastFrame);
    });
    this.session = session;
    return session;
  }

  async startOn(page) {
    try {
      const session = await this.sessionFor(page);
      await session?.send('Page.startScreencast', this.screencastOptions);
    } catch (error) {
      this.log(`live view: could not stream the page: ${error.message}`);
    }
  }

  async detach() {
    const session = this.session;
    this.session = null;
    if (!session) return;
    await session.send('Page.stopScreencast').catch(() => {});
    await session.detach().catch(() => {});
  }

  enqueue(work) {
    const run = this.queue.then(work);
    this.queue = run.catch(() => {});
    return run;
  }

  async close() {
    await this.stop();
  }
}
