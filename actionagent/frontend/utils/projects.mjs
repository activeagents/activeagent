// Pure helpers for the Projects views: secret names and warnings (the same
// rules as ActionAgent::ProjectSecret), the repository picker's state, boot
// steps, and project paths.

export const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
// Names the sandbox sets itself, or that change how Ruby, Bundler, Node or
// git load code (SandboxBootSpec::REFUSED_SECRET_NAME).
export const REFUSED_SECRET_NAME = /^(?:PORT|DATABASE_URL|RUBYOPT|RUBYLIB|LD_PRELOAD|PATH|NODE_OPTIONS)$|_DATABASE_URL$|^ACTION_AGENT_SANDBOX_|^DYLD_|^BUNDLE_|^GIT_/;
// The variables "Use the organization's key" is offered for.
export const ORGANIZATION_KEY_PROVIDERS = {
  OPENAI_API_KEY: 'openai',
  ANTHROPIC_API_KEY: 'anthropic',
  OPENROUTER_API_KEY: 'openrouter',
};
export const LIVE_PREFIXES = ['sk_live_', 'rk_live_'];
// Shorter values are not masked in logs (SecretScrubber::MIN_SECRET_LENGTH).
export const MIN_MASKED_LENGTH = 8;
export const BOOT_POLL_INTERVAL_MS = 2000;

// Returns why `name` cannot be a project secret, or null when it can.
export function secretNameProblem(name) {
  if (!name) return 'Name the variable.';
  if (!ENV_NAME.test(name)) return 'Use letters, digits and _ only, not starting with a digit.';
  if (REFUSED_SECRET_NAME.test(name)) return `${name} is set by the sandbox or changes how code is loaded, so a project cannot set it.`;
  return null;
}

// Returns what the secrets form warns about for `name` set to `value`, as
// [{ code, message }]. A warning never stops a save.
export function secretWarnings(name, value) {
  const warnings = [];
  const text = typeof value === 'string' ? value : '';
  if (LIVE_PREFIXES.some((prefix) => text.startsWith(prefix))) {
    warnings.push({ code: 'live_credential', message: 'This looks like a live-mode key. A sandbox runs the repository\'s code with it: use a test-mode key.' });
  }
  if (text.length > 0 && text.length < MIN_MASKED_LENGTH) {
    warnings.push({ code: 'short_value', message: `Values under ${MIN_MASKED_LENGTH} characters cannot be masked in logs.` });
  }
  if (name === 'RAILS_MASTER_KEY') {
    warnings.push({ code: 'rails_master_key', message: 'Prefer the key of development or test credentials over production\'s.' });
  }
  return warnings;
}

// Builds the secrets form's rows from what discovery found, in its order,
// each marked `set` when the project already has it. A row is
//   { name, required, sources, description, organizationKey, set, value, useOrganizationKey, consent }
export function secretRows(variables = [], existing = []) {
  const set = new Set(existing.map((secret) => secret.name));
  return variables.map((variable) => ({
    name: variable.name,
    required: Boolean(variable.required),
    sources: variable.sources || [],
    description: variable.description || null,
    organizationKey: variable.organization_key || ORGANIZATION_KEY_PROVIDERS[variable.name] || null,
    set: set.has(variable.name) || Boolean(variable.set),
    value: '',
    useOrganizationKey: false,
    consent: false,
  }));
}

// The secrets a form submits: rows with a value, or using the organization's
// key. Rows left empty are skipped.
export function secretsPayload(rows) {
  return rows.flatMap((row) => {
    if (row.useOrganizationKey) return [{ name: row.name, source: 'organization_key', consent: row.consent === true }];
    if (row.value) return [{ name: row.name, value: row.value }];
    return [];
  });
}

