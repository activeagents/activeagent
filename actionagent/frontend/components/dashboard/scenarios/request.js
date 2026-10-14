import { apiErrorMessage } from '../../../utils/codeSessions.mjs';

// Sends a JSON request to the dashboard's API and answers its parsed body,
// or throws an Error with the server's message (or `fallback` and the
// status) when it refused.
export async function requestJson(path, { method = 'GET', body, fallback = 'The request failed' } = {}) {
  const init = { method };
  if (body !== undefined) {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(body);
  }
  const res = await fetch(path, init);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(apiErrorMessage(data, `${fallback} (HTTP ${res.status}).`));
  return data;
}

// The YAML an export URL answers, as text.
export async function requestText(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`The export failed (HTTP ${res.status}).`);
  return res.text();
}
