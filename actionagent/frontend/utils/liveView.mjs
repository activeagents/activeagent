// The live view of a sandbox's browser: what the viewer's mouse, wheel and
// keys become on the wire, and what the sidecar's messages make of the view's
// state. The protocol is described in browser-sidecar/README.md.
//
// Pointer positions are sent as fractions of the frame (0 to 1 from the left
// and top), so the sidecar scales them to the page whatever size the frame
// is drawn at.

// The CDP modifier bit field: Alt 1, Ctrl 2, Meta 4, Shift 8.
export function modifierMask(event) {
  return (event.altKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.metaKey ? 4 : 0) | (event.shiftKey ? 8 : 0);
}

const BUTTONS = ['left', 'middle', 'right'];

// Returns where `clientX`/`clientY` fall in `rect` (the drawn frame's
// bounding box), as fractions, or null when outside it or it has no size.
export function framePoint(clientX, clientY, rect) {
  if (!rect || !(rect.width > 0) || !(rect.height > 0)) return null;
  const x = (clientX - rect.left) / rect.width;
  const y = (clientY - rect.top) / rect.height;
  if (x < 0 || x > 1 || y < 0 || y > 1) return null;
  return { x, y };
}

// Returns the message for a mouse event (`action` "move", "down" or "up"),
// or null when it is outside the frame.
export function mouseMessage(action, event, rect) {
  const point = framePoint(event.clientX, event.clientY, rect);
  if (!point) return null;

  const message = { type: 'mouse', action, ...point, modifiers: modifierMask(event) };
  if (action === 'move') return { ...message, button: event.buttons & 1 ? 'left' : 'none' };
  return { ...message, button: BUTTONS[event.button] || 'left', clickCount: Math.min(Math.max(event.detail || 1, 1), 3) };
}

// Returns the message that releases a button pressed on the frame: where
// the pointer is when it is over the frame, otherwise at `lastPoint`, the
// last place it was over it. Null with neither.
export function releaseMessage(event, rect, lastPoint) {
  const inside = mouseMessage('up', event, rect);
  if (inside || !lastPoint) return inside;

  return {
    type: 'mouse', action: 'up', x: lastPoint.x, y: lastPoint.y, modifiers: modifierMask(event),
    button: BUTTONS[event.button] || 'left', clickCount: 1,
  };
}

const LINE_PIXELS = 16;
const PAGE_PIXELS = 800;

// Returns the message for a wheel event, its delta in pixels whatever unit
// the event used, or null when it is outside the frame.
export function wheelMessage(event, rect) {
  const point = framePoint(event.clientX, event.clientY, rect);
  if (!point) return null;

  const scale = event.deltaMode === 1 ? LINE_PIXELS : event.deltaMode === 2 ? PAGE_PIXELS : 1;
  return { type: 'wheel', ...point, deltaX: event.deltaX * scale, deltaY: event.deltaY * scale, modifiers: modifierMask(event) };
}

// Returns the message for a key event (`action` "down" or "up"), or null for
// a key an input method is composing, which is not sent.
export function keyMessage(action, event) {
  if (event.isComposing || event.key === 'Process' || event.key === 'Unidentified' || !event.key) return null;

  return { type: 'key', action, key: event.key, code: event.code || '', keyCode: event.keyCode || undefined, modifiers: modifierMask(event) };
}

// Returns the message that types `text`, as a paste does, or null for none.
export function textMessage(text) {
  return typeof text === 'string' && text !== '' ? { type: 'text', text: text.slice(0, 2000) } : null;
}

// How soon a second Escape has to follow the first to move focus out of the
// view.
export const LEAVE_VIEW_MS = 600;

// Whether a keydown is the second of two quick presses of Escape, which
// moves focus out of the view instead of reaching the page. `previousAt` is
// the timeStamp of the keydown before it when that was a fresh press of
// Escape, otherwise null. The first press reaches the page as usual.
export function leavesView(event, previousAt) {
  if (event.key !== 'Escape' || event.repeat || previousAt === null) return false;
  return event.timeStamp - previousAt <= LEAVE_VIEW_MS;
}

