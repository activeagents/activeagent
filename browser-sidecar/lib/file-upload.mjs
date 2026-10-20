import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { mkdir, open, rm } from 'node:fs/promises';
import { join } from 'node:path';

// The bytes a viewer sends in one file_chunk message, before base64. Encoded,
// a chunk and its envelope stay well under the live view's 64 KiB message cap.
export const UPLOAD_CHUNK_BYTES = 32 * 1024;
const MAX_CHUNK_CHARS = Math.ceil(UPLOAD_CHUNK_BYTES / 3) * 4;
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;
const MAX_NAME_BYTES = 200;
// How often, in bytes received, the uploader is told how far it has got.
const PROGRESS_EVERY_BYTES = 1024 * 1024;

export const DEFAULT_UPLOAD_LIMITS = Object.freeze({
  maxFileBytes: 25 * 1024 * 1024,
  maxFiles: 10,
  maxSessionBytes: 250 * 1024 * 1024,
});
// How long a file chooser waits for the person driving to answer it, counted
// again from each chunk they send.
const CHOOSER_TIMEOUT_MS = 5 * 60 * 1000;

/** Raised for an upload the sidecar refuses; `code` names why. */
export class UploadError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/**
 * Returns the name a file a viewer sent is saved and shown to the page
 * under: its last path segment, without control characters, characters
 * file systems refuse, or leading dots, and at most MAX_NAME_BYTES of UTF-8.
 * "upload" when nothing is left.
 *
 * @param {unknown} name
 * @returns {string}
 */
