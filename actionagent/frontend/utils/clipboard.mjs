// Puts text on the clipboard: the async Clipboard API where the page has it
// (a secure context with permission), else a selected textarea and the
// legacy copy command, which still works on http:// dev hosts. Resolves true
// when something copied, false when nothing could; never throws.
export async function copyToClipboard(text, { navigator: nav = globalThis.navigator, document: doc = globalThis.document } = {}) {
  const value = String(text ?? '');
  if (nav?.clipboard?.writeText) {
    try {
      await nav.clipboard.writeText(value);
      return true;
    } catch {
      // Fall through to the legacy command.
    }
  }
  if (!doc?.body || typeof doc.execCommand !== 'function') return false;
  const area = doc.createElement('textarea');
  area.value = value;
  area.setAttribute('readonly', '');
  area.style.position = 'fixed';
  area.style.top = '0';
  area.style.left = '0';
  area.style.opacity = '0';
  doc.body.appendChild(area);
  try {
    area.select();
    if (typeof area.setSelectionRange === 'function') area.setSelectionRange(0, value.length);
    return doc.execCommand('copy') === true;
  } catch {
    return false;
  } finally {
    doc.body.removeChild(area);
  }
}
