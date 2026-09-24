import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { dashboardPath } from '../../utils/dashboardPath';

// What the OAuth callback reports back through ?github=… on its redirect.
const CALLBACK_MESSAGES = {
  connected: { tone: 'success', text: 'GitHub connected. Choose the repositories this workspace may use.' },
  denied: { tone: 'error', text: 'GitHub authorization was cancelled.' },
  invalid_state: { tone: 'error', text: 'That GitHub sign-in expired or was not started here. Try connecting again.' },
  missing_code: { tone: 'error', text: 'GitHub did not return an authorization code. Try connecting again.' },
  not_configured: { tone: 'error', text: 'GitHub OAuth is not configured on this dashboard.' },
  error: { tone: 'error', text: 'Could not finish connecting GitHub. Try again.' },
};

// Settings -> Integrations: the owner's GitHub connection, the repositories
// it makes available, and checkout sandboxes booted from one of them.
export default function GithubIntegrationCard({ callbackStatus }) {
  const { darkMode } = useTheme();
  const [status, setStatus] = useState(null);
  const [available, setAvailable] = useState(null); // repositories the token reaches
  const [selection, setSelection] = useState(new Set());
  const [filter, setFilter] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(CALLBACK_MESSAGES[callbackStatus] || null);
  const [sandboxes, setSandboxes] = useState({}); // full_name -> sandbox summary
  const [launching, setLaunching] = useState(null);

  const loadStatus = useCallback(async () => {
    try {
      const res = await fetch('/api/github_connection');
      if (!res.ok) throw new Error('status failed');
      const data = await res.json();
      setStatus(data);
      setSelection(new Set((data.connection?.repositories || []).map((r) => r.full_name)));
    } catch (e) {
      setError('Could not load the GitHub connection. Are you signed in?');
    }
  }, []);

  useEffect(() => { loadStatus(); }, [loadStatus]);

  const loadRepositories = async () => {
    setError(null);
    try {
      const res = await fetch('/api/github_connection/repositories');
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Could not list repositories.');
      setAvailable(data.repositories || []);
    } catch (e) {
      setError(e.message);
    }
  };

  const toggle = (fullName) => {
    setSelection((current) => {
      const next = new Set(current);
      if (next.has(fullName)) next.delete(fullName); else next.add(fullName);
      return next;
    });
  };

  const saveSelection = async () => {
    setSaving(true);
    setError(null);
    try {
      const res = await fetch('/api/github_connection', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ repositories: [...selection] }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'Could not save the selection.');
      setStatus((s) => ({ ...s, connection: data.connection }));
      setAvailable(null);
      setNotice({ tone: 'success', text: 'Repository selection saved.' });
    } catch (e) {
      setError(e.message);
    } finally {
      setSaving(false);
    }
  };

  const disconnect = async () => {
    if (!window.confirm('Disconnect GitHub? Checkout sandboxes will no longer be able to clone its repositories.')) return;
    try {
      const res = await fetch('/api/github_connection', { method: 'DELETE' });
      if (!res.ok) throw new Error('disconnect failed');
      setAvailable(null);
      setSandboxes({});
      setNotice(null);
      await loadStatus();
    } catch (e) {
      setError('Could not disconnect GitHub.');
    }
  };

  const launchSandbox = async (fullName) => {
    setLaunching(fullName);
    setError(null);
    try {
      const res = await fetch('/api/sandboxes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sandbox_type: 'app_runtime', repository: fullName }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error((data.errors || [data.error]).filter(Boolean).join(', ') || 'Could not start the sandbox.');
      setSandboxes((current) => ({ ...current, [fullName]: data.sandbox }));
    } catch (e) {
      setError(e.message);
    } finally {
      setLaunching(null);
    }
  };

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const rowStyle = { backgroundColor: darkMode ? '#252525' : '#f9fafb' };
  const secondaryButton = `px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`;
  const connection = status?.connection;
  const selected = connection?.repositories || [];
  const visible = (available || []).filter((r) => r.full_name.toLowerCase().includes(filter.toLowerCase()));

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center space-x-3">
          <span className="text-xl">🐙</span>
          <div>
            <p className={`font-medium ${strong}`}>GitHub</p>
            <p className={`text-sm ${status?.connected ? (darkMode ? 'text-green-400' : 'text-green-600') : muted}`}>
              {!status ? 'Loading…' : status.connected ? `Connected as @${connection.login}` : 'Not connected'}
            </p>
          </div>
        </div>
        {status?.connected ? (
          <button onClick={disconnect} className={`px-3 py-1 text-sm rounded ${darkMode ? 'text-red-300 hover:bg-red-900/40' : 'text-red-600 hover:bg-red-50'}`}>
            Disconnect
          </button>
        ) : status?.configured ? (
          <a href={dashboardPath('/api/github_connection/connect')} className="px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600 text-sm">
            Connect GitHub
          </a>
        ) : null}
      </div>

      {status && !status.configured && !status.connected && (
        <p className={`text-sm ${muted}`}>
          The operator has not configured a GitHub OAuth app. Set <code>ActionAgent.github_client_id</code> and{' '}
          <code>github_client_secret</code> (or <code>GITHUB_CLIENT_ID</code> / <code>GITHUB_CLIENT_SECRET</code>) and register{' '}
          <code>{dashboardPath('/api/github_connection/callback')}</code> as its callback URL.
        </p>
      )}

      {notice && (
        <div className={`p-3 rounded-lg text-sm border ${notice.tone === 'success'
          ? (darkMode ? 'bg-green-900/20 border-green-800 text-green-300' : 'bg-green-50 border-green-200 text-green-800')
          : (darkMode ? 'bg-red-900/20 border-red-800 text-red-300' : 'bg-red-50 border-red-200 text-red-700')}`}>
          {notice.text}
        </div>
      )}
      {error && (
        <div className={`p-3 rounded-lg text-sm border ${darkMode ? 'bg-red-900/20 border-red-800 text-red-300' : 'bg-red-50 border-red-200 text-red-700'}`}>
          {error}
        </div>
      )}

      {status?.connected && (
        <div className="space-y-3">
          <div className="flex items-center justify-between">
            <p className={`text-sm font-medium ${strong}`}>Available repositories</p>
            {available ? (
              <div className="flex items-center space-x-2">
                <button onClick={() => { setAvailable(null); setSelection(new Set(selected.map((r) => r.full_name))); }} className={secondaryButton}>Cancel</button>
                <button onClick={saveSelection} disabled={saving} className="px-3 py-1 text-sm bg-red-500 text-white rounded hover:bg-red-600 disabled:opacity-50">
                  {saving ? 'Saving…' : `Save (${selection.size})`}
                </button>
              </div>
            ) : (
              <button onClick={loadRepositories} className={secondaryButton}>Choose repositories</button>
            )}
          </div>

          {available ? (
            <div className="space-y-2">
              <input
                type="text"
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                placeholder="Filter repositories"
                className={`w-full px-3 py-2 border rounded-lg text-sm ${darkMode ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500' : 'bg-white border-gray-300 text-gray-900'}`}
              />
              <div className="max-h-80 overflow-y-auto space-y-1">
                {visible.map((repo) => (
                  <label key={repo.id} className="flex items-center space-x-3 p-2 rounded cursor-pointer" style={rowStyle}>
                    <input type="checkbox" checked={selection.has(repo.full_name)} onChange={() => toggle(repo.full_name)} />
                    <span className={`text-sm font-mono ${strong}`}>{repo.full_name}</span>
                    {repo.private && <span className={`text-xs ${muted}`}>private</span>}
                  </label>
                ))}
                {visible.length === 0 && <p className={`text-sm ${muted}`}>No repositories match.</p>}
              </div>
            </div>
          ) : selected.length === 0 ? (
            <p className={`text-sm ${muted}`}>No repositories selected yet. Selected repositories can be checked out into sandboxes.</p>
          ) : (
            <div className="space-y-2">
              {selected.map((repo) => {
                const sandbox = sandboxes[repo.full_name];
                return (
                  <div key={repo.full_name} className="p-3 rounded-lg" style={rowStyle}>
                    <div className="flex items-center justify-between">
                      <div>
                        <p className={`text-sm font-mono ${strong}`}>{repo.full_name}</p>
                        <p className={`text-xs ${muted}`}>{repo.private ? 'private' : 'public'} · {repo.default_branch}</p>
                      </div>
                      <button onClick={() => launchSandbox(repo.full_name)} disabled={launching === repo.full_name} className={`${secondaryButton} disabled:opacity-50`}>
                        {launching === repo.full_name ? 'Starting…' : 'Start sandbox'}
                      </button>
                    </div>
                    {sandbox && (
                      <p className={`mt-2 text-xs ${muted}`}>
                        Sandbox {sandbox.status} at {sandbox.repository_ref}.{' '}
                        {sandbox.runtime_server_key
                          ? <>Add <code className="font-mono">{sandbox.runtime_server_key}</code> to an agent's MCP servers to run it, or evaluate it, with this checkout's tools.</>
                          : 'Its runtime tools appear once the backend reports the app is up.'}
                      </p>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
