// The start configuration, read as JSON from stdin (or a file the image is
// given), so the bearer token never appears in argv or the environment:
//
//   {
//     "token": "...",                       bearer token every request must carry
//     "app_url": "http://127.0.0.1:3000",   the sandbox app; top-level navigation stays on its origin
//     "mode": "headless" | "headed",
//     "capabilities": ["testing"],          optional Playwright MCP tool groups
//     "host": "127.0.0.1", "port": 0,       where the MCP endpoint listens (0 picks a free port)
//     "allowed_hosts": ["browser:8931"],    Host header values accepted besides the listening address
//     "workdir": "/path",                   where the profile, uploads and output directories go
//     "stop_at": 1767225600000,             when to shut down on its own (epoch ms or ISO 8601)
//     "chromium_sandbox": true,             false where Chromium's own sandbox cannot run (some containers)
//     "recording": { "url": "...", "token": "...", "batch_events": 1000, "batch_bytes": 1048576 },
//     "storage_state": { "cookies": [...], "origins": [...] }   a saved sign-in the browser starts with
//   }

import { appStorageState, StorageStateError } from './storage-state.mjs';

export const MODES = ['headless', 'headed'];
// Tool groups a browser may be started with. The others reach outside the
// page: devtools writes traces and videos, storage reads and writes storage
// state files, network rewrites responses, config describes the server.
export const CAPABILITIES = ['testing', 'vision', 'pdf'];
export const MIN_TOKEN_LENGTH = 32;
const DEFAULT_BATCH_EVENTS = 1000;
const DEFAULT_BATCH_BYTES = 1024 * 1024;

export class ConfigError extends Error {}

function fail(message) {
  throw new ConfigError(message);
}

function httpUrl(value, name) {
  let url;
  try {
    url = new URL(value);
  } catch {
    fail(`${name} must be an absolute http(s) URL`);
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') fail(`${name} must be an absolute http(s) URL`);
  if (url.username || url.password) fail(`${name} must not carry credentials`);
  return url;
}

function token(value, name) {
  if (typeof value !== 'string' || value.length < MIN_TOKEN_LENGTH || /\s/.test(value)) {
    fail(`${name} must be a string of at least ${MIN_TOKEN_LENGTH} characters without whitespace`);
  }
  return value;
}

function positiveInteger(value, name, fallback) {
  if (value === undefined || value === null) return fallback;
  if (!Number.isInteger(value) || value <= 0) fail(`${name} must be a positive integer`);
  return value;
}

function stopAt(value) {
  if (value === undefined || value === null) return null;
  const time = typeof value === 'number' ? value : Date.parse(value);
  if (!Number.isFinite(time)) fail('stop_at must be epoch milliseconds or an ISO 8601 time');
  return time;
}

function recording(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) fail('recording must be an object');

  return {
    url: httpUrl(value.url, 'recording.url').toString(),
    token: token(value.token, 'recording.token'),
    batchEvents: positiveInteger(value.batch_events, 'recording.batch_events', DEFAULT_BATCH_EVENTS),
    batchBytes: positiveInteger(value.batch_bytes, 'recording.batch_bytes', DEFAULT_BATCH_BYTES),
  };
}

/**
 * Validates a start configuration and returns it with camelCase keys.
 *
 * @param {string|object} input the configuration, as JSON text or parsed
 * @returns {object}
 * @throws {ConfigError} naming the first invalid setting
 */
export function parseConfig(input) {
  let raw = input;
  if (typeof input === 'string') {
    try {
      raw = JSON.parse(input);
    } catch {
      fail('the configuration is not JSON');
    }
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) fail('the configuration must be a JSON object');

  const mode = raw.mode ?? 'headless';
  if (!MODES.includes(mode)) fail(`mode must be one of ${MODES.join(', ')}`);

  const capabilities = raw.capabilities ?? [];
  if (!Array.isArray(capabilities) || capabilities.some((name) => !CAPABILITIES.includes(name))) {
    fail(`capabilities may only name ${CAPABILITIES.join(', ')}`);
  }

  const allowedHosts = raw.allowed_hosts ?? [];
  if (!Array.isArray(allowedHosts) || allowedHosts.some((host) => typeof host !== 'string' || host === '')) {
    fail('allowed_hosts must be a list of host names');
  }

  const port = raw.port ?? 0;
  if (!Number.isInteger(port) || port < 0 || port > 65535) fail('port must be an integer from 0 to 65535');

  if (raw.chromium_sandbox !== undefined && typeof raw.chromium_sandbox !== 'boolean') fail('chromium_sandbox must be true or false');

  if (raw.workdir !== undefined && raw.workdir !== null && (typeof raw.workdir !== 'string' || raw.workdir === '')) {
    fail('workdir must be a directory path');
  }

  const appOrigin = httpUrl(raw.app_url, 'app_url').origin;
  let storageState = null;
  if (raw.storage_state !== undefined && raw.storage_state !== null) {
    try {
      storageState = appStorageState(raw.storage_state, appOrigin);
    } catch (error) {
      if (error instanceof StorageStateError) fail(error.message);
      throw error;
    }
  }

  return {
    token: token(raw.token, 'token'),
    appOrigin,
    mode,
    capabilities: [...new Set(capabilities)],
    host: typeof raw.host === 'string' && raw.host !== '' ? raw.host : '127.0.0.1',
    port,
    allowedHosts: allowedHosts.map((host) => host.toLowerCase()),
    workdir: raw.workdir ?? null,
    chromiumSandbox: raw.chromium_sandbox !== false,
    stopAt: stopAt(raw.stop_at),
    recording: recording(raw.recording),
    storageState,
  };
}
