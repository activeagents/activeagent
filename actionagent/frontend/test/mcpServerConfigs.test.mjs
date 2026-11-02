import test from 'node:test';
import assert from 'node:assert/strict';

import {
  addHeader,
  draftFrom,
  emptyDraft,
  errorText,
  hasErrors,
  isCustomServer,
  removeHeader,
  requestBody,
  testStatus,
  updateHeader,
  validateDraft,
} from '../utils/mcpServerConfigs.mjs';
import { emptyToolsHint, isRemovedCustomServer, isUndocumented } from '../utils/toolRoster.mjs';

const stored = {
  id: 7,
  key: 'custom:7',
  name: 'Orders',
  description: '',
  url: 'https://app.example.com/mcp',
  enabled: true,
  headers: [{ name: 'Authorization', hint: '••••0001' }],
  tools: ['find_order'],
  last_tested_at: '2026-10-27T12:00:00Z',
  last_test_status: 'ok',
};

const draftWith = (overrides) => ({ ...emptyDraft(), name: 'Orders', url: 'https://app.example.com/mcp', ...overrides });

test('a stored header comes back with an empty value and its masked hint', () => {
  const draft = draftFrom(stored);

  assert.deepEqual(draft.headers, [{ name: 'Authorization', value: '', hint: '••••0001', stored: true }]);
  assert.equal(draft.id, 7);
  assert.equal(draft.enabled, true);
});

test('a stored header left blank is sent blank, which keeps its value', () => {
  const body = requestBody(draftFrom(stored));

  assert.deepEqual(body.mcp_server_config.headers, [{ name: 'Authorization', value: '' }]);
  assert.equal(hasErrors(validateDraft(draftFrom(stored))), false);
});

test('a new header needs a value, and an empty header row is dropped', () => {
  let draft = addHeader(draftWith({}));
  draft = updateHeader(draft, 0, 'name', 'X-Api-Key');
  assert.match(validateDraft(draft).headers, /X-Api-Key needs a value/);

  draft = updateHeader(draft, 0, 'value', 'secret');
  draft = addHeader(draft);
  assert.equal(hasErrors(validateDraft(draft)), false);
  assert.deepEqual(requestBody(draft).mcp_server_config.headers, [{ name: 'X-Api-Key', value: 'secret' }]);
});

test('renaming a stored header makes it new, so it needs a value of its own', () => {
  const draft = updateHeader(draftFrom(stored), 0, 'name', 'X-Token');

  assert.equal(draft.headers[0].stored, false);
  assert.equal(draft.headers[0].hint, '');
  assert.match(validateDraft(draft).headers, /X-Token needs a value/);
  // A change of case is the same header.
  assert.equal(updateHeader(draftFrom(stored), 0, 'name', 'authorization').headers[0].stored, true);
});

test('removing a header drops it from the request, which deletes it', () => {
  const draft = removeHeader(draftFrom(stored), 0);

  assert.deepEqual(requestBody(draft).mcp_server_config.headers, []);
});

test('the URL must be http or https and carry no credentials', () => {
  assert.equal(validateDraft(draftWith({ url: '' })).url, 'Enter the server’s URL.');
  assert.match(validateDraft(draftWith({ url: 'ftp://app.example.com' })).url, /http/);
  assert.match(validateDraft(draftWith({ url: 'not a url' })).url, /http/);
  assert.match(validateDraft(draftWith({ url: 'https://me:pw@app.example.com/mcp' })).url, /header/);
  assert.equal(validateDraft(draftWith({})).url, undefined);
  assert.equal(validateDraft(draftWith({ name: ' ' })).name, 'Name the server.');
});

test('reserved, duplicate and malformed header names are refused', () => {
  const header = (name) => ({ name, value: 'v', hint: '', stored: false });

  assert.match(validateDraft(draftWith({ headers: [header('Content-Type')] })).headers, /set by the MCP client/);
  assert.match(validateDraft(draftWith({ headers: [header('X-A'), header('x-a')] })).headers, /listed twice/);
  assert.match(validateDraft(draftWith({ headers: [header('Bad Name')] })).headers, /not a valid header name/);
  assert.match(
    validateDraft(draftWith({ headers: [{ name: 'X-A', value: 'a\nb', hint: '', stored: false }] })).headers,
    /line breaks/,
  );
});

test('the request body trims fields and keeps the enabled switch', () => {
  const body = requestBody(draftWith({ name: '  Orders ', url: ' https://app.example.com/mcp ', enabled: false }));

  assert.deepEqual(body, {
    mcp_server_config: {
      name: 'Orders', description: '', url: 'https://app.example.com/mcp', enabled: false, headers: [],
    },
  });
});

test('a test result reads as not tested, connected with its tool count, or failed', () => {
  assert.equal(testStatus({ ...stored, last_tested_at: null }).label, 'Not tested');
  assert.equal(testStatus(stored).label, 'Connected · 1 tool');
  assert.equal(testStatus({ ...stored, tools: ['a', 'b'] }).label, 'Connected · 2 tools');

  const failed = testStatus({ ...stored, last_test_status: 'failed', last_test_error: 'HTTP 401' });
  assert.equal(failed.label, 'Failed');
  assert.equal(failed.tone, 'error');
  assert.equal(failed.title, 'HTTP 401');
});

test('an API error reads as one line', () => {
  assert.equal(errorText({ error: ['Url must not point at localhost', 'Name can\'t be blank'] }),
    'Url must not point at localhost Name can\'t be blank');
  assert.equal(errorText({ error: 'Record not found' }), 'Record not found');
  assert.equal(errorText(null, 'Could not save'), 'Could not save');
});

test('a custom server is recognised by its flag or its key, and a removed one is not undocumented', () => {
  assert.equal(isCustomServer({ key: 'custom:7' }), true);
  assert.equal(isCustomServer({ key: 'orders', custom: true }), true);
  assert.equal(isCustomServer({ key: 'playwright' }), false);
  assert.equal(isCustomServer({ key: 'sandbox:abc' }), false);

  const removed = { key: 'custom:9', known: false, tools: [] };
  assert.equal(isUndocumented(removed), false);
  assert.equal(isRemovedCustomServer(removed), true);
  assert.match(emptyToolsHint(removed), /removed from MCP Services/);

  const untested = { key: 'custom:7', custom: true, known: true, tools: [] };
  assert.equal(isRemovedCustomServer(untested), false);
  assert.match(emptyToolsHint(untested), /test this server/);
  assert.equal(isUndocumented({ key: 'booking', known: false }), true);
});
