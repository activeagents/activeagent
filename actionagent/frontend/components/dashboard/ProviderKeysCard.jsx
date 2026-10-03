import React, { useState } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { clearProviderModels } from '../../utils/providerModels';

const PROVIDER_META = {
  openai: { label: 'OpenAI', icon: '🤖', placeholder: 'sk-…' },
  anthropic: { label: 'Anthropic', icon: '🧠', placeholder: 'sk-ant-…' },
  openrouter: { label: 'OpenRouter', icon: '🔀', placeholder: 'sk-or-…' },
  ollama: { label: 'Ollama', icon: '🦙', placeholder: 'http://localhost:11434/v1' },
};

// Returns the state and actions behind ProviderKeysCard: which provider is
// being edited, the typed values, the last connection test per provider, and
// save, test and remove. Called by the component that renders the card, so
// an open edit and a test result outlive the card when it is hidden and
// shown again (a Settings tab switch).
//
// onKeysChanged: called, and awaited, after a credential is saved or
//   removed, to reload the card's providerKeys.
// onError: shows a failure message to the user; called with null to clear
//   it when a save or a test starts.
export function useProviderKeyEditor({ onKeysChanged, onError }) {
  const [editingProvider, setEditingProvider] = useState(null);
  const [providerInput, setProviderInput] = useState('');
  const [providerApiKeyInput, setProviderApiKeyInput] = useState('');
  const [savingProvider, setSavingProvider] = useState(false);
  // Host-based providers (Ollama): result of the last "Test connection",
  // keyed by provider so it survives switching between rows.
  const [testResults, setTestResults] = useState({});
  const [testingProvider, setTestingProvider] = useState(null);

  const saveProviderKey = async (provider, { hostBased = false, clearApiKey = false } = {}) => {
    if (!providerInput.trim() || savingProvider) return;
    setSavingProvider(true);
    onError(null);
    try {
      const body = { provider, credential: providerInput.trim() };
      // Host-based providers: a typed key replaces the stored one, an empty
      // field keeps it, and "clear" removes it explicitly.
      if (hostBased && (providerApiKeyInput.trim() || clearApiKey)) {
        body.api_key = clearApiKey ? '' : providerApiKeyInput.trim();
      }
      const res = await fetch('/api/provider_keys', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(Array.isArray(data.error) ? data.error.join(', ') : 'save failed');
      }
      setEditingProvider(null);
      setProviderInput('');
      setProviderApiKeyInput('');
      setTestResults((prev) => ({ ...prev, [provider]: null }));
      // A credential decides which models a provider lists (a live lookup
      // with the new key, or an Ollama host's own models).
      clearProviderModels();
      await onKeysChanged();
    } catch (e) {
      onError(`Could not save the ${PROVIDER_META[provider]?.label || provider} credential${e.message !== 'save failed' ? `: ${e.message}` : '.'}`);
    } finally {
      setSavingProvider(false);
    }
  };

  // Checks a host-based provider (Ollama) is reachable and lists its models.
  // While editing, tests the typed host/key (before saving); otherwise the
  // stored one, or the platform default. Nothing is persisted.
  const testProviderHost = async (provider, { editing = false } = {}) => {
    if (testingProvider) return;
    setTestingProvider(provider);
    onError(null);
    try {
      const body = { provider };
      if (editing) {
        if (providerInput.trim()) body.credential = providerInput.trim();
        if (providerApiKeyInput.trim()) body.api_key = providerApiKeyInput.trim();
      }
      const res = await fetch('/api/provider_keys/test', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || 'test failed');
      setTestResults((prev) => ({ ...prev, [provider]: data }));
    } catch (e) {
      setTestResults((prev) => ({ ...prev, [provider]: { ok: false, models: [], error: e.message } }));
    } finally {
      setTestingProvider(null);
    }
  };

  const removeProviderKey = async (provider) => {
    if (!window.confirm('Remove this provider credential? Runs will fall back to the platform default credentials, or fail until a key is configured.')) return;
    try {
      const res = await fetch(`/api/provider_keys/${provider}`, { method: 'DELETE' });
      if (!res.ok) throw new Error('delete failed');
      setTestResults((prev) => ({ ...prev, [provider]: null }));
      clearProviderModels();
      await onKeysChanged();
    } catch (e) {
      onError('Could not remove the provider credential.');
    }
  };

  return {
    editingProvider,
    setEditingProvider,
    providerInput,
    setProviderInput,
    providerApiKeyInput,
    setProviderApiKeyInput,
    savingProvider,
    testResults,
    testingProvider,
    saveProviderKey,
    testProviderHost,
    removeProviderKey,
  };
}

