import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { requestConfirm } from '../../utils/confirm.mjs';
import { codexAuth, codexCardState } from '../../utils/codeSessions.mjs';

// Settings -> Integrations: how Codex sessions authenticate.
//
// Usually with a workspace-owned OpenAI API key, separate from the agent
// builder's key, stored write-only (masked hint) and billed to that key's
// project. When the install runs Codex on this machine's own login instead
// (codex_auth "local_login"), there is no key to store: the card shows
// whether that login is there. onChange fires after a save, a disconnect or
// a re-check, so the sandbox card can unlock or lock its session panel.
export default function CodexIntegrationCard({ onChange }) {
  const { darkMode } = useTheme();
  const [connection, setConnection] = useState(null); // the stored key's row, or { configured: false }
  const [auth, setAuth] = useState(null); // codexAuth of the sandbox listing
  const [editing, setEditing] = useState(false);
  const [credential, setCredential] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const load = useCallback(async () => {
    const [keys, listing] = await Promise.all([fetch('/api/provider_keys'), fetch('/api/sandboxes?sandbox_type=app_runtime')]);
    if (!keys.ok || !listing.ok) throw new Error('Could not load the Codex connection.');
    const [keyData, listingData] = await Promise.all([keys.json(), listing.json()]);
    setConnection((keyData.provider_keys || []).find((row) => row.provider === 'codex') || { configured: false });
    setAuth(codexAuth(listingData));
  }, []);
  useEffect(() => { load().catch((e) => setError(e.message)); }, [load]);

  const save = async (event) => {
    event.preventDefault();
    if (saving || !credential.trim()) return;
    setSaving(true);
    setError(null);
    try {
      const res = await fetch('/api/provider_keys', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ provider: 'codex', credential: credential.trim() }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(Array.isArray(data.error) ? data.error.join(', ') : data.error || 'Could not save the API key.');
      setCredential('');
      setEditing(false);
      await load();
      onChange?.();
    } catch (e) { setError(e.message); }
    finally { setSaving(false); }
  };

  const disconnect = async () => {
    if (!(await requestConfirm({
      title: 'Disconnect Codex?',
      message: 'New Codex sessions will need an API key connected again.',
      confirmLabel: 'Disconnect',
      danger: true,
    }))) return;
    setSaving(true);
    setError(null);
    try {
      const res = await fetch('/api/provider_keys/codex', { method: 'DELETE' });
      if (!res.ok) throw new Error('Could not disconnect Codex.');
      await load();
      onChange?.();
    } catch (e) { setError(e.message); }
    finally { setSaving(false); }
  };

  // The machine's login may have changed since the page loaded.
  const recheck = async () => {
    setError(null);
    try {
      await load();
      onChange?.();
    } catch (e) { setError(e.message); }
  };

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const button = `px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-200' : 'bg-gray-200 text-gray-800'}`;
  const card = codexCardState(auth, connection);
  const toneClass = {
    success: darkMode ? 'text-green-400' : 'text-green-600',
    error: darkMode ? 'text-amber-300' : 'text-amber-700',
    neutral: muted,
  }[card.tone];
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>Codex</p>
          <p className={`text-sm ${toneClass}`}>{card.status}</p>
        </div>
        <div className="flex gap-2">
          {card.keyForm && connection?.configured && !editing && <button className={button} disabled={saving} onClick={disconnect}>Disconnect</button>}
          {card.keyForm && (
            <button className={button} disabled={saving} onClick={() => { setEditing(!editing); setCredential(''); setError(null); }}>
              {editing ? 'Cancel' : connection?.configured ? 'Update' : 'Connect'}
            </button>
          )}
          {card.view === 'local_login' && <button className={button} disabled={saving} onClick={recheck}>Check again</button>}
        </div>
      </div>
      {card.view === 'local_login' ? (
        <p className={`text-xs ${muted}`}>
          Sessions run <code className="font-mono">codex</code> on this machine with its own login (a ChatGPT plan, or a key the
          CLI holds), which the dashboard never reads or stores.{' '}
          {card.loginHint && (
            <>
              Run <code className="font-mono">{card.loginHint}</code> on this machine, as the user the dashboard runs as, then
              check again.
            </>
          )}
        </p>
      ) : (
        <p className={`text-sm ${muted}`}>Run Codex in a repository checkout using an OpenAI API key. API usage is billed to that key's project.</p>
      )}
      {card.keyForm && editing && (
        <form onSubmit={save} className="flex flex-wrap gap-2">
          <label className={`flex-1 text-sm ${muted}`}>
            OpenAI API key for Codex
            <input type="password" data-aa-secret="" autoComplete="off" spellCheck={false} value={credential} onChange={(e) => setCredential(e.target.value)} placeholder="sk-…" disabled={saving}
              className={`block w-full mt-1 px-3 py-2 border rounded ${darkMode ? 'bg-gray-800 border-gray-700 text-white' : 'bg-white border-gray-300 text-gray-900'}`} />
          </label>
          <button type="submit" className={`${button} self-end`} disabled={saving || !credential.trim()}>{saving ? 'Saving…' : 'Save API key'}</button>
        </form>
      )}
      {error && <p role="alert" className="text-sm text-red-500">{error}</p>}
    </div>
  );
}
