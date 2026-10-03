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
// one an input method is composing: its text arrives once composed
// (textMessage).
export function keyMessage(action, event) {
  if (event.isComposing || event.key === 'Process' || event.key === 'Unidentified' || !event.key) return null;

  return { type: 'key', action, key: event.key, code: event.code || '', keyCode: event.keyCode || undefined, modifiers: modifierMask(event) };
}

// Returns the message that types `text`, pasted or composed, or null for none.
export function textMessage(text) {
  return typeof text === 'string' && text !== '' ? { type: 'text', text: text.slice(0, 2000) } : null;
}

export const initialLiveViewState = {
  ready: false,
  canControl: false,
  control: { held: false, mine: false, by: null, since: null },
  agent: { waiting: false, tool: null, since: null },
  page: null,
  frameSize: null,
  error: null,
};

// Returns the view's state after one message from the sidecar, or after one
// of the view's own: { type: "clear_error" }, or { type: "reset" } when its
// connection closed. A frame changes only the frame's size: its pixels are
// drawn, not kept in state.
export function liveViewReducer(state, message) {
  switch (message?.type) {
    case 'ready':
      return {
        ...state,
        ready: true,
        canControl: message.can_control === true,
        control: message.control || initialLiveViewState.control,
        agent: message.agent || initialLiveViewState.agent,
        page: message.page || null,
      };
    case 'frame':
      if (state.frameSize?.width === message.width && state.frameSize?.height === message.height) return state;
      return { ...state, frameSize: { width: message.width, height: message.height } };
    case 'control':
      return {
        ...state,
        // Holding control proves this connection may take it: a watching
        // connection becomes one by sending a control ticket.
        canControl: state.canControl || message.mine === true,
        control: { held: message.held, mine: message.mine, by: message.by, since: message.since },
      };
    case 'agent':
      return { ...state, agent: { waiting: message.waiting, tool: message.tool, since: message.since } };
    case 'page':
      return { ...state, page: message.page || null };
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
  if (state.control.mine) return `The agent is waiting for you to hand back control${tool}.`;
  return `The agent is waiting for ${state.control.by || 'the person driving'} to hand back control${tool}.`;
}

// Returns who holds control, as the view labels it, or null when nobody does.
export function controlLabel(state) {
  if (!state.control.held) return null;
  if (state.control.mine) return 'You are driving';
  return `Held by ${state.control.by || 'someone else'}`;
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
