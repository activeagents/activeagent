import React, { useState } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { dashboardPath } from '../../utils/dashboardPath';
import RepoPicker from './RepoPicker';
import { toggleRepository } from '../../utils/repositories.mjs';
import { installationLabel, installationProblem, submitManifest, validGithubLogin } from '../../utils/githubApp.mjs';

// The GitHub App half of the GitHub card: installing the App and the owner's
// linked installations, each with its repository selection and Unlink. On a
// dashboard with no App configured it offers to create one from a manifest
// instead, where the engine allows that (single-tenant installs).
//
// app: the `app` object GET /api/github_connection returns.
// onChanged(): called after an installation's selection or link changed.
// onError(message), onNotice({ tone, text }): report to the card.
export default function GithubAppSection({ app, onChanged, onError, onNotice }) {
  const { darkMode } = useTheme();
  const [editing, setEditing] = useState(null); // installation id whose repositories are being chosen
  const [available, setAvailable] = useState(null);
  const [selection, setSelection] = useState(new Set());
  const [filter, setFilter] = useState('');
  const [saving, setSaving] = useState(false);
  const [organization, setOrganization] = useState('');
  const [creating, setCreating] = useState(false);

  if (!app || (!app.configured && !app.manifest_available)) return null;

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const rowStyle = { backgroundColor: darkMode ? '#252525' : '#f9fafb' };
  const secondaryButton = `px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`;
  const dangerButton = `px-3 py-1 text-sm rounded ${darkMode ? 'text-red-300 hover:bg-red-900/40' : 'text-red-600 hover:bg-red-50'}`;
  const toneText = {
    error: darkMode ? 'text-red-400' : 'text-red-600',
    warning: darkMode ? 'text-amber-300' : 'text-amber-700',
  };

  const chooseRepositories = async (installation) => {
    onError(null);
    try {
      const res = await fetch(`/api/github_installations/${installation.id}/repositories`);
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        if (data.reinstall_required) onChanged();
        throw new Error(data.error || 'Could not list the installation\'s repositories.');
      }
      setAvailable(data.repositories || []);
      setSelection(new Set((installation.repositories || []).map((repository) => repository.full_name)));
      setFilter('');
      setEditing(installation.id);
    } catch (e) {
      onError(e.message);
    }
  };

  const cancelEditing = () => {
    setEditing(null);
    setAvailable(null);
  };

  const saveSelection = async () => {
    setSaving(true);
    onError(null);
    try {
      const res = await fetch(`/api/github_installations/${editing}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ repositories: [...selection] }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Could not save the selection.');
      cancelEditing();
      onNotice({ tone: 'success', text: 'Repository selection saved.' });
      onChanged();
    } catch (e) {
      onError(e.message);
    } finally {
      setSaving(false);
    }
  };

  const unlink = async (installation) => {
    if (!window.confirm(
      `Unlink the GitHub App installation on @${installation.account_login}? New sandboxes can no longer check out its `
      + 'repositories. The App stays installed on GitHub; uninstall it there to remove its access.',
    )) return;
    onError(null);
    try {
      const res = await fetch(`/api/github_installations/${installation.id}`, { method: 'DELETE' });
      if (!res.ok && res.status !== 404) throw new Error('Could not unlink the installation.');
      if (editing === installation.id) cancelEditing();
      onChanged();
    } catch (e) {
      onError(e.message);
    }
  };

  // GitHub accepts a manifest only as a form post from the browser, so the
  // dashboard asks for the URL and manifest, then submits a form there.
  const createApp = async () => {
    const login = organization.trim();
    if (login && !validGithubLogin(login)) {
      onError('Enter the organization\'s GitHub login, or leave it empty to create the App under your account.');
      return;
    }
    setCreating(true);
    onError(null);
    try {
      const res = await fetch('/api/github_app_manifest', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(login ? { organization: login } : {}),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Could not start creating the GitHub App.');
      submitManifest(document, data.url, data.manifest);
    } catch (e) {
      onError(e.message);
      setCreating(false);
    }
  };

  if (!app.configured) {
    return (
      <div className="p-3 rounded-lg space-y-2" style={rowStyle}>
        <p className={`text-sm font-medium ${strong}`}>Use a GitHub App</p>
        <p className={`text-xs ${muted}`}>
          A GitHub App gives each checkout a one-hour token limited to its one repository. Create one for this
          dashboard: GitHub registers it, and this page shows its settings once to add to your configuration.
        </p>
        <div className="flex items-center gap-2">
          <input
            type="text"
            value={organization}
            onChange={(e) => setOrganization(e.target.value)}
            placeholder="Organization (optional)"
            className={`flex-1 px-3 py-1 border rounded text-sm ${darkMode ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500' : 'bg-white border-gray-300 text-gray-900'}`}
          />
          <button type="button" onClick={createApp} disabled={creating} className={`${secondaryButton} disabled:opacity-50`}>
            {creating ? 'Opening GitHub…' : 'Create GitHub App'}
          </button>
        </div>
      </div>
    );
  }

  const installations = app.installations || [];

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <p className={`text-sm font-medium ${strong}`}>GitHub App</p>
          <p className={`text-xs ${muted}`}>
            Each checkout gets a one-hour token limited to its repository. When a repository is reachable both ways,
            the App is used.
          </p>
        </div>
        <a href={dashboardPath('/api/github_installations/install')} className="shrink-0 px-3 py-1 text-sm bg-red-500 text-white rounded hover:bg-red-600">
          Install the GitHub App
        </a>
      </div>

      {installations.length === 0 && (
        <p className={`text-sm ${muted}`}>No installation is linked yet. Install the App on the repositories this workspace should use.</p>
      )}

      {installations.map((installation) => {
        const problem = installationProblem(installation);
        const repositories = installation.repositories || [];
        return (
          <div key={installation.id} className="p-3 rounded-lg space-y-2" style={rowStyle}>
            <div className="flex items-center justify-between gap-3">
              <div className="min-w-0">
                <p className={`text-sm font-mono ${strong}`}>{installationLabel(installation)}</p>
                <p className={`text-xs ${problem ? toneText[problem.tone] : muted}`}>
                  {problem ? problem.label : `${repositories.length} selected for sandboxes`}
                </p>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                {editing === installation.id ? (
                  <>
                    <button type="button" onClick={cancelEditing} className={secondaryButton}>Cancel</button>
                    <button type="button" onClick={saveSelection} disabled={saving} className="px-3 py-1 text-sm bg-red-500 text-white rounded hover:bg-red-600 disabled:opacity-50">
                      {saving ? 'Saving…' : `Save (${selection.size})`}
                    </button>
                  </>
                ) : (
                  <>
                    {!problem && (
                      <button type="button" onClick={() => chooseRepositories(installation)} className={secondaryButton}>Choose repositories</button>
                    )}
                    {installation.settings_url && (
                      <a href={installation.settings_url} target="_blank" rel="noreferrer" className={secondaryButton}>Access on GitHub</a>
                    )}
                    <button type="button" onClick={() => unlink(installation)} className={dangerButton}>Unlink</button>
                  </>
                )}
              </div>
            </div>
            {editing === installation.id && available && (
              <RepoPicker
                repositories={available}
                selection={selection}
                onToggle={(fullName) => setSelection((current) => toggleRepository(current, fullName))}
                filter={filter}
                onFilterChange={setFilter}
              />
            )}
          </div>
        );
      })}
    </div>
  );
}
