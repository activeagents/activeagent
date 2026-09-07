// Generative UI parsing.
//
// An assistant can answer with UI instead of (or alongside) prose in three
// shapes: a fenced ```ui block of JSON inside markdown, a whole-message JSON
// object with a top-level `ui`/`blocks` array, or a `render_ui` tool call.
// These helpers turn each of those into a plain array of block objects for
// GenerativeUI to render. No React in here — the runner's tests exercise the
// parsing on its own, and the same rules apply wherever a message is shown.

// Fence languages that mark a UI block. A plain ```json fence also counts
// when its object carries a `ui` array — models that were told about the
// contract but reach for their usual fence still render.
export const UI_FENCE_LANGS = ['ui', 'json-ui', 'genui'];

// The tool the toolbox exposes for interactive answers.
export const UI_TOOL_NAME = 'render_ui';

const isPlainObject = (value) =>
  value != null && typeof value === 'object' && !Array.isArray(value);

const tryParse = (text) => {
  if (typeof text !== 'string') return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
};

// The block list inside a container, whatever the container looks like: a
// bare array of blocks, `{ blocks: [...] }`, `{ ui: [...] }`, or a JSON string
// of any of those. `null` when the value is not a block list — an array with a
// non-object entry is refused whole rather than rendered with holes, so a
// malformed fence stays visible as code instead of silently losing items.
export function blocksFromValue(value) {
  const parsed = typeof value === 'string' ? tryParse(value) : value;
  if (Array.isArray(parsed)) {
    return parsed.every(isPlainObject) ? parsed : null;
  }
  if (isPlainObject(parsed)) {
    if (Array.isArray(parsed.blocks)) return parsed.blocks.every(isPlainObject) ? parsed.blocks : null;
    if (Array.isArray(parsed.ui)) return parsed.ui.every(isPlainObject) ? parsed.ui : null;
  }
  return null;
}

// Blocks carried by one fenced code block, given its language tag and body.
// `null` for every fence that is not UI — including a ```ui fence whose body
// is not valid JSON, which the caller renders as ordinary code.
export function uiFenceBlocks(lang, body) {
  const tag = String(lang || '').trim().toLowerCase();
  if (UI_FENCE_LANGS.includes(tag)) return blocksFromValue(body);
  if (tag === 'json') {
    const parsed = tryParse(body);
    return isPlainObject(parsed) && Array.isArray(parsed.ui) ? blocksFromValue(parsed) : null;
  }
  return null;
}

// A message whose entire content is one JSON value. Returns `{ blocks }`
// when it is a UI container, `{ object }` for any other object or array
// (structured output the object block renders as key/value tables), and
// `null` for prose.
export function structuredContent(text) {
  if (typeof text !== 'string') return null;
  const trimmed = text.trim();
  const looksLikeObject = trimmed.startsWith('{') && trimmed.endsWith('}');
  const looksLikeArray = trimmed.startsWith('[') && trimmed.endsWith(']');
  if (!looksLikeObject && !looksLikeArray) return null;
  const parsed = tryParse(trimmed);
  if (parsed == null || typeof parsed !== 'object') return null;
  if (Array.isArray(parsed)) {
    const allBlocks = parsed.length > 0 && parsed.every((item) => isPlainObject(item) && typeof item.type === 'string');
    return allBlocks ? { blocks: parsed } : { object: parsed };
  }
  const blocks = blocksFromValue(parsed);
  return blocks ? { blocks } : { object: parsed };
}

// Splits markdown into the UI blocks it carries and the markdown left over
// once their fences are removed. Non-UI fences (and UI fences with invalid
// JSON) are kept verbatim so the markdown renderer still shows them as code.
// A message that is one whole JSON UI container yields its blocks and no
// text.
export function extractUiBlocks(text) {
  if (text == null) return { blocks: [], text: '' };
  const source = String(text);
  const lines = source.split('\n');
  const kept = [];
  const blocks = [];
  let i = 0;

  while (i < lines.length) {
    const open = lines[i].match(/^```(.*)$/);
    if (!open) {
      kept.push(lines[i]);
      i += 1;
      continue;
    }
    // Same fence rules as Markdown.jsx: the body runs to the next line that
    // starts with ```; an unclosed fence swallows the rest of the message.
    let j = i + 1;
    const body = [];
    while (j < lines.length && !lines[j].startsWith('```')) {
      body.push(lines[j]);
      j += 1;
    }
    const closed = j < lines.length;
    const found = closed ? uiFenceBlocks(open[1], body.join('\n')) : null;
    if (found) {
      blocks.push(...found);
    } else {
      for (let k = i; k <= Math.min(j, lines.length - 1); k += 1) kept.push(lines[k]);
    }
    i = j + 1;
  }

  if (blocks.length === 0) {
    const whole = structuredContent(source);
    if (whole && whole.blocks) return { blocks: whole.blocks, text: '' };
  }

  return { blocks, text: kept.join('\n').replace(/\n{3,}/g, '\n\n').trim() };
}

const callName = (call) => (isPlainObject(call) ? call.function?.name || call.name : undefined);
const callArguments = (call) =>
  isPlainObject(call) ? (call.function?.arguments ?? call.arguments ?? call.input) : undefined;

// Blocks requested through the render_ui tool, from either side of the call:
// the tool row (`tool_arguments`, a JSON string or object, possibly wrapped
// in `{ blocks }`) or the assistant row that issued it (`tool_calls[]`, in
// provider shape or the bare arguments object the trace serializer emits).
// `callId` narrows an assistant row with several calls to the one a given
// tool row answers; when no call carries an id every render_ui call counts.
export function blocksFromToolCall(message, { callId } = {}) {
  if (!isPlainObject(message)) return null;

  if (message.tool_name === UI_TOOL_NAME && message.tool_arguments != null) {
    const fromArguments = blocksFromValue(message.tool_arguments);
    if (fromArguments) return fromArguments;
  }

  const calls = message.tool_calls;
  const out = [];
  if (Array.isArray(calls)) {
    const anyIds = calls.some((call) => isPlainObject(call) && call.id != null);
    calls.forEach((call) => {
      if (callName(call) !== UI_TOOL_NAME) return;
      if (callId != null && anyIds && call.id != null && call.id !== callId) return;
      const found = blocksFromValue(callArguments(call));
      if (found) out.push(...found);
    });
  } else if (isPlainObject(calls) && message.tool_name === UI_TOOL_NAME) {
    const found = blocksFromValue(calls);
    if (found) out.push(...found);
  }

  return out.length > 0 ? out : null;
}

// Image sources a block may load. Model output is untrusted, so only
// absolute http(s) URLs and inline image data are allowed — never
// javascript:, blob:, or relative paths that would resolve inside the host.
export function isSafeImageUrl(url) {
  return typeof url === 'string' && /^(https?:\/\/|data:image\/)/i.test(url.trim());
}
