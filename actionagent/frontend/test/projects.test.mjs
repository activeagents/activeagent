import assert from 'node:assert/strict';
import test from 'node:test';

import {
  blockingFailures,
  bootStepGroup,
  createProblem,
  formatElapsed,
  isRepositoryName,
  parseProjectPath,
  projectNameAfterPick,
  projectPath,
  repoPickerState,
  secretNameProblem,
  secretRows,
  secretWarnings,
  secretsFormProblem,
  secretsPayload,
  withSecretRow,
} from '../utils/projects.mjs';

// The Projects views' rules, which mirror ActionAgent::ProjectSecret and the
// projects API, so the form says before saving what the API would refuse.

test('names the sandbox sets, or that change how code loads, are refused', () => {
  for (const name of ['PATH', 'RUBYOPT', 'RUBYLIB', 'LD_PRELOAD', 'DYLD_INSERT_LIBRARIES', 'BUNDLE_GEMFILE', 'GIT_DIR', 'NODE_OPTIONS',
    'PORT', 'DATABASE_URL', 'QUEUE_DATABASE_URL', 'ACTION_AGENT_SANDBOX_TOKEN']) {
    assert.match(secretNameProblem(name), /set by the sandbox or changes how code is loaded/, name);
  }
  for (const name of ['STRIPE_SECRET_KEY', 'OPENAI_API_KEY', 'BUNDLER_VERSION', 'DATABASE_HOST', 'RAILS_MASTER_KEY']) {
    assert.equal(secretNameProblem(name), null, name);
  }
  assert.match(secretNameProblem('9LIVES'), /letters, digits and _/);
  assert.match(secretNameProblem(''), /Name the variable/);
});

test('live keys, values too short to mask and the master key are warned about before saving', () => {
  const codes = (name, value) => secretWarnings(name, value).map((warning) => warning.code);

  assert.deepEqual(codes('STRIPE_SECRET_KEY', 'sk_live_0123456789'), ['live_credential']);
  assert.deepEqual(codes('STRIPE_RESTRICTED_KEY', 'rk_live_0123456789'), ['live_credential']);
  assert.deepEqual(codes('STRIPE_SECRET_KEY', 'sk_test_0123456789'), []);
  assert.deepEqual(codes('PIN', '1234567'), ['short_value']);
  assert.deepEqual(codes('PIN', '12345678'), []);
  assert.deepEqual(codes('PIN', ''), []);
  assert.deepEqual(codes('RAILS_MASTER_KEY', '0123456789abcdef'), ['rails_master_key']);
  assert.deepEqual(codes('RAILS_MASTER_KEY', 'sk_live_x'), ['live_credential', 'rails_master_key']);
});

test('discovered variables become form rows, marked when the project has them set', () => {
  const rows = secretRows([
    { name: 'OPENAI_API_KEY', required: false, sources: ['.env.example:2'], organization_key: 'openai' },
    { name: 'STRIPE_SECRET_KEY', required: true, sources: ['config/initializers/stripe.rb:1'] },
  ], [{ name: 'STRIPE_SECRET_KEY' }]);

  assert.deepEqual(rows.map((row) => [row.name, row.required, row.set, row.organizationKey]), [
    ['OPENAI_API_KEY', false, false, 'openai'],
    ['STRIPE_SECRET_KEY', true, true, null],
  ]);
  assert.ok(rows.every((row) => row.value === '' && row.useOrganizationKey === false && row.consent === false));
});

test('the form submits values and organization keys, and skips empty rows', () => {
  const rows = [
    { name: 'A_KEY', value: 'value-a', useOrganizationKey: false, consent: false },
    { name: 'EMPTY', value: '', useOrganizationKey: false, consent: false },
    { name: 'OPENAI_API_KEY', value: '', useOrganizationKey: true, consent: true },
  ];

  assert.deepEqual(secretsPayload(rows), [
    { name: 'A_KEY', value: 'value-a' },
    { name: 'OPENAI_API_KEY', source: 'organization_key', consent: true },
  ]);
  assert.equal(secretsFormProblem(rows), null);
});

test("using the organization's key needs consent, and a refused name with a value stops the form", () => {
  assert.match(secretsFormProblem([{ name: 'OPENAI_API_KEY', value: '', useOrganizationKey: true, consent: false }]), /Confirm that OPENAI_API_KEY/);
  assert.match(secretsFormProblem([{ name: 'RUBYOPT', value: '-rx', useOrganizationKey: false }]), /RUBYOPT/);
  assert.equal(secretsFormProblem([{ name: 'RUBYOPT', value: '', useOrganizationKey: false }]), null, 'left empty, it is not submitted');
});