// The bytes in one file_chunk message, before base64: what the sidecar takes.
export const UPLOAD_CHUNK_BYTES = 32 * 1024;

// Returns `bytes` (a Uint8Array) as base64, a slice at a time so a large
// chunk does not overflow String.fromCharCode's arguments.
export function encodeChunk(bytes) {
  let binary = '';
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

function sizeLabel(bytes) {
  if (bytes >= 1024 * 1024) return `${Math.round((bytes / (1024 * 1024)) * 10) / 10} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} bytes`;
}

// Returns what the files a person chose for `chooser` (the sidecar's
// file_chooser) upload as: { files: [{ name, size }], total }, or { error }
// when the sidecar would refuse them.
export function uploadPlan(files, chooser) {
  const list = Array.from(files || []);
  if (!chooser) return { error: 'The page is no longer asking for a file.' };
  if (list.length === 0) return { error: 'Choose a file to upload.' };
  const limit = chooser.multiple ? chooser.max_files : 1;
  if (list.length > limit) return { error: limit === 1 ? 'This field takes one file.' : `This field takes at most ${limit} files.` };
  const large = list.find((file) => file.size > chooser.max_file_bytes);
  if (large) return { error: `${large.name} is larger than ${sizeLabel(chooser.max_file_bytes)}.` };

  return { files: list.map((file) => ({ name: file.name, size: file.size })), total: list.reduce((sum, file) => sum + file.size, 0) };
}

// Returns how an upload under way reads, from `upload` ({ sent, total }).
export function uploadProgressLabel(upload) {
  if (!upload) return null;
  const percent = upload.total > 0 ? Math.min(100, Math.floor((upload.sent / upload.total) * 100)) : 100;
  return `Uploading ${sizeLabel(upload.total)}… ${percent}%`;
}

// Returns what a viewer who is not driving is told while the page waits for
// a file, or null when it is not waiting, or this viewer is driving.
export function fileChooserWaitLabel(state) {
  if (!state.fileChooser || state.control.mine) return null;
  if (state.control.yours) return 'The page is asking for a file. Choose it in the view you are driving from.';
  return `The page is asking ${state.control.by || 'the person driving'} for a file.`;
}

export const initialLiveViewState = {
  ready: false,
  control: { held: false, mine: false, yours: false, by: null, since: null },
  agent: { waiting: false, tool: null, since: null, client: null },
  page: null,
  frameSize: null,
  fileChooser: null,
  // An agent's request for a person to take over: { reason, client, at }.
  personRequest: null,
  error: null,
};

// Returns the view's state after one message from the sidecar, or after one
// of the view's own: { type: "clear_error" }, or { type: "reset" } when its
// connection closed. A failed upload shows as the view's error. A frame changes only the frame's size: its pixels are
// drawn, not kept in state.
export function liveViewReducer(state, message) {
  switch (message?.type) {
    case 'ready':
      return {
        ...state,
        ready: true,
        control: { ...initialLiveViewState.control, ...message.control },
        agent: { ...initialLiveViewState.agent, ...message.agent },
        page: message.page || null,
        fileChooser: message.file_chooser || null,
        personRequest: message.person_request || null,
      };
    case 'frame':
      if (state.frameSize?.width === message.width && state.frameSize?.height === message.height) return state;
      return { ...state, frameSize: { width: message.width, height: message.height } };
    case 'control':
      return {
        ...state,
        control: { held: message.held, mine: message.mine, yours: message.yours === true, by: message.by, since: message.since },
      };
    case 'agent':
      return { ...state, agent: { waiting: message.waiting, tool: message.tool, since: message.since, client: message.client || null } };
    case 'person_requested':
      return { ...state, personRequest: message.request || null };
    case 'page':
      return { ...state, page: message.page || null };
    case 'file_chooser':
      return { ...state, fileChooser: message.chooser || null };
    case 'file_upload':
      return message.status === 'failed' ? { ...state, error: message.message || 'The upload failed' } : state;
    case 'error':
      return { ...state, error: message.message || 'The browser refused that' };
    case 'clear_error':
      return { ...state, error: null };
    case 'reset':
      return initialLiveViewState;
    default:
      return state;
  }
}

// Returns the banner to show while an agent's browser call waits for the
// person driving to hand back control, or null.
export function agentBanner(state) {
  if (!state.agent.waiting || !state.control.held) return null;

  const tool = state.agent.tool ? ` (${state.agent.tool})` : '';
  const who = state.agent.client || 'The agent';
  if (state.control.mine) return `${who} is waiting for you to hand back control${tool}.`;
  if (state.control.yours) return `${who} is waiting for you to hand back control in your other view${tool}.`;
  return `${who} is waiting for ${state.control.by || 'the person driving'} to hand back control${tool}.`;
}

// Returns the banner to show while an agent asks for a person to take over
// the browser, or null. It stands until someone takes control.
export function personRequestBanner(state) {
  const request = state.personRequest;
  if (!request || state.control.held) return null;

  return `${request.client || 'The agent'} needs a person: ${request.reason}`;
}

// What a viewer who held control reports when handing it back, for the next
// message to the agent: who drove, when they took and handed back control,
// and the page they left it on. `takenAt` and `releasedAt` are epoch ms.
export function handoffReport({ by = null, takenAt, releasedAt, page = null }) {
  const iso = (ms) => (Number.isFinite(ms) ? new Date(ms).toISOString() : null);
  return {
    by: by || null,
    taken_at: iso(takenAt),
    released_at: iso(releasedAt),
    page_url: typeof page?.url === 'string' && /^https?:\/\//.test(page.url) ? page.url : null,
  };
}

// Returns who holds control, as the view labels it, or null when nobody does.
export function controlLabel(state) {
  if (!state.control.held) return null;
  if (state.control.mine) return 'You are driving';
  if (state.control.yours) return 'You are driving in another view';
  return `Held by ${state.control.by || 'someone else'}`;
}

// Returns the button that takes control for a view that does not hold it:
// { label, disabled }. A person driving in another view of theirs, such as
// the tab they had open before a reload, may carry on in this one.
export function takeOverButton(state, { taking = false } = {}) {
  const { held, yours } = state.control;
  let label = 'Take over';
  if (taking) label = 'Taking over…';
  else if (held && yours) label = 'Continue driving here';

  return { label, disabled: taking || (held && !yours) };
}

// Returns the page on screen as one line: its address, and which tab it is
// when there are several.
export function pageLabel(page) {
  if (!page) return null;
  const tab = page.tabs > 1 ? ` · tab ${page.tab} of ${page.tabs}` : '';
  return `${page.url || 'a page with no address to show'}${tab}`;
}

const CLOSE_MESSAGES = {
  1001: 'The browser stopped.',
  4401: 'The live view did not accept the ticket. Try again.',
  4408: 'The live view timed out before it opened. Try again.',
  4429: 'Too many people are watching this browser.',
};

// Returns why the live view's connection closed, as the view says it, or
// null for a close the viewer asked for.
export function closeMessage(code, { requested = false } = {}) {
  if (requested) return null;
  return CLOSE_MESSAGES[code] || 'The live view lost its connection to the browser.';
}

const BROWSER_STATUSES = {
  starting: { label: 'Starting', tone: 'progress' },
  running: { label: 'Running', tone: 'success' },
  stopped: { label: 'Stopped', tone: 'neutral' },
  failed: { label: 'Failed', tone: 'error' },
};

// Returns a sandbox browser's status as a badge shows it, or null when the
// sandbox has never started one.
export function browserStatus(browser) {
  if (!browser?.status) return null;
  return BROWSER_STATUSES[browser.status] || { label: browser.status, tone: 'neutral' };
}

// Whether a browser is starting or running, and so has to be stopped before
// another starts.
export function isBrowserActive(browser) {
  return browser?.status === 'starting' || browser?.status === 'running';
}

// Returns the body that starts a browser: in a window on the dashboard's
// machine when `inWindow` and the backend can show one, without a window
// otherwise.
export function browserStartBody({ inWindow = false, modes = [] } = {}) {
  return { mode: inWindow && modes.includes('headed') ? 'headed' : 'headless' };
}
