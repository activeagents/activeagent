// Attachment helpers shared by the composer (files not yet uploaded) and the
// conversation rows (the manifest the run persisted). Both render the same
// chip, so both describe a file the same way.

// Mirrors AgentRun#attachment_manifest's `kind` so a pending chip and the
// persisted one agree before and after the upload.
const TEXT_TYPES = ['application/json', 'application/xml', 'application/x-yaml', 'application/csv'];
const TEXT_EXTENSIONS = /\.(csv|md|txt|json|ya?ml)$/i;

export function attachmentKind(file) {
  const type = String(file?.type || file?.content_type || '').toLowerCase();
  const name = String(file?.name || file?.filename || '');
  if (type.startsWith('image/')) return 'image';
  if (type === 'application/pdf') return 'document';
  if (type.startsWith('text/') || TEXT_TYPES.includes(type) || TEXT_EXTENSIONS.test(name)) return 'text';
  return 'file';
}

export function formatBytes(bytes) {
  const size = Number(bytes);
  if (!Number.isFinite(size) || size < 0) return '';
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

// Thumbnails come from the host's Active Storage routes (root-relative), the
// composer's object URLs, or inline data — never from a bare model string.
// An absolute URL is allowed only on this app's own origin: "//host/x.png"
// and "/\host/x.png" wear a root-relative look but load from elsewhere.
export function isRenderableAttachmentUrl(url) {
  if (typeof url !== 'string') return false;
  const value = url.trim();
  if (/^(data:image\/|blob:)/i.test(value)) return true;
  if (/^\/[\\/]/.test(value)) return false;
  if (value.startsWith('/')) return true;
  if (!/^https?:\/\//i.test(value)) return false;
  if (typeof window === 'undefined' || !window.location) return false;
  try {
    return new URL(value, window.location.href).origin === window.location.origin;
  } catch {
    return false;
  }
}