// The 'Provider API Keys' card: one row per LLM provider credential the
// owner can configure, update, remove and, for a host-based provider
// (Ollama), test.
//
// providerKeys: the rows GET /api/provider_keys returns; connection rows
//   (Claude Code, Codex) are left to their own cards.
// editor: what useProviderKeyEditor returns.
export default function ProviderKeysCard({ providerKeys, editor }) {
  const { darkMode } = useTheme();
  const {
    editingProvider, setEditingProvider, providerInput, setProviderInput,
    providerApiKeyInput, setProviderApiKeyInput, savingProvider, testResults, testingProvider,
    saveProviderKey, testProviderHost, removeProviderKey,
  } = editor;

  const cardStyle = {
    backgroundColor: darkMode ? '#1f1f1f' : '#ffffff',
    borderColor: darkMode ? '#2a2a2a' : '#e5e7eb',
  };

  return (
    <div className="border rounded-lg p-6" style={cardStyle}>
      <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
        Provider API Keys
      </h3>
      <p className={`text-sm mb-4 ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
        Configure your own LLM provider credentials. Agent runs and evaluations on this
        account use these instead of the platform defaults. Keys are encrypted at rest.
      </p>
      <div className="space-y-4">
        {providerKeys.filter(({ kind }) => kind !== 'connection').map(({
          provider, host_based: hostBased, configured, hint,
          api_key_configured: apiKeyConfigured, api_key_hint: apiKeyHint, platform_default: platformDefault,
        }) => {
          const meta = PROVIDER_META[provider] || { label: provider, icon: '🔑', placeholder: '' };
          const editing = editingProvider === provider;
          const testResult = testResults[provider];
          const testing = testingProvider === provider;
          const testable = hostBased && (editing ? providerInput.trim() : (configured || platformDefault));
          const statusText = configured
            ? (hostBased ? `${hint}${apiKeyConfigured ? ` · key ${apiKeyHint}` : ''}` : `Configured (${hint})`)
            : (hostBased && platformDefault ? `Platform default: ${platformDefault}` : 'Not configured');
          return (
            <div key={provider} className="p-4 rounded-lg" style={{ backgroundColor: darkMode ? '#252525' : '#f9fafb' }}>
              <div className="flex items-center justify-between">
                <div className="flex items-center space-x-3">
                  <span className="text-xl">{meta.icon}</span>
                  <div>
                    <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>{meta.label}</p>
                    <p className={`text-sm ${configured ? (darkMode ? 'text-green-400' : 'text-green-600') : (darkMode ? 'text-gray-400' : 'text-gray-500')}`}>
                      {statusText}
                    </p>
                  </div>
                </div>
                <div className="flex items-center space-x-2">
                  {hostBased && !editing && testable && (
                    <button
                      onClick={() => testProviderHost(provider)}
                      disabled={testing}
                      className={`px-3 py-1 text-sm rounded disabled:opacity-50 ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`}
                    >
                      {testing ? 'Testing…' : 'Test connection'}
                    </button>
                  )}
                  {configured && !editing && (
                    <button
                      onClick={() => removeProviderKey(provider)}
                      className={`px-3 py-1 text-sm rounded ${darkMode ? 'text-red-300 hover:bg-red-900/40' : 'text-red-600 hover:bg-red-50'}`}
                    >
                      Remove
                    </button>
                  )}
                  <button
                    onClick={() => {
                      setEditingProvider(editing ? null : provider);
                      // Pre-fill the host so "Update" edits the current value
                      // instead of starting from a blank field.
                      setProviderInput(!editing && hostBased && configured ? hint : '');
                      setProviderApiKeyInput('');
                    }}
                    className={`px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`}
                  >
                    {editing ? 'Cancel' : configured ? 'Update' : 'Configure'}
                  </button>
                </div>
              </div>
              {editing && (
                <div className="mt-3 space-y-2">
                  <div className="flex items-center space-x-2">
                    <input
                      type={hostBased ? 'text' : 'password'}
                      value={providerInput}
                      onChange={(e) => setProviderInput(e.target.value)}
                      onKeyDown={(e) => e.key === 'Enter' && saveProviderKey(provider, { hostBased })}
                      placeholder={hostBased ? meta.placeholder : `${meta.label} API key (${meta.placeholder})`}
                      aria-label={hostBased ? `${meta.label} host URL` : `${meta.label} API key`}
                      autoFocus
                      className={`flex-1 px-3 py-2 border rounded-lg text-sm font-mono ${
                        darkMode
                          ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500'
                          : 'bg-white border-gray-300 text-gray-900'
                      }`}
                    />
                    {hostBased && (
                      <button
                        onClick={() => testProviderHost(provider, { editing: true })}
                        disabled={!providerInput.trim() || testing}
                        className={`px-3 py-2 text-sm rounded-lg disabled:opacity-50 ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`}
                      >
                        {testing ? 'Testing…' : 'Test'}
                      </button>
                    )}
                    <button
                      onClick={() => saveProviderKey(provider, { hostBased })}
                      disabled={!providerInput.trim() || savingProvider}
                      className="px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600 disabled:opacity-50 text-sm"
                    >
                      {savingProvider ? 'Saving…' : 'Save'}
                    </button>
                  </div>
                  {hostBased && (
                    <div className="flex items-center space-x-2">
                      <input
                        type="password"
                        value={providerApiKeyInput}
                        onChange={(e) => setProviderApiKeyInput(e.target.value)}
                        onKeyDown={(e) => e.key === 'Enter' && saveProviderKey(provider, { hostBased })}
                        placeholder={apiKeyConfigured ? `API key (stored: ${apiKeyHint} — type to replace)` : 'API key (optional — only for remote servers that require one)'}
                        aria-label={`${meta.label} API key`}
                        className={`flex-1 px-3 py-2 border rounded-lg text-sm font-mono ${
                          darkMode
                            ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500'
                            : 'bg-white border-gray-300 text-gray-900'
                        }`}
                      />
                      {apiKeyConfigured && (
                        <button
                          onClick={() => saveProviderKey(provider, { hostBased, clearApiKey: true })}
                          disabled={!providerInput.trim() || savingProvider}
                          className={`px-3 py-2 text-sm rounded-lg disabled:opacity-50 ${darkMode ? 'text-red-300 hover:bg-red-900/40' : 'text-red-600 hover:bg-red-50'}`}
                        >
                          Clear key
                        </button>
                      )}
                    </div>
                  )}
                </div>
              )}
              {hostBased && editing && (
                <p className={`mt-2 text-xs ${darkMode ? 'text-gray-500' : 'text-gray-400'}`}>
                  Your Ollama server's address — the OpenAI-compatible /v1 path is added
                  if you leave it off. Local: http://localhost:11434. Remote: a LAN host,
                  a tunnel URL, or Ollama Cloud (https://ollama.com), which needs an API
                  key. Test lists the models the server currently serves.
                </p>
              )}
              {hostBased && testResult && (
                <div
                  className="mt-2 text-xs rounded-lg px-3 py-2"
                  role="status"
                  style={{
                    backgroundColor: testResult.ok ? (darkMode ? 'rgba(74,222,128,0.1)' : '#ecfdf5') : (darkMode ? 'rgba(248,113,113,0.1)' : '#fef2f2'),
                    color: testResult.ok ? (darkMode ? '#4ade80' : '#047857') : (darkMode ? '#f87171' : '#b91c1c'),
                  }}
                >
                  {testResult.ok ? (
                    <>
                      <span className="font-medium">Connected</span>
                      {' '}to {testResult.host}
                      {typeof testResult.latency_ms === 'number' ? ` in ${testResult.latency_ms} ms` : ''}
                      {' · '}
                      {testResult.models.length === 0
                        ? 'no models pulled yet (run `ollama pull <model>` on the server)'
                        : `${testResult.models.length} model${testResult.models.length === 1 ? '' : 's'}`}
                      {testResult.models.length > 0 && (
                        <span className="block mt-1 font-mono" style={{ color: darkMode ? '#d1d5db' : '#374151' }}>
                          {testResult.models.join(' · ')}
                        </span>
                      )}
                    </>
                  ) : (
                    <><span className="font-medium">Not reachable.</span> {testResult.error}</>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
