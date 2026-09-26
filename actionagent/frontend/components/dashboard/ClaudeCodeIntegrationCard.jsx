import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import {
  CLAUDE_CODE_API_KEY_PLACEHOLDER,
  CLAUDE_CODE_POLICY_URL,
  CLAUDE_CONSOLE_URL,
  claudeCodeAuth,
  claudeCodeCardState,
} from '../../utils/codeSessions.mjs';

const PROVIDER = 'claude_code';

// Settings -> Integrations: how Claude Code sessions authenticate.
//
// Usually with the owner's Anthropic API key, stored like a provider key
// (write-only, masked hint) and handed to checkout sandboxes so the booted
// app can run Claude Code sessions. When the install runs them on this
// machine's own Claude Code login instead (claude_code_auth "local_login"),
// there is no key to store: the card shows whether that login is there.
// Claude subscription tokens are never asked for (see CLAUDE_CODE_POLICY_URL).
// onChange fires after a save or a disconnect, so the sandbox card can
// unlock or lock its session panel.
export default function ClaudeCodeIntegrationCard({ onChange }) {
  const { darkMode } = useTheme();
  const [state, setState] = useState(null); // { configured, hint, updated_at, needs_replacing }
  const [auth, setAuth] = useState(null); // claudeCodeAuth of the sandbox listing
  const [editing, setEditing] = useState(false);
  const [input, setInput] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    try {
      const [keys, listing] = await Promise.all([fetch('/api/provider_keys'), fetch('/api/sandboxes?sandbox_type=app_runtime')]);
      if (!keys.ok || !listing.ok) throw new Error('load failed');
      const [keyData, listingData] = await Promise.all([keys.json(), listing.json()]);
      setState((keyData.provider_keys || []).find((row) => row.provider === PROVIDER) || { configured: false });
      setAuth(claudeCodeAuth(listingData));
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
        throw new Error(Array.isArray(data.error) ? data.error.join(', ') : 'Could not save the API key.');
      }
      setEditing(false);
      setInput('');
      await load();
      onChange?.();
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
      onChange?.();
    } catch (e) {
      setError('Could not disconnect Claude Code.');
    }
  };

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const card = claudeCodeCardState(auth, state);
  const configured = card.keyForm && state?.configured;
  const toneClass = {
    success: darkMode ? 'text-green-400' : 'text-green-600',
    error: darkMode ? 'text-amber-300' : 'text-amber-700',
    neutral: muted,
  }[card.tone];
  const link = `underline ${darkMode ? 'text-gray-300' : 'text-gray-700'}`;

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center space-x-3">
          <span className="text-xl">✳️</span>
          <div>
            <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>Claude Code</p>
            <p className={`text-sm ${toneClass}`}>{card.status}</p>
          </div>
        </div>
        {card.keyForm && (
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
              {editing ? 'Cancel' : card.needsReplacing ? 'Replace' : configured ? 'Update' : 'Connect'}
            </button>
          </div>
        )}
        {card.view === 'local_login' && (
          <button
            onClick={() => { setError(null); load(); onChange?.(); }}
            className={`px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`}
          >
            Check again
          </button>
        )}
      </div>

      {card.view === 'local_login' && (
        <p className={`text-xs ${muted}`}>
          Sessions run <code className="font-mono">claude</code> on this machine with its own login, which the dashboard
          never reads or stores.{' '}
          {card.loginHint && (
            <>
              Run <code className="font-mono">{card.loginHint}</code> on this machine, as the user the dashboard runs as,
              then check again.
            </>
          )}
        </p>
      )}

      {card.needsReplacing && !editing && (
        <p className={`text-xs ${darkMode ? 'text-amber-300' : 'text-amber-700'}`}>
          The Claude subscription token stored here is no longer used: Anthropic does not allow third-party apps to hold
          Claude.ai credentials. Replace it with an Anthropic API key to run Claude Code sessions.
        </p>
      )}

      {card.keyForm && editing && (
        <>
          <div className="flex items-center space-x-2">
            <input
              type="password"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && save()}
              placeholder={CLAUDE_CODE_API_KEY_PLACEHOLDER}
              aria-label="Anthropic API key"
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
            Paste an Anthropic API key from the{' '}
            <a href={CLAUDE_CONSOLE_URL} target="_blank" rel="noreferrer" className={link}>Claude Console</a>. It is
            encrypted at rest and passed to checkout sandboxes so they can run Claude Code sessions against the
            repository. Claude subscription logins cannot be stored here (
            <a href={CLAUDE_CODE_POLICY_URL} target="_blank" rel="noreferrer" className={link}>why</a>); to use your own
            on this machine, the install can run sessions on its local Claude Code login instead.
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