test('the repository picker state follows what is known about GitHub', () => {
  assert.equal(repoPickerState(), 'loading');
  assert.equal(repoPickerState({ github: { mode: 'none', connected: false } }), 'not_configured');
  assert.equal(repoPickerState({ github: { mode: 'oauth', connected: false } }), 'not_connected');
  assert.equal(repoPickerState({ github: { mode: 'oauth', connected: true }, reconnectRequired: true }), 'reconnect_required');
  assert.equal(repoPickerState({ github: { mode: 'app', connected: true }, pendingApproval: true, repositories: [] }), 'pending_approval');
  assert.equal(repoPickerState({ github: { mode: 'oauth', connected: true } }), 'loading');
  assert.equal(repoPickerState({ github: { mode: 'oauth', connected: true }, repositories: [] }), 'empty');
  assert.equal(repoPickerState({ github: { mode: 'oauth', connected: true }, repositories: [{ full_name: 'acme/shop' }] }), 'ready');
});

test('a typed repository name is owner/name', () => {
  assert.ok(isRepositoryName('acme/shop'));
  assert.ok(isRepositoryName('acme-co/shop.web_2'));
  assert.ok(!isRepositoryName('acme'));
  assert.ok(!isRepositoryName('acme/shop/extra'));
  assert.ok(!isRepositoryName('acme /shop'));
  assert.ok(!isRepositoryName(''));
});

test('creating waits on the capabilities, a supported repository and a valid form', () => {
  const ready = { ready: true, items: [{ key: 'github', label: 'GitHub', ok: true, blocking: true }, { key: 'browser', label: 'Browser', ok: false, blocking: false }] };
  const blocked = { ready: false, items: [{ key: 'sandbox_backend', label: 'Sandbox backend', ok: false, blocking: true }] };

  assert.deepEqual(blockingFailures(blocked).map((item) => item.key), ['sandbox_backend']);
  assert.deepEqual(blockingFailures(ready), []);
  assert.match(createProblem({}), /Checking/);
  assert.equal(createProblem({ capabilities: blocked, preflight: { status: 'supported' } }), 'Fix first: Sandbox backend.');
  assert.equal(createProblem({ capabilities: ready }), 'Pick a repository.');
  assert.equal(createProblem({ capabilities: ready, preflight: { status: 'unsupported', summary: 'acme/shop locks railties 7.1.3' } }), 'acme/shop locks railties 7.1.3');
  assert.equal(createProblem({ capabilities: ready, preflight: { status: 'bootstrap' }, secretsProblem: 'Confirm it' }), 'Confirm it');
  assert.equal(createProblem({ capabilities: ready, preflight: { status: 'bootstrap' } }), null);
});

test('boot steps are grouped the way the boot progress view names them', () => {
  const groups = Object.fromEntries(['checkout', 'preflight', 'setup', 'bundle_config', 'bundle_install', 'add_framework', 'add_engine',
    'install_framework', 'install_engine', 'javascript_build', 'css_build', 'tailwindcss_build', 'db_prepare', 'manifest', 'start', 'server',
    'custom_step'].map((name) => [name, bootStepGroup(name)]));

  assert.deepEqual(groups, {
    checkout: 'Checkout', preflight: 'Preflight', setup: 'Setup', bundle_config: 'Bundle', bundle_install: 'Bundle',
    add_framework: 'Install', add_engine: 'Install', install_framework: 'Install', install_engine: 'Install',
    javascript_build: 'Assets', css_build: 'Assets', tailwindcss_build: 'Assets', db_prepare: 'Database', manifest: 'Manifest',
    start: 'Start and start URL', server: 'Start and start URL', custom_step: 'Step',
  });
});

test('elapsed times read as ms, seconds, then minutes', () => {
  assert.equal(formatElapsed(null), '—');
  assert.equal(formatElapsed(850), '850ms');
  assert.equal(formatElapsed(12_400), '12.4s');
  assert.equal(formatElapsed(185_000), '3m 05s');
});

test('project paths round-trip', () => {
  assert.equal(projectPath(7), '/projects/7');
  assert.equal(projectPath(null), '/projects/new');
  assert.deepEqual(parseProjectPath('/projects/7'), { projectId: '7' });
  assert.deepEqual(parseProjectPath('/projects/7/environment'), { projectId: '7' });
  assert.deepEqual(parseProjectPath('/projects/new'), { creating: true });
  assert.deepEqual(parseProjectPath('/projects'), {});
  assert.deepEqual(parseProjectPath('/projects/abc'), {});
});

test("a variable added by hand offers the organization's key when it names a provider key", () => {
  const rows = withSecretRow(withSecretRow([], 'OPENAI_API_KEY'), 'MAILER_PASSWORD');

  assert.deepEqual(rows.map((row) => [row.name, row.organizationKey, row.required, row.set, row.value]), [
    ['OPENAI_API_KEY', 'openai', false, false, ''],
    ['MAILER_PASSWORD', null, false, false, ''],
  ]);
});

test("the project's name follows each picked repository until the user types one", () => {
  let name = projectNameAfterPick({ name: '', edited: false, fullName: 'acme/a' });
  assert.equal(name, 'acme/a');
  name = projectNameAfterPick({ name, edited: false, fullName: 'acme/b' });
  assert.equal(name, 'acme/b', 're-picking renames a project the user did not name');
  assert.equal(projectNameAfterPick({ name: 'Storefront', edited: true, fullName: 'acme/c' }), 'Storefront');
});