// Returns why the form cannot be submitted, or null: a refused name, or an
// organization key without consent.
export function secretsFormProblem(rows) {
  for (const row of rows) {
    const problem = secretNameProblem(row.name);
    if (problem && (row.value || row.useOrganizationKey)) return problem;
    if (row.useOrganizationKey && !row.consent) {
      return `Confirm that ${row.name}'s organization key may be read by the repository's code.`;
    }
  }
  return null;
}

// The picker's state, from what the dashboard knows about GitHub:
//   loading            nothing known yet
//   not_configured     no GitHub app on this dashboard
//   not_connected      the owner has not connected GitHub
//   reconnect_required GitHub rejected the stored token
//   pending_approval   an App installation waits for an owner's approval
//   empty              connected, reaching no repositories
//   ready              repositories to choose from
export function repoPickerState({ github, repositories, reconnectRequired = false, pendingApproval = false } = {}) {
  if (!github) return 'loading';
  if (github.mode === 'none') return 'not_configured';
  if (!github.connected) return 'not_connected';
  if (reconnectRequired) return 'reconnect_required';
  if (pendingApproval) return 'pending_approval';
  if (repositories == null) return 'loading';
  return repositories.length === 0 ? 'empty' : 'ready';
}

// Returns whether `value` names a repository as owner/name.
export function isRepositoryName(value) {
  return /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(value || '');
}

// The capabilities checklist's blocking items that fail.
export function blockingFailures(capabilities) {
  return (capabilities?.items || []).filter((item) => item.blocking && !item.ok);
}

// Returns why a project cannot be created yet, or null when it can.
export function createProblem({ capabilities, preflight, secretsProblem } = {}) {
  if (!capabilities) return 'Checking what this dashboard can do…';
  const failures = blockingFailures(capabilities);
  if (failures.length > 0) return `Fix first: ${failures.map((item) => item.label).join(', ')}.`;
  if (!preflight) return 'Pick a repository.';
  if (preflight.status === 'unsupported') return preflight.summary;
  return secretsProblem || null;
}

export const PREFLIGHT_TONES = { supported: 'success', bootstrap: 'info', unsupported: 'error' };

// The group a boot step belongs to, as the boot progress view names it.
export function bootStepGroup(name) {
  if (name === 'checkout') return 'Checkout';
  if (name === 'preflight') return 'Preflight';
  if (name === 'setup') return 'Setup';
  if (/^bundle_/.test(name)) return 'Bundle';
  if (/^(add|install)_/.test(name)) return 'Install';
  if (/_build$/.test(name)) return 'Assets';
  if (name === 'db_prepare') return 'Database';
  if (name === 'manifest') return 'Manifest';
  if (name === 'start' || name === 'server') return 'Start and start URL';
  return 'Step';
}

// "850ms", "12.4s", "3m 05s".
export function formatElapsed(ms) {
  if (ms == null || Number.isNaN(Number(ms))) return '—';
  const value = Number(ms);
  if (value < 1000) return `${Math.round(value)}ms`;
  if (value < 60000) return `${(value / 1000).toFixed(1)}s`;
  const minutes = Math.floor(value / 60000);
  const seconds = Math.round((value % 60000) / 1000);
  return `${minutes}m ${String(seconds).padStart(2, '0')}s`;
}

export const STEP_TONES = { succeeded: 'success', failed: 'error', running: 'info', skipped: 'muted', pending: 'muted' };

// Whether the project's sandbox is still booting, so its boot is polled.
export function isBooting(project) {
  return project?.sandbox_state === 'booting';
}

// The mount-relative path of a project page, or of the New Project page.
export function projectPath(id) {
  return id == null ? '/projects/new' : `/projects/${id}`;
}

// What a mount-relative path under /projects opens:
// { projectId } for a project, { creating: true } for /projects/new, {} for the list.
export function parseProjectPath(path = '') {
  if (/^\/projects\/new\/?$/.test(path)) return { creating: true };
  const match = path.match(/^\/projects\/(\d+)/);
  return match ? { projectId: match[1] } : {};
}
