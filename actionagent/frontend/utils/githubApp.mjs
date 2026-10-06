// Pure helpers for the GitHub App half of Settings -> Integrations.

// What the installation and manifest callbacks report back through
// ?github_app=… on their redirects.
export const GITHUB_APP_CALLBACK_MESSAGES = {
  linked: { tone: 'success', text: 'GitHub App installation linked. Choose the repositories this workspace may use on it.' },
  pending: { tone: 'success', text: 'Installation requested. Once an owner of the organization approves it on GitHub, that owner has to link it from this page.' },
  denied: { tone: 'error', text: 'GitHub authorization was cancelled.' },
  invalid_state: { tone: 'error', text: 'That GitHub App return expired or was not started here. Try again from this page.' },
  missing_code: { tone: 'error', text: 'GitHub did not return an authorization code. Try again.' },
  missing_installation: { tone: 'error', text: 'GitHub did not say which installation to link. Try installing again.' },
  not_found: { tone: 'error', text: 'Your GitHub account cannot reach that installation, so it was not linked.' },
  not_admin: { tone: 'error', text: 'Only the account the App is installed on, or an admin of its organization, can link an installation.' },
  taken: { tone: 'error', text: 'That installation is already linked to another workspace.' },
  not_configured: { tone: 'error', text: 'No GitHub App is configured on this dashboard.' },
  forbidden: { tone: 'error', text: 'You do not have permission to change the GitHub App.' },
  manifest_error: { tone: 'error', text: 'GitHub did not finish creating the App. Try again.' },
  manifest_unavailable: { tone: 'error', text: 'Creating a GitHub App is not available on this dashboard.' },
  error: { tone: 'error', text: 'Could not finish linking the GitHub App. Try again.' },
};

// How an installation reads in a list: "@acme · organization".
export function installationLabel(installation) {
  const type = installation.account_type === 'Organization' ? 'organization' : 'user';
  return `@${installation.account_login} · ${type}`;
}

// Returns { label, tone } for an installation GitHub no longer serves, or
// null for an active one.
export function installationProblem(installation) {
  if (installation.status === 'removed') return { label: 'Removed from GitHub: reinstall or unlink', tone: 'error' };
  if (installation.status === 'suspended') return { label: 'Suspended on GitHub', tone: 'warning' };
  return null;
}

// How the card header counts installations, and how many of them GitHub
// still serves: { text: '2 GitHub App installations (1 needs attention)',
// active: 1 }. text is null when nothing is linked.
export function installationsSummary(installations) {
  const list = installations || [];
  if (list.length === 0) return { text: null, active: 0 };
  const attention = list.filter((installation) => installationProblem(installation)).length;
  const noun = list.length === 1 ? 'GitHub App installation' : 'GitHub App installations';
  const suffix = attention > 0 ? ` (${attention} ${attention === 1 ? 'needs' : 'need'} attention)` : '';
  return { text: `${list.length} ${noun}${suffix}`, active: list.length - attention };
}

// The repositories sandboxes can check out, each with how: { ...repository,
// source: 'app' | 'oauth', installation }. A repository selected both ways
// is listed once, through its installation, as the engine checks it out.
// Installations GitHub no longer serves contribute nothing.
export function checkoutRepositories(connection, installations) {
  const listed = new Map();
  (installations || []).forEach((installation) => {
    if (installationProblem(installation)) return;
    (installation.repositories || []).forEach((repository) => {
      const key = repository.full_name.toLowerCase();
      if (!listed.has(key)) listed.set(key, { ...repository, source: 'app', installation });
    });
  });
  (connection?.repositories || []).forEach((repository) => {
    const key = repository.full_name.toLowerCase();
    if (!listed.has(key)) listed.set(key, { ...repository, source: 'oauth', installation: null });
  });
  return [...listed.values()];
}

// How a row from checkoutRepositories is cloned: "GitHub App (@acme)" or
// "OAuth".
export function checkoutSourceLabel(repository) {
  if (repository.source === 'app') return `GitHub App (@${repository.installation.account_login})`;
  return 'OAuth';
}

// GitHub's own rule for a user or organization login.
export function validGithubLogin(login) {
  return /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/.test(login);
}

// Posts the App manifest to GitHub as the form field GitHub reads, from a
// form built in +doc+. GitHub only accepts the manifest as a form post.
export function submitManifest(doc, url, manifest) {
  const form = doc.createElement('form');
  form.method = 'post';
  form.action = url;
  form.style.display = 'none';
  const field = doc.createElement('input');
  field.type = 'hidden';
  field.name = 'manifest';
  field.value = JSON.stringify(manifest);
  form.appendChild(field);
  doc.body.appendChild(form);
  form.submit();
  return form;
}
