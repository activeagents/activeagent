// The MCP Services page's own servers: remote MCP servers a user adds by URL,
// with optional request headers, and enables on agents as "custom:<id>".
//
// Header values are write-only. The API returns each header's name with a
// masked hint, and on update a header sent with a blank value keeps the value
// stored under that name. The form therefore holds a stored header with an
// empty value and its hint as the placeholder, and only a value the person
// types replaces it.

export const CUSTOM_KEY_PREFIX = 'custom:';

// The headers MCPClient sets itself, which a server's configuration cannot
// replace. Mirrors MCPServerConfig::RESERVED_HEADERS.
export const RESERVED_HEADERS = [
  'accept', 'content-type', 'content-length', 'host', 'mcp-session-id', 'user-agent', 'connection',
  'transfer-encoding',
];

// An HTTP header field name (RFC 9110 token).
const HEADER_NAME = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

// A server the owner added, which an agent enables as "custom:<id>". The API
// marks those rows `custom: true`; the key prefix is read too.
export const isCustomServer = (row) => Boolean(
  row && (row.custom === true || String(row.key || '').startsWith(CUSTOM_KEY_PREFIX)),
);

// A blank form for a new server.
export function emptyDraft() {
  return { id: null, name: '', description: '', url: '', enabled: true, headers: [] };
}

// The form for an existing server. A stored header carries its masked hint
// and an empty value, which keeps the stored value unless one is typed.
export function draftFrom(config) {
  return {
    id: config.id,
    name: config.name || '',
    description: config.description || '',
    url: config.url || '',
    enabled: config.enabled !== false,
    headers: (config.headers || []).map((header) => ({
      name: header.name,
      value: '',
      hint: header.hint || '',
      stored: true,
    })),
  };
}

// Adds an empty header row.
export function addHeader(draft) {
  return { ...draft, headers: [...draft.headers, { name: '', value: '', hint: '', stored: false }] };
}

// Changes one field of the header at +index+. Renaming a stored header makes
// it a new one: the value stored under the old name does not follow it.
export function updateHeader(draft, index, field, value) {
  const headers = draft.headers.map((header, position) => {
    if (position !== index) return header;
    const next = { ...header, [field]: value };
    if (field === 'name' && header.stored && value.trim().toLowerCase() !== header.name.trim().toLowerCase()) {
      next.stored = false;
      next.hint = '';
    }
    return next;
  });
  return { ...draft, headers };
}

export function removeHeader(draft, index) {
  return { ...draft, headers: draft.headers.filter((_, position) => position !== index) };
}

// What is wrong with the form before it is sent: { url, name, headers }, each
// a message or absent. The server checks the same rules, and also refuses a
// private or loopback address unless the host app allows them.
export function validateDraft(draft) {
  const errors = {};
  if (!draft.name.trim()) errors.name = 'Name the server.';

  const url = draft.url.trim();
  if (!url) {
    errors.url = 'Enter the server’s URL.';
  } else {
    let parsed = null;
    try {
      parsed = new URL(url);
    } catch {
      parsed = null;
    }
    if (!parsed || !['http:', 'https:'].includes(parsed.protocol)) {
      errors.url = 'Use an http:// or https:// URL.';
    } else if (parsed.username || parsed.password) {
      errors.url = 'Send credentials in a header, not in the URL.';
    }
  }

  const seen = new Set();
  for (const header of draft.headers) {
    const name = header.name.trim();
    if (!name) {
      if (header.value.trim()) errors.headers = 'Every header needs a name.';
      continue;
    }
    const lower = name.toLowerCase();
    if (!HEADER_NAME.test(name)) {
      errors.headers = `${name} is not a valid header name.`;
    } else if (RESERVED_HEADERS.includes(lower)) {
      errors.headers = `${name} is set by the MCP client and cannot be replaced.`;
    } else if (seen.has(lower)) {
      errors.headers = `${name} is listed twice.`;
    } else if (!header.stored && !header.value.trim()) {
      errors.headers = `${name} needs a value.`;
    } else if (/[\r\n]/.test(header.value)) {
      errors.headers = `${name} must not contain line breaks.`;
    }
    seen.add(lower);
  }

  return errors;
}

export const hasErrors = (errors) => Object.keys(errors).length > 0;

// The create or update request body. Header rows with no name are dropped;
// a stored header with no value typed is sent blank, which keeps its value.
export function requestBody(draft) {
  return {
    mcp_server_config: {
      name: draft.name.trim(),
      description: draft.description.trim(),
      url: draft.url.trim(),
      enabled: draft.enabled,
      headers: draft.headers
        .filter((header) => header.name.trim())
        .map((header) => ({ name: header.name.trim(), value: header.value })),
    },
  };
}

// The API's error body as one line: a message, or a list of them.
export function errorText(body, fallback = 'Something went wrong.') {
  const error = body && body.error;
  if (Array.isArray(error)) return error.join(' ') || fallback;
  return error ? String(error) : fallback;
}

// The badge a server's last connection test earns: { tone, label, title }.
export function testStatus(config) {
  if (!config.last_tested_at || !config.last_test_status) {
    return { tone: 'muted', label: 'Not tested', title: 'Test the connection to list the tools it serves' };
  }
  if (config.last_test_status === 'ok') {
    const count = (config.tools || []).length;
    return {
      tone: 'success',
      label: `Connected · ${count} tool${count === 1 ? '' : 's'}`,
      title: `Last tested ${config.last_tested_at}`,
    };
  }
  return { tone: 'error', label: 'Failed', title: config.last_test_error || 'The last test failed' };
}