export function sanitizeFileName(name) {
  if (typeof name !== 'string') return 'upload';

  let clean = name.split(/[\\/]/).at(-1)
    .replace(/[\u0000-\u001f\u007f<>:"|?*]/g, '')
    .replace(/^[.\s]+/, '')
    .trim();
  while (Buffer.byteLength(clean, 'utf8') > MAX_NAME_BYTES) clean = [...clean].slice(0, -1).join('');
  return clean === '' ? 'upload' : clean;
}

/**
 * Clears the file chooser modal state Playwright MCP keeps on its tab for
 * `chooser`, so an agent's next tool call is not refused for a chooser the
 * person driving already answered or cancelled. Playwright MCP keeps its tab
 * on the page under a private symbol, so this looks for any symbol whose
 * value has its modal state methods; a version without them is left alone.
 *
 * @param {import('playwright').Page} page
 * @param {import('playwright').FileChooser} chooser
 */
export function clearAgentFileChooser(page, chooser) {
  for (const symbol of Object.getOwnPropertySymbols(page)) {
    const tab = page[symbol];
    if (typeof tab?.modalStates !== 'function' || typeof tab.clearModalState !== 'function') continue;
    for (const state of tab.modalStates()) {
      if (state?.type === 'fileChooser' && state.fileChooser === chooser) tab.clearModalState(state);
    }
  }
}

function decodeChunk(data) {
  if (typeof data !== 'string' || data === '' || data.length > MAX_CHUNK_CHARS || data.length % 4 !== 0 || !BASE64.test(data)) {
    throw new UploadError('bad_upload', 'A file chunk must be base64, at most 32 KiB before encoding');
  }
  return Buffer.from(data, 'base64');
}

/**
 * Used to hand a file to a page's <input type="file"> from the live view.
 *
 * While someone holds control (ControlLock), a page that opens a file
 * chooser is offered to the live view instead (#state): headless Chromium
 * has no dialog to show, and a headed one's is on the sandbox's screen, not
 * the viewer's. Only the person holding control may answer it, by sending
 * the files' bytes (#begin, #chunk), which are written to a directory of
 * their own, readable only by this process, and set on the input. They stay
 * there until the browser stops, as the page's File objects read them from
 * disk, and count against maxSessionBytes until then.
 *
 * It listens for choosers only while someone holds control: Playwright
 * intercepts a page's choosers while anything listens, so the rest of the
 * time a headed browser's own dialog opens as before, and an agent's
 * chooser is left to Playwright MCP's browser_file_upload.
 *
 * Events:
 *   change       (state) the chooser on offer changed; null when none is
 *   unavailable  ({ reason }) a chooser opened that the live view may not answer
 *   progress     ({ id, key, received, total }) an upload went on
 *   uploaded     ({ id, user, files, bytes }) the files were set on the input
 */
export class FileChooserRelay extends EventEmitter {
  /**
   * @param {object} options
   * @param {import('playwright').BrowserContext} options.context
   * @param {import('./control-lock.mjs').ControlLock} options.lock
   * @param {string} options.dir where uploaded files are written
   * @param {Partial<typeof DEFAULT_UPLOAD_LIMITS>} [options.limits]
   * @param {number} [options.timeoutMs]
   * @param {(message: string) => void} [options.log]
   * @param {() => number} [options.now]
   */
  constructor({ context, lock, dir, limits = {}, timeoutMs = CHOOSER_TIMEOUT_MS, log = () => {}, now = Date.now }) {
    super();
    this.context = context;
    this.lock = lock;
    this.dir = dir;
    this.limits = { ...DEFAULT_UPLOAD_LIMITS, ...limits };
    this.timeoutMs = timeoutMs;
    this.log = log;
    this.now = now;
    this.pending = null;
    this.upload = null;
    this.storedBytes = 0;
    this.closed = false;
    // Uploads, cancels and offers run one after another, as their messages
    // arrive.
    this.queue = Promise.resolve();
    this.listening = false;
    this.onChooser = (chooser) => void this.enqueue(() => this.offer(chooser));

    lock.on('change', (holder, previous) => {
      this.listen(Boolean(holder));
      if (!holder) void this.enqueue(() => this.discard('control was handed back'));
      else if (previous && this.upload?.key === previous.key) void this.enqueue(() => this.abortUpload());
    });
  }

  // Follows the context's pages, to listen on them while someone holds
  // control.
  attach() {
    this.context.on('page', (page) => {
      if (this.listening) page.on('filechooser', this.onChooser);
    });
    this.listen(Boolean(this.lock.holder));
  }

  listen(on) {
    if (on === this.listening || (on && this.closed)) return;
    this.listening = on;
    for (const page of this.context.pages()) {
      if (on) page.on('filechooser', this.onChooser);
      else page.off('filechooser', this.onChooser);
    }
  }

  get enabled() {
    return this.limits.maxFiles > 0;
  }

  // The chooser on offer, as viewers are told of it, or null.
  get state() {
    if (!this.pending) return null;
    const { id, multiple, accept, since } = this.pending;
    return { id, multiple, accept, since, max_files: multiple ? this.limits.maxFiles : 1, max_file_bytes: this.limits.maxFileBytes };
  }

  async offer(chooser) {
    if (this.closed || !this.lock.holder) return;
    if (!this.enabled) {
      this.emit('unavailable', { reason: 'File uploads are turned off for this browser' });
      return;
    }

    await this.discard(null);
    const accept = await chooser.element().getAttribute('accept').catch(() => null);
    this.pending = { id: randomUUID(), chooser, multiple: chooser.isMultiple(), accept: accept || null, since: this.now(), timer: null };
    this.restartTimer();
    this.emit('change', this.state);
  }

  restartTimer() {
    const pending = this.pending;
    clearTimeout(pending.timer);
    pending.timer = setTimeout(() => void this.enqueue(() => {
      if (this.pending === pending) return this.discard('the file chooser timed out');
    }), this.timeoutMs);
    pending.timer.unref?.();
  }

  /**
   * Starts answering the chooser `id` with `files` ({ name, size } each),
   * for the connection `key`, which must hold control. The bytes follow in
   * #chunk calls, in the order the files are listed. Resolves `{ done }`:
   * true when every file is empty, so the input was set at once.
   *
   * @param {string} key
   * @param {{ chooser: string, files: Array<{ name: string, size: number }> }} request
   */
  begin(key, request) {
    return this.enqueue(async () => {
      this.assertAnswering(key, request?.chooser);
      const files = request.files;
      const limit = this.state.max_files;
      if (!Array.isArray(files) || files.length === 0) throw new UploadError('bad_upload', 'Choose at least one file');
      if (files.length > limit) throw new UploadError('too_many', limit === 1 ? 'This field takes one file' : `This field takes at most ${limit} files`);
      for (const file of files) {
        if (!Number.isSafeInteger(file?.size) || file.size < 0) throw new UploadError('bad_upload', 'Each file needs its size in bytes');
        if (file.size > this.limits.maxFileBytes) {
          throw new UploadError('too_large', `${sanitizeFileName(file.name)} is larger than ${megabytes(this.limits.maxFileBytes)}`);
        }
      }
      // Beginning again replaces an upload that did not finish.
      await this.abortUpload();
      const total = files.reduce((sum, file) => sum + file.size, 0);
      if (this.storedBytes + total > this.limits.maxSessionBytes) {
        throw new UploadError('too_large', `This browser takes at most ${megabytes(this.limits.maxSessionBytes)} of uploads in all`);
      }

      const root = join(this.dir, this.pending.id);
      await mkdir(root, { recursive: true, mode: 0o700 });
      const upload = { id: this.pending.id, key, root, total, received: 0, reported: 0, index: 0, files: [] };
      this.upload = upload;
      this.storedBytes += total;
      try {
        // A directory per file, so two files of the same name both arrive
        // under it.
        for (const [index, file] of files.entries()) {
          const folder = join(root, String(index));
          await mkdir(folder, { mode: 0o700 });
          const path = join(folder, sanitizeFileName(file.name));
          upload.files.push({ path, size: file.size, written: 0, handle: await open(path, 'wx', 0o600) });
        }
      } catch (error) {
        await this.abortUpload();
        throw error;
      }
      return { done: await this.advance() };
    });
  }

  /**
   * Writes the next chunk of the upload the connection `key` began, base64
   * in `data`. Resolves `{ done, received, total }`; done once every file
   * is written and set on the input.
   *
   * @param {string} key
   * @param {{ chooser: string, data: string }} request
   */
  chunk(key, request) {
    return this.enqueue(async () => {
      this.assertAnswering(key, request?.chooser);
      const upload = this.upload;
      if (upload?.key !== key || upload.id !== request.chooser) throw new UploadError('bad_upload', 'Begin the upload before sending its files');

      let bytes = decodeChunk(request.data);
      if (upload.received + bytes.length > upload.total) {
        await this.abortUpload();
        throw new UploadError('bad_upload', 'More bytes arrived than the files hold');
      }
      this.restartTimer();
      upload.received += bytes.length;
      while (bytes.length > 0) {
        const file = upload.files[upload.index];
        const part = bytes.subarray(0, file.size - file.written);
        await file.handle.write(part);
        file.written += part.length;
        bytes = bytes.subarray(part.length);
        await this.advance();
      }
      if (upload.received - upload.reported >= PROGRESS_EVERY_BYTES) {
        upload.reported = upload.received;
        this.emit('progress', { id: upload.id, key, received: upload.received, total: upload.total });
      }
      return { done: upload.index === upload.files.length && this.upload !== upload, received: upload.received, total: upload.total };
    });
  }

  /**
   * Cancels the chooser `id` for the connection `key`, which must hold
   * control: the input keeps what it had.
   *
   * @param {string} key
   * @param {string} id
   */
  cancel(key, id) {
    return this.enqueue(async () => {
      this.assertAnswering(key, id);
      await this.discard('cancelled');
    });
  }

  assertAnswering(key, id) {
    if (this.lock.holder?.key !== key) throw new UploadError('not_driving', 'Only the person driving the browser can choose its files');
    if (!this.pending || this.pending.id !== id) throw new UploadError('no_chooser', 'That file chooser is no longer open');
  }

  // Closes the files written so far, and sets them on the input once all of
  // them are. Returns whether it did.
  async advance() {
    const upload = this.upload;
    while (upload.index < upload.files.length && upload.files[upload.index].written === upload.files[upload.index].size) {
      await upload.files[upload.index].handle.close();
      upload.index += 1;
    }
    if (upload.index < upload.files.length) return false;

    const { chooser } = this.pending;
    this.upload = null;
    try {
      await chooser.setFiles(upload.files.map((file) => file.path));
    } catch (error) {
      await this.discardFiles(upload);
      await this.discard(null);
      throw new UploadError('upload_failed', `The page did not take the files: ${error.message}`);
    }
    const user = this.lock.holder?.user ?? null;
    this.log(`live view: ${upload.files.length} file(s), ${upload.total} bytes, set on a file input`);
    this.emit('uploaded', { id: upload.id, user, files: upload.files.length, bytes: upload.total });
    await this.discard(null);
    return true;
  }

  // Stops the upload under way, removing what it wrote.
  async abortUpload() {
    const upload = this.upload;
    if (!upload) return;
    this.upload = null;
    await this.discardFiles(upload);
  }

  async discardFiles(upload) {
    for (const file of upload.files) await file.handle.close().catch(() => {});
    await rm(upload.root, { recursive: true, force: true }).catch(() => {});
    this.storedBytes -= upload.total;
  }

  // Withdraws the chooser on offer, and the upload under way for it.
  async discard(reason) {
    const pending = this.pending;
    if (!pending) return;
    clearTimeout(pending.timer);
    await this.abortUpload();
    this.pending = null;
    try {
      clearAgentFileChooser(pending.chooser.page(), pending.chooser);
    } catch {
      // The page closed.
    }
    if (reason) this.log(`live view: file chooser withdrawn (${reason})`);
    this.emit('change', null);
  }

  enqueue(work) {
    const run = this.queue.then(work);
    this.queue = run.catch(() => {});
    return run;
  }

  async close() {
    this.closed = true;
    this.listen(false);
    await this.enqueue(() => this.discard(null));
  }
}

function megabytes(bytes) {
  return `${Math.round((bytes / (1024 * 1024)) * 10) / 10} MB`;
}
