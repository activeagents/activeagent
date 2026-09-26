import React, { useState, useEffect, useCallback, useRef } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { dashboardPath } from '../../utils/dashboardPath';
import CodeSessionPanel, { StatusBadge } from './CodeSessionPanel';
import {
  SANDBOX_POLL_INTERVAL_MS,
  apiErrorMessage,
  fmtExpiry,
  groupSandboxes,
  isSandboxBooting,
  isSandboxReady,
  pollGivesUp,
  replaceBy,
  sandboxStatus,
  upsertBy,
  claudeCodeAuth,
} from '../../utils/codeSessions.mjs';

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
// it makes available, and checkout sandboxes booted from one of them — each
// listed under its repository, polled while it boots, and, once ready, able
// to run Claude Code sessions in its checkout. The sandboxes are listed
// whether or not GitHub is still connected: disconnecting stops nothing, so
// they stay here to be stopped.
// refreshKey changes when another Integrations card changed something the
// sandbox listing reports (the Claude Code connection).
export default function GithubIntegrationCard({ callbackStatus, refreshKey }) {
  const { darkMode } = useTheme();
  const [status, setStatus] = useState(null);
  const [available, setAvailable] = useState(null); // repositories the token reaches
  const [selection, setSelection] = useState(new Set());
  const [filter, setFilter] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(CALLBACK_MESSAGES[callbackStatus] || null);
  const [sandboxes, setSandboxes] = useState([]); // the caller's app_runtime sandbox summaries, newest first
  // What the configured backend and the owner's credentials allow:
  // { codeSessions, claudeCode }, from GET /api/sandboxes.
  const [sandboxSupport, setSandboxSupport] = useState(null);
  const [sandboxErrors, setSandboxErrors] = useState({}); // repository full_name -> message
  const [launching, setLaunching] = useState(null);
  const [stopping, setStopping] = useState(null); // session_id
  const [pollTick, setPollTick] = useState(0);
  // session_id -> { message, stopped } for a booting sandbox whose status
  // poll failed; stopped once pollGivesUp, until Retry.
  const [pollErrors, setPollErrors] = useState({});
  const pollFailures = useRef({}); // session_id -> failed polls in a row

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

  const loadSandboxes = useCallback(async () => {
    try {
      const res = await fetch('/api/sandboxes?sandbox_type=app_runtime');
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not list your sandboxes (HTTP ${res.status}).`));
      setSandboxes(data.sandboxes || []);
      setSandboxSupport({ codeSessions: Boolean(data.code_sessions_supported), claudeCode: claudeCodeAuth(data) });
    } catch (e) {
      setError(e.message);
    }
  }, []);

  // Listed once the connection's status is known (so a signed-out page
  // shows one error, not two), and again when it connects or disconnects.
  const statusLoaded = status !== null;
  const connected = Boolean(status?.connected);
  useEffect(() => { if (statusLoaded) loadSandboxes(); }, [statusLoaded, connected, loadSandboxes, refreshKey]);

  // Every sandbox still checking out and booting is polled every 2s until it
  // settles (ready, failed, expired). The loop stops when none is booting,
  // and on unmount. A failed poll leaves the sandbox as it was and says why;
  // it is tried again on the next tick until pollGivesUp (a 4xx, or
  // MAX_POLL_FAILURES in a row), and then only when Retry is clicked.
  const bootingIds = sandboxes
    .filter((sandbox) => isSandboxBooting(sandbox) && !pollErrors[sandbox.session_id]?.stopped)
    .map((sandbox) => sandbox.session_id)
    .join(' ');
  useEffect(() => {
    if (!bootingIds) return undefined;
    let cancelled = false;
    const timer = setTimeout(async () => {
      const results = await Promise.all(bootingIds.split(' ').map(async (id) => {
        try {
          const res = await fetch(`/api/sandboxes/${encodeURIComponent(id)}`);
          if (res.status === 404) return { id, gone: true };
          const data = await res.json().catch(() => ({}));
          if (!res.ok) {
            return { id, status: res.status, error: apiErrorMessage(data, `Could not check on this sandbox (HTTP ${res.status}).`) };
          }
          return { id, sandbox: data.sandbox || null };
        } catch (_error) {
          return { id, status: null, error: 'Could not reach the dashboard to check on this sandbox.' };
        }
      }));
      if (cancelled) return;
      const errors = {};
      results.forEach(({ id, status: httpStatus, error: message }) => {
        if (!message) {
          delete pollFailures.current[id];
          errors[id] = null;
          return;
        }
        const failures = (pollFailures.current[id] || 0) + 1;
        pollFailures.current[id] = failures;
        errors[id] = { message, stopped: pollGivesUp(httpStatus, failures) };
      });
      setPollErrors((current) => Object.entries(errors).reduce((acc, [id, entry]) => {
        if (entry) return { ...acc, [id]: entry };
        if (!(id in acc)) return acc;
        const { [id]: _cleared, ...rest } = acc;
        return rest;
      }, current));
      setSandboxes((list) => results.reduce((acc, result) => {
        if (result.gone) return acc.filter((sandbox) => sandbox.session_id !== result.id);
        return result.sandbox ? replaceBy(acc, result.sandbox, 'session_id') : acc;
      }, list));
      setPollTick((tick) => tick + 1);
    }, SANDBOX_POLL_INTERVAL_MS);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [bootingIds, pollTick]);

  // Forgets a sandbox's failed polls. For one whose poll had stopped, that is
  // Retry: it is booting and no longer stopped, so it rejoins the loop.
  const clearPollError = (id) => {
    delete pollFailures.current[id];
    setPollErrors((current) => {
      const { [id]: _cleared, ...rest } = current;
      return rest;
    });
  };

  const setSandboxError = (repository, message) => {
    setSandboxErrors((current) => ({ ...current, [repository]: message }));
  };

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

  // Only the connection goes: sandboxes already checked out keep running
  // until stopped or reaped, so they stay listed below with their Stop.
  const disconnect = async () => {
    if (!window.confirm(
      'Disconnect GitHub? New checkout sandboxes will no longer be able to clone its repositories. '
      + 'Sandboxes already running keep running until you stop them or they expire.',
    )) return;
    try {
      const res = await fetch('/api/github_connection', { method: 'DELETE' });
      if (!res.ok) throw new Error('disconnect failed');
      setAvailable(null);
      setNotice(null);
      await loadStatus();
    } catch (e) {
      setError('Could not disconnect GitHub.');
    }
  };

  // Created pending: the checkout and boot happen in a job, and the poll
  // above follows it until it is ready or has failed.
  const launchSandbox = async (fullName) => {
    setLaunching(fullName);
    setSandboxError(fullName, null);
    try {
      const res = await fetch('/api/sandboxes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sandbox_type: 'app_runtime', repository: fullName }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(apiErrorMessage(data, `Could not start the sandbox (HTTP ${res.status}).`));
      setSandboxes((list) => upsertBy(list, data.sandbox, 'session_id'));
    } catch (e) {
      setSandboxError(fullName, e.message);
    } finally {
      setLaunching(null);
    }
  };

  // Expires the sandbox; the cleanup job stops its processes and deletes
  // the checkout. A failed one has nothing running, so it is just dismissed.
  const stopSandbox = async (sandbox) => {
    if (sandbox.status !== 'failed' && !window.confirm(
      'Stop this sandbox? Its app stops and its checkout is deleted, including any changes Claude Code made there.',
    )) return;
    setStopping(sandbox.session_id);
    setSandboxError(sandbox.repository, null);
    try {
      const res = await fetch(`/api/sandboxes/${encodeURIComponent(sandbox.session_id)}`, { method: 'DELETE' });
      const data = await res.json().catch(() => ({}));
      // Not found: already gone, which is what Stop asked for.
      if (!res.ok && res.status !== 404) throw new Error(apiErrorMessage(data, `Could not stop the sandbox (HTTP ${res.status}).`));
      setSandboxes((list) => list.filter((row) => row.session_id !== sandbox.session_id));
      clearPollError(sandbox.session_id);
    } catch (e) {
      setSandboxError(sandbox.repository, e.message);
    } finally {
      setStopping(null);
    }
  };

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const rowStyle = { backgroundColor: darkMode ? '#252525' : '#f9fafb' };
  const secondaryButton = `px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`;
  const connection = status?.connection;
  const selected = connection?.repositories || [];
  const visible = (available || []).filter((r) => r.full_name.toLowerCase().includes(filter.toLowerCase()));
  const { byRepository, others } = groupSandboxes(sandboxes, selected.map((r) => r.full_name));

  const errorText = darkMode ? 'text-red-400' : 'text-red-600';
  // One sandbox: its status, what it failed with, how an agent uses it, and
  // (once ready) Claude Code sessions in its checkout. Under a repository it
  // sits below a divider; listed on its own it names its repository.
  const renderSandbox = (sandbox, { standalone = false } = {}) => {
    const { label, tone } = sandboxStatus(sandbox.status);
    const booting = isSandboxBooting(sandbox);
    const ready = isSandboxReady(sandbox);
    const expiry = ready ? fmtExpiry(sandbox.expires_at) : null;
    const pollError = booting ? pollErrors[sandbox.session_id] : null;
    return (
      <div
        key={sandbox.session_id}
        className={standalone ? 'p-3 rounded-lg space-y-2' : `mt-3 pt-3 border-t space-y-2 ${darkMode ? 'border-gray-700' : 'border-gray-200'}`}
        style={standalone ? rowStyle : undefined}
      >
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2 min-w-0 text-xs">
            <StatusBadge tone={tone}>{label}</StatusBadge>
            <span className={`font-mono truncate ${muted}`}>
              {standalone ? sandbox.repository : ''}@{sandbox.repository_ref}
            </span>
            {expiry && <span className={`shrink-0 ${muted}`}>· {expiry}</span>}
          </div>
          <button
            onClick={() => stopSandbox(sandbox)}
            disabled={stopping === sandbox.session_id}
            className={`shrink-0 px-3 py-1 text-sm rounded disabled:opacity-50 ${darkMode ? 'text-red-300 hover:bg-red-900/40' : 'text-red-600 hover:bg-red-50'}`}
          >
            {stopping === sandbox.session_id ? 'Stopping…' : sandbox.status === 'failed' ? 'Dismiss' : 'Stop'}
          </button>
        </div>
        {booting && !pollError?.stopped && (
          <p className={`text-xs ${muted}`}>Checking out the repository and booting its app; this can take a few minutes.</p>
        )}
        {pollError && (
          <p className={`text-xs ${errorText}`}>
            {pollError.message}{' '}
            {pollError.stopped ? (
              <>
                Stopped checking; its status above may be out of date.{' '}
                <button type="button" onClick={() => clearPollError(sandbox.session_id)} className="underline">Retry</button>
              </>
            ) : 'Trying again…'}
          </p>
        )}
        {sandbox.error_message && (
          <pre className={`p-2 rounded text-xs font-mono whitespace-pre-wrap break-words max-h-48 overflow-y-auto border ${darkMode ? 'bg-red-900/20 border-red-800 text-red-300' : 'bg-red-50 border-red-200 text-red-700'}`}>
            {sandbox.error_message}
          </pre>
        )}
        {sandbox.runtime_server_key && (
          <p className={`text-xs ${muted}`}>
            Enable <code className="font-mono">{sandbox.runtime_server_key}</code> in an agent's Tools tab to run it, or
            evaluate it, with this checkout's tools.
          </p>
        )}
        {ready && sandboxSupport?.codeSessions && (
          <CodeSessionPanel
            sandbox={sandbox}
            claudeCode={sandboxSupport.claudeCode}
            onRecheckConnection={loadSandboxes}
          />
        )}
        {ready && sandboxSupport && !sandboxSupport.codeSessions && (
          <p className={`text-xs ${muted}`}>The configured sandbox backend cannot run Claude Code sessions.</p>
        )}
      </div>
    );
  };

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
                const repoSandboxes = byRepository[repo.full_name] || [];
                // One checkout at a time: a second boot of the same app
                // while the first is still installing only competes with it.
                const booting = repoSandboxes.some(isSandboxBooting);
                return (
                  <div key={repo.full_name} className="p-3 rounded-lg" style={rowStyle}>
                    <div className="flex items-center justify-between">
                      <div>
                        <p className={`text-sm font-mono ${strong}`}>{repo.full_name}</p>
                        <p className={`text-xs ${muted}`}>{repo.private ? 'private' : 'public'} · {repo.default_branch}</p>
                      </div>
                      <button
                        onClick={() => launchSandbox(repo.full_name)}
                        disabled={launching === repo.full_name || booting}
                        className={`${secondaryButton} disabled:opacity-50`}
                      >
                        {launching === repo.full_name ? 'Starting…' : booting ? 'Booting…' : 'Start sandbox'}
                      </button>
                    </div>
                    {sandboxErrors[repo.full_name] && <p className={`mt-2 text-xs ${errorText}`}>{sandboxErrors[repo.full_name]}</p>}
                    {repoSandboxes.map((sandbox) => renderSandbox(sandbox))}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* Outside the connected section: disconnecting GitHub stops none of
          these, so they must stay reachable to be stopped. */}
      {!available && others.length > 0 && (
        <div className="space-y-2">
          <p className={`text-sm font-medium ${strong}`}>{connected ? 'Other sandboxes' : 'Checkout sandboxes'}</p>
          <p className={`text-xs ${muted}`}>
            {connected ? 'From repositories no longer selected.' : 'Checked out while GitHub was connected.'}{' '}
            They keep running until stopped or they expire.
          </p>
          {others.map((sandbox) => (
            <React.Fragment key={sandbox.session_id}>
              {sandboxErrors[sandbox.repository] && <p className={`text-xs ${errorText}`}>{sandboxErrors[sandbox.repository]}</p>}
              {renderSandbox(sandbox, { standalone: true })}
            </React.Fragment>
          ))}
        </div>
      )}
    </div>
  );
}
