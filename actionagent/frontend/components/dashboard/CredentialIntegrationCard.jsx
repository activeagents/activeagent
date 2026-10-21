import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { requestConfirm } from '../../utils/confirm.mjs';

// A tool connected with one workspace credential (a ProviderKey connection
// provider, such as Slack's bot token), configured beside the model
// providers in Settings -> Integrations and never offered as one. Codex has
// a card of its own, since it can also run on the machine's own login.
export default function CredentialIntegrationCard({ provider, title, description, credentialLabel, placeholder, onChange }) {
  const { darkMode } = useTheme();
  const [connection, setConnection] = useState(null);
  const [editing, setEditing] = useState(false);
  const [credential, setCredential] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const load = useCallback(async () => {
    const res = await fetch('/api/provider_keys');
    if (!res.ok) throw new Error(`Could not load the ${title} connection.`);
    const data = await res.json();
    setConnection((data.provider_keys || []).find((row) => row.provider === provider) || { configured: false });
  }, [provider, title]);
  useEffect(() => { load().catch((e) => setError(e.message)); }, [load]);

  const save = async (event) => {
    event.preventDefault();
    if (saving || !credential.trim()) return;
    setSaving(true);
    setError(null);
    try {
      const res = await fetch('/api/provider_keys', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ provider, credential: credential.trim() }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(Array.isArray(data.error) ? data.error.join(', ') : data.error || `Could not save the ${credentialLabel}.`);
      setCredential('');
      setEditing(false);
      await load();
      onChange?.();
    } catch (e) { setError(e.message); }
    finally { setSaving(false); }
  };

  const disconnect = async () => {
    if (!(await requestConfirm({
      title: `Disconnect ${title}?`,
      message: `${title} will need its ${credentialLabel} connected again.`,
      confirmLabel: 'Disconnect',
      danger: true,
    }))) return;
    setSaving(true);
    setError(null);
    try {
      const res = await fetch(`/api/provider_keys/${provider}`, { method: 'DELETE' });
      if (!res.ok) throw new Error(`Could not disconnect ${title}.`);
      await load();
      onChange?.();
    } catch (e) { setError(e.message); }
    finally { setSaving(false); }
  };

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const button = `px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-200' : 'bg-gray-200 text-gray-800'}`;
  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>{title}</p>
          <p className={`text-sm ${muted}`}>{connection == null ? 'Loading…' : connection.configured ? `Connected · ${connection.hint}` : 'Not connected'}</p>
        </div>
        <div className="flex gap-2">
          {connection?.configured && !editing && <button className={button} disabled={saving} onClick={disconnect}>Disconnect</button>}
          <button className={button} disabled={saving || connection == null} onClick={() => { setEditing(!editing); setCredential(''); setError(null); }}>
            {editing ? 'Cancel' : connection?.configured ? 'Update' : 'Connect'}
          </button>
        </div>
      </div>
      <p className={`text-sm ${muted}`}>{description}</p>
      {editing && (
        <form onSubmit={save} className="flex flex-wrap gap-2">
          <label className={`flex-1 text-sm ${muted}`}>
            {credentialLabel}
            <input type="password" data-aa-secret="" autoComplete="off" spellCheck={false} value={credential} onChange={(e) => setCredential(e.target.value)} placeholder={placeholder} disabled={saving}
              className={`block w-full mt-1 px-3 py-2 border rounded ${darkMode ? 'bg-gray-800 border-gray-700 text-white' : 'bg-white border-gray-300 text-gray-900'}`} />
          </label>
          <button type="submit" className={`${button} self-end`} disabled={saving || !credential.trim()}>{saving ? 'Saving…' : 'Save'}</button>
        </form>
      )}
      {error && <p role="alert" className="text-sm text-red-500">{error}</p>}
    </div>
  );
}
