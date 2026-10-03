import assert from 'node:assert/strict';
import test from 'node:test';
import { JSDOM } from 'jsdom';

import {
  GITHUB_APP_CALLBACK_MESSAGES,
  checkoutRepositories,
  checkoutSourceLabel,
  installationLabel,
  installationProblem,
  submitManifest,
  validGithubLogin,
} from '../utils/githubApp.mjs';

const repo = (full_name, extra = {}) => ({ id: full_name.length, full_name, private: true, default_branch: 'main', ...extra });
const installation = (overrides = {}) => ({
  id: 1, account_login: 'acme', account_type: 'Organization', status: 'active', repositories: [], ...overrides,
});

const listed = (rows) => rows.map((row) => [row.full_name, row.source]);

test('a repository selected on an installation is listed through it, ahead of the OAuth connection', () => {
  const connection = { repositories: [repo('acme/shop'), repo('acme/docs')] };
  const rows = checkoutRepositories(connection, [installation({ repositories: [repo('ACME/Shop')] })]);

  assert.deepEqual(listed(rows), [['ACME/Shop', 'app'], ['acme/docs', 'oauth']]);
  assert.equal(rows[0].installation.account_login, 'acme');
  assert.equal(rows[1].installation, null);
});

test('each listed repository names the path that clones it', () => {
  const rows = checkoutRepositories({ repositories: [repo('acme/docs')] }, [installation({ repositories: [repo('acme/shop')] })]);

  assert.deepEqual(rows.map(checkoutSourceLabel), ['GitHub App (@acme)', 'OAuth']);
});

test('installations GitHub no longer serves contribute no repositories', () => {
  const rows = checkoutRepositories({ repositories: [repo('acme/shop')] }, [
    installation({ id: 1, status: 'removed', repositories: [repo('acme/shop')] }),
    installation({ id: 2, status: 'suspended', repositories: [repo('acme/web')] }),
  ]);

  assert.deepEqual(listed(rows), [['acme/shop', 'oauth']]);
});

test('several installations list each repository once, and nothing connected lists nothing', () => {
  const rows = checkoutRepositories(null, [
    installation({ id: 1, account_login: 'octocat', account_type: 'User', repositories: [repo('octocat/site')] }),
    installation({ id: 2, repositories: [repo('acme/shop'), repo('octocat/site')] }),
  ]);

  assert.deepEqual(listed(rows), [['octocat/site', 'app'], ['acme/shop', 'app']]);
  assert.equal(rows[0].installation.id, 1);
  assert.deepEqual(checkoutRepositories(undefined, undefined), []);
});

test('an installation reads as its account and kind, and says when GitHub stopped serving it', () => {
  assert.equal(installationLabel(installation()), '@acme · organization');
  assert.equal(installationLabel(installation({ account_login: 'octocat', account_type: 'User' })), '@octocat · user');

  assert.equal(installationProblem(installation()), null);
  assert.equal(installationProblem(installation({ status: 'removed' })).tone, 'error');
  assert.equal(installationProblem(installation({ status: 'suspended' })).tone, 'warning');
});

test('every outcome the callbacks report has a message', () => {
  const outcomes = [
    'linked', 'pending', 'denied', 'invalid_state', 'missing_code', 'missing_installation', 'not_found', 'not_admin',
    'taken', 'not_configured', 'forbidden', 'manifest_error', 'manifest_unavailable', 'error',
  ];
  outcomes.forEach((outcome) => assert.ok(GITHUB_APP_CALLBACK_MESSAGES[outcome]?.text, outcome));
  assert.equal(GITHUB_APP_CALLBACK_MESSAGES.linked.tone, 'success');
  assert.equal(GITHUB_APP_CALLBACK_MESSAGES.not_admin.tone, 'error');
});

test('organization logins follow GitHub\'s rule', () => {
  ['acme', 'acme-labs', 'A1', 'a'.repeat(39)].forEach((login) => assert.ok(validGithubLogin(login), login));
  ['', '-acme', '../acme', 'acme labs', 'a'.repeat(40), 'acme/x'].forEach((login) => assert.ok(!validGithubLogin(login), login));
});

test('the manifest is posted to GitHub as one hidden form field', () => {
  const { window } = new JSDOM('<!doctype html><body></body>');
  const submitted = [];
  window.HTMLFormElement.prototype.submit = function submit() { submitted.push(this); };
  const manifest = { name: 'ActiveAgent example.com', default_permissions: { contents: 'write' } };

  const form = submitManifest(window.document, 'https://github.com/settings/apps/new?state=abc', manifest);

  assert.deepEqual(submitted, [form]);
  assert.equal(form.method, 'post');
  assert.equal(form.action, 'https://github.com/settings/apps/new?state=abc');
  const fields = [...form.querySelectorAll('input')];
  assert.deepEqual(fields.map((field) => [field.type, field.name]), [['hidden', 'manifest']]);
  assert.deepEqual(JSON.parse(fields[0].value), manifest);
});
