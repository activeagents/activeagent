// Turns the input a viewer relays into Chrome DevTools Protocol commands for
// the page on screen. A viewer sends pointer positions as fractions of the
// frame it was shown (0 to 1 from the left and top), and they are scaled to
// the page's CSS pixels from the latest frame's metadata.
//
// Messages:
//   { type: "mouse", action: "move"|"down"|"up", x, y, button, clickCount, modifiers }
//   { type: "wheel", x, y, deltaX, deltaY, modifiers }
//   { type: "key", action: "down"|"up", key, code, keyCode, modifiers }
//   { type: "text", text }
//
// `modifiers` is the CDP bit field: Alt 1, Ctrl 2, Meta 4, Shift 8.

const MOUSE_TYPES = { move: 'mouseMoved', down: 'mousePressed', up: 'mouseReleased' };
const BUTTONS = new Set(['none', 'left', 'middle', 'right']);
const CTRL = 2;
const META = 4;
const MAX_KEY_CHARS = 32;
const MAX_TEXT_CHARS = 2000;
const MAX_WHEEL_DELTA = 10_000;
// The text a key types when its key value is not the character itself.
const KEY_TEXT = { Enter: '\r' };
// Windows virtual key codes, for a key the viewer sent none for.
const KEY_CODES = {
  Backspace: 8, Tab: 9, Enter: 13, Shift: 16, Control: 17, Alt: 18, Pause: 19, CapsLock: 20, Escape: 27, ' ': 32,
  PageUp: 33, PageDown: 34, End: 35, Home: 36, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40,
  Insert: 45, Delete: 46, Meta: 91,
};

function fraction(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1;
}

function modifiers(value) {
  return Number.isInteger(value) && value >= 0 && value <= 15 ? value : 0;
}

function boundedNumber(value, limit) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 0;
  return Math.max(-limit, Math.min(limit, value));
}

/**
 * Returns the CSS pixel position of a point given as fractions of a frame
 * whose metadata is `metadata`, or null without a frame to scale by.
 *
 * @param {{ x: number, y: number }} point
 * @param {{ deviceWidth: number, deviceHeight: number, offsetTop?: number } | null} metadata
 * @returns {{ x: number, y: number } | null}
 */
export function pagePoint({ x, y }, metadata) {
  if (!fraction(x) || !fraction(y) || !metadata) return null;
  const { deviceWidth, deviceHeight, offsetTop = 0 } = metadata;
  if (!(deviceWidth > 0) || !(deviceHeight > 0)) return null;

  return { x: Math.round(x * deviceWidth), y: Math.round(y * deviceHeight + offsetTop) };
}

/**
 * Returns `[method, params]` for one relayed input message, or null when the
 * message is not one the viewer may send, or a pointer message arrives
 * before any frame was shown.
 *
 * @param {object} message
 * @param {object | null} metadata the latest frame's metadata
 * @returns {[string, object] | null}
 */
export function inputCommand(message, metadata) {
  switch (message?.type) {
    case 'mouse':
      return mouseCommand(message, metadata);
    case 'wheel':
      return wheelCommand(message, metadata);
    case 'key':
      return keyCommand(message);
    case 'text':
      return textCommand(message);
    default:
      return null;
  }
}

function mouseCommand(message, metadata) {
  const type = MOUSE_TYPES[message.action];
  const point = pagePoint(message, metadata);
  if (!type || !point) return null;

  const button = BUTTONS.has(message.button) ? message.button : type === 'mouseMoved' ? 'none' : 'left';
  const clickCount = Number.isInteger(message.clickCount) && message.clickCount >= 0 && message.clickCount <= 3 ? message.clickCount : 1;
  const params = { type, ...point, button, modifiers: modifiers(message.modifiers) };
  if (type !== 'mouseMoved') params.clickCount = clickCount;
  return ['Input.dispatchMouseEvent', params];
}

function wheelCommand(message, metadata) {
  const point = pagePoint(message, metadata);
  if (!point) return null;

  return ['Input.dispatchMouseEvent', {
    type: 'mouseWheel',
    ...point,
    deltaX: boundedNumber(message.deltaX, MAX_WHEEL_DELTA),
    deltaY: boundedNumber(message.deltaY, MAX_WHEEL_DELTA),
    modifiers: modifiers(message.modifiers),
  }];
}

// The text a key down types: the character of a printable key, or Enter's
// carriage return. A key pressed with Ctrl or Meta is a shortcut and types
// nothing.
function keyText(key, mask) {
  if (mask & (CTRL | META)) return '';
  if (KEY_TEXT[key]) return KEY_TEXT[key];
  return [...key].length === 1 ? key : '';
}

function keyCommand(message) {
  const { action, key } = message;
  if ((action !== 'down' && action !== 'up') || typeof key !== 'string' || key === '' || key.length > MAX_KEY_CHARS) return null;

  const code = typeof message.code === 'string' && message.code.length <= MAX_KEY_CHARS ? message.code : '';
  const mask = modifiers(message.modifiers);
  let keyCode = Number.isInteger(message.keyCode) && message.keyCode > 0 && message.keyCode < 256 ? message.keyCode : KEY_CODES[key];
  if (keyCode === undefined && /^[a-z0-9]$/i.test(key)) keyCode = key.toUpperCase().charCodeAt(0);

  const params = { key, code, modifiers: mask, windowsVirtualKeyCode: keyCode ?? 0 };
  if (action === 'up') return ['Input.dispatchKeyEvent', { type: 'keyUp', ...params }];

  const text = keyText(key, mask);
  return ['Input.dispatchKeyEvent', text ? { type: 'keyDown', ...params, text, unmodifiedText: text } : { type: 'rawKeyDown', ...params }];
}

function textCommand(message) {
  if (typeof message.text !== 'string' || message.text === '' || message.text.length > MAX_TEXT_CHARS) return null;

  return ['Input.insertText', { text: message.text }];
}
