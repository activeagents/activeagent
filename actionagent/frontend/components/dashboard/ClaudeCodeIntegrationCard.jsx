import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';

const PROVIDER = 'claude_code';

// Settings -> Integrations: the owner's Claude Code credential. Stored like a
// provider key (write-only, masked hint) and handed to checkout sandboxes so
// the booted app can run Claude Code sessions.
export default function ClaudeCodeIntegrationCard() {
  const { darkMode } = useTheme();
  const [state, setState] = useState(null); // { configured, hint, updated_at }
  const [editing, setEditing] = useState(false);
  const [input, setInput] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    try {
      const res = await fetch('/api/provider_keys');
      if (!res.ok) throw new Error('load failed');
      const data = await res.json();
      setState((data.provider_keys || []).find((row) => row.provider === PROVIDER) || { configured: false });
    } catch (e) {
      setError('Could not load the Claude Code connection. Are you signed in?');
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const save = async () => {
    if (!input.trim() || saving) return;
    setSaving(true);
    setError(null);
    try {
      const res = await fetch('/api/provider_keys', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ provider: PROVIDER, credential: input.trim() }),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(Array.isArray(data.error) ? data.error.join(', ') : 'Could not save the token.');
      }
      setEditing(false);
      setInput('');
      await load();
    } catch (e) {
      setError(e.message);
    } finally {
      setSaving(false);
    }
  };

  const remove = async () => {
    if (!window.confirm('Disconnect Claude Code? Sandboxes started afterwards will not be able to run Claude Code sessions.')) return;
    try {
      const res = await fetch(`/api/provider_keys/${PROVIDER}`, { method: 'DELETE' });
      if (!res.ok) throw new Error('delete failed');
      await load();
    } catch (e) {
      setError('Could not disconnect Claude Code.');
    }
  };

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const configured = state?.configured;

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center space-x-3">
          <span className="text-xl">✳️</span>
          <div>
            <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>Claude Code</p>
            <p className={`text-sm ${configured ? (darkMode ? 'text-green-400' : 'text-green-600') : muted}`}>
              {!state ? 'Loading…' : configured ? `Connected (${state.hint})` : 'Not connected'}
            </p>
          </div>
        </div>
        <div className="flex items-center space-x-2">
          {configured && !editing && (
            <button onClick={remove} className={`px-3 py-1 text-sm rounded ${darkMode ? 'text-red-300 hover:bg-red-900/40' : 'text-red-600 hover:bg-red-50'}`}>
              Disconnect
            </button>
          )}
          <button
            onClick={() => { setEditing(!editing); setInput(''); setError(null); }}
            className={`px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`}
          >
            {editing ? 'Cancel' : configured ? 'Update' : 'Connect'}
          </button>
        </div>
      </div>

      {editing && (
        <>
          <div className="flex items-center space-x-2">
            <input
              type="password"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && save()}
              placeholder="sk-ant-oat01-…"
              autoFocus
              className={`flex-1 px-3 py-2 border rounded-lg text-sm font-mono ${
                darkMode ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500' : 'bg-white border-gray-300 text-gray-900'
              }`}
            />
            <button
              onClick={save}
              disabled={!input.trim() || saving}
              className="px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600 disabled:opacity-50 text-sm"
            >
              {saving ? 'Saving…' : 'Save'}
            </button>
          </div>
          <p className={`text-xs ${muted}`}>
            Run <code className="font-mono">claude setup-token</code> and paste the token it prints, or paste an
            Anthropic API key. It is encrypted at rest and passed to checkout sandboxes so they can run Claude Code
            sessions against the repository.
          </p>
        </>
      )}

      {error && (
        <div className={`p-3 rounded-lg text-sm border ${darkMode ? 'bg-red-900/20 border-red-800 text-red-300' : 'bg-red-50 border-red-200 text-red-700'}`}>
          {error}
        </div>
      )}
    </div>
  );
}
