import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';

const PROVIDER_META = {
  openai: { label: 'OpenAI', icon: '🤖', placeholder: 'sk-…' },
  anthropic: { label: 'Anthropic', icon: '🧠', placeholder: 'sk-ant-…' },
  openrouter: { label: 'OpenRouter', icon: '🔀', placeholder: 'sk-or-…' },
  ollama: { label: 'Ollama', icon: '🦙', placeholder: 'http://localhost:11434/v1' },
};

export default function SettingsView({ user, account }) {
  const { darkMode, toggleDarkMode } = useTheme();
  const [activeTab, setActiveTab] = useState('profile');

  // API Keys tab state
  const [apiKeys, setApiKeys] = useState([]);
  const [providerKeys, setProviderKeys] = useState([]);
  const [keysLoaded, setKeysLoaded] = useState(false);
  const [newKeyName, setNewKeyName] = useState('');
  const [creatingKey, setCreatingKey] = useState(false);
  const [createdKey, setCreatedKey] = useState(null); // { name, token } shown once
  const [copied, setCopied] = useState(false);
  const [keysError, setKeysError] = useState(null);
  const [editingProvider, setEditingProvider] = useState(null);
  const [providerInput, setProviderInput] = useState('');
  const [savingProvider, setSavingProvider] = useState(false);

  const loadKeys = useCallback(async () => {
    try {
      const [keysRes, providersRes] = await Promise.all([
        fetch('/api/api_keys'),
        fetch('/api/provider_keys'),
      ]);
      if (!keysRes.ok || !providersRes.ok) throw new Error('Failed to load keys');
      const keysData = await keysRes.json();
      const providersData = await providersRes.json();
      setApiKeys(keysData.api_keys || []);
      setProviderKeys(providersData.provider_keys || []);
      setKeysError(null);
    } catch (e) {
      setKeysError('Could not load API keys. Are you signed in?');
    } finally {
      setKeysLoaded(true);
    }
  }, []);

  useEffect(() => {
    if (activeTab === 'api-keys' && !keysLoaded) loadKeys();
  }, [activeTab, keysLoaded, loadKeys]);

  const createApiKey = async () => {
    if (!newKeyName.trim() || creatingKey) return;
    setCreatingKey(true);
    setKeysError(null);
    try {
      const res = await fetch('/api/api_keys', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: newKeyName.trim() }),
      });
      if (!res.ok) throw new Error('create failed');
      const data = await res.json();
      setCreatedKey(data.api_key);
      setCopied(false);
      setNewKeyName('');
      await loadKeys();
    } catch (e) {
      setKeysError('Could not create the API key.');
    } finally {
      setCreatingKey(false);
    }
  };

  const revokeApiKey = async (id) => {
    if (!window.confirm('Revoke this API key? Requests using it will stop working immediately.')) return;
    try {
      const res = await fetch(`/api/api_keys/${id}`, { method: 'DELETE' });
      if (!res.ok) throw new Error('delete failed');
      if (createdKey && createdKey.id === id) setCreatedKey(null);
      await loadKeys();
    } catch (e) {
      setKeysError('Could not revoke the API key.');
    }
  };

  const saveProviderKey = async (provider) => {
    if (!providerInput.trim() || savingProvider) return;
    setSavingProvider(true);
    setKeysError(null);
    try {
      const res = await fetch('/api/provider_keys', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ provider, credential: providerInput.trim() }),
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(Array.isArray(data.error) ? data.error.join(', ') : 'save failed');
      }
      setEditingProvider(null);
      setProviderInput('');
      await loadKeys();
    } catch (e) {
      setKeysError(`Could not save the ${PROVIDER_META[provider]?.label || provider} credential${e.message !== 'save failed' ? `: ${e.message}` : '.'}`);
    } finally {
      setSavingProvider(false);
    }
  };

  const removeProviderKey = async (provider) => {
    if (!window.confirm('Remove this provider credential? Runs will fall back to the platform default credentials, or fail until a key is configured.')) return;
    try {
      const res = await fetch(`/api/provider_keys/${provider}`, { method: 'DELETE' });
      if (!res.ok) throw new Error('delete failed');
      await loadKeys();
    } catch (e) {
      setKeysError('Could not remove the provider credential.');
    }
  };

  const copyToken = async (token) => {
    try {
      await navigator.clipboard.writeText(token);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch (e) {
      // Clipboard unavailable (e.g. insecure context); the token stays visible for manual copy.
    }
  };

  const cardStyle = {
    backgroundColor: darkMode ? '#1f1f1f' : '#ffffff',
    borderColor: darkMode ? '#2a2a2a' : '#e5e7eb',
  };

  const tabs = [
    { id: 'profile', label: 'Profile' },
    { id: 'api-keys', label: 'API Keys' },
    { id: 'notifications', label: 'Notifications' },
    { id: 'billing', label: 'Billing' },
  ];

  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div>
        <h2 className={`text-2xl font-bold ${darkMode ? 'text-white' : 'text-gray-900'}`}>
          Settings
        </h2>
        <p className={`mt-1 ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
          Manage your account and preferences
        </p>
      </div>

      {/* Tabs */}
      <div className="border-b" style={{ borderColor: darkMode ? '#2a2a2a' : '#e5e7eb' }}>
        <nav className="flex space-x-8">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`py-4 px-1 border-b-2 font-medium text-sm transition-colors ${
                activeTab === tab.id
                  ? 'border-red-500 text-red-500'
                  : `border-transparent ${darkMode ? 'text-gray-400 hover:text-gray-300' : 'text-gray-500 hover:text-gray-700'}`
              }`}
            >
              {tab.label}
            </button>
          ))}
        </nav>
      </div>

      {/* Profile Tab */}
      {activeTab === 'profile' && (
        <div className="space-y-6">
          <div className="border rounded-lg p-6" style={cardStyle}>
            <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
              Profile Information
            </h3>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label className={`block text-sm font-medium mb-1 ${darkMode ? 'text-gray-300' : 'text-gray-700'}`}>
                  First Name
                </label>
                <input
                  type="text"
                  defaultValue={user?.name?.split(' ')[0] || ''}
                  className={`w-full px-3 py-2 border rounded-lg ${
                    darkMode
                      ? 'bg-gray-800 border-gray-700 text-white'
                      : 'bg-white border-gray-300 text-gray-900'
                  }`}
                />
              </div>
              <div>
                <label className={`block text-sm font-medium mb-1 ${darkMode ? 'text-gray-300' : 'text-gray-700'}`}>
                  Last Name
                </label>
                <input
                  type="text"
                  defaultValue={user?.name?.split(' ')[1] || ''}
                  className={`w-full px-3 py-2 border rounded-lg ${
                    darkMode
                      ? 'bg-gray-800 border-gray-700 text-white'
                      : 'bg-white border-gray-300 text-gray-900'
                  }`}
                />
              </div>
              <div className="md:col-span-2">
                <label className={`block text-sm font-medium mb-1 ${darkMode ? 'text-gray-300' : 'text-gray-700'}`}>
                  Email
                </label>
                <input
                  type="email"
                  defaultValue={user?.email || ''}
                  disabled
                  className={`w-full px-3 py-2 border rounded-lg cursor-not-allowed ${
                    darkMode
                      ? 'bg-gray-900 border-gray-700 text-gray-500'
                      : 'bg-gray-100 border-gray-300 text-gray-500'
                  }`}
                />
              </div>
            </div>
            <button className="mt-4 px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600">
              Save Changes
            </button>
          </div>

          {/* Appearance */}
          <div className="border rounded-lg p-6" style={cardStyle}>
            <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
              Appearance
            </h3>
            <div className="flex items-center justify-between">
              <div>
                <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                  Dark Mode
                </p>
                <p className={`text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
                  Use dark theme across the dashboard
                </p>
              </div>
              <button
                onClick={toggleDarkMode}
                className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                  darkMode ? 'bg-red-500' : 'bg-gray-300'
                }`}
              >
                <span
                  className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                    darkMode ? 'translate-x-6' : 'translate-x-1'
                  }`}
                />
              </button>
            </div>
          </div>
        </div>
      )}

      {/* API Keys Tab */}
      {activeTab === 'api-keys' && (
        <div className="space-y-6">
          <div className="border rounded-lg p-6" style={cardStyle}>
            <div className="flex items-center justify-between mb-4">
              <h3 className={`text-lg font-semibold ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                API Keys
              </h3>
              <div className="flex items-center space-x-2">
                <input
                  type="text"
                  value={newKeyName}
                  onChange={(e) => setNewKeyName(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && createApiKey()}
                  placeholder="Key name (e.g. production)"
                  className={`px-3 py-2 border rounded-lg text-sm ${
                    darkMode
                      ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500'
                      : 'bg-white border-gray-300 text-gray-900'
                  }`}
                />
                <button
                  onClick={createApiKey}
                  disabled={!newKeyName.trim() || creatingKey}
                  className="px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600 disabled:opacity-50 whitespace-nowrap"
                >
                  {creatingKey ? 'Creating…' : '+ Create New Key'}
                </button>
              </div>
            </div>

            <div className={`p-4 rounded-lg mb-4 ${darkMode ? 'bg-yellow-900/20 border border-yellow-800' : 'bg-yellow-50 border border-yellow-200'}`}>
              <p className={`text-sm ${darkMode ? 'text-yellow-300' : 'text-yellow-800'}`}>
                ⚠️ API keys are secrets. Never share them or commit them to version control.
              </p>
            </div>

            {keysError && (
              <div className={`p-4 rounded-lg mb-4 text-sm ${darkMode ? 'bg-red-900/20 border border-red-800 text-red-300' : 'bg-red-50 border border-red-200 text-red-700'}`}>
                {keysError}
              </div>
            )}

            {createdKey && (
              <div className={`p-4 rounded-lg mb-4 border ${darkMode ? 'bg-green-900/20 border-green-800' : 'bg-green-50 border-green-200'}`}>
                <p className={`text-sm font-medium mb-2 ${darkMode ? 'text-green-300' : 'text-green-800'}`}>
                  Key “{createdKey.name}” created. Copy it now — it won't be shown again.
                </p>
                <div className="flex items-center space-x-2">
                  <code className={`flex-1 px-3 py-2 rounded text-sm font-mono break-all ${darkMode ? 'bg-gray-900 text-green-300' : 'bg-white text-green-800 border border-green-200'}`}>
                    {createdKey.token}
                  </code>
                  <button
                    onClick={() => copyToken(createdKey.token)}
                    className={`px-3 py-2 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-200 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`}
                  >
                    {copied ? 'Copied!' : 'Copy'}
                  </button>
                  <button
                    onClick={() => setCreatedKey(null)}
                    className={`px-3 py-2 text-sm rounded ${darkMode ? 'text-gray-400 hover:text-gray-200' : 'text-gray-500 hover:text-gray-700'}`}
                  >
                    Dismiss
                  </button>
                </div>
              </div>
            )}

            {apiKeys.length === 0 ? (
              <div className={`text-center py-8 ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
                <p>{keysLoaded ? 'No API keys yet' : 'Loading…'}</p>
                {keysLoaded && <p className="text-sm">Create your first API key to authenticate requests</p>}
              </div>
            ) : (
              <div className="space-y-2">
                {apiKeys.map((key) => (
                  <div
                    key={key.id}
                    className="flex items-center justify-between p-4 rounded-lg"
                    style={{ backgroundColor: darkMode ? '#252525' : '#f9fafb' }}
                  >
                    <div>
                      <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>{key.name}</p>
                      <p className={`text-sm font-mono ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
                        {key.masked_token}
                        <span className="font-sans">
                          {' · created '}{new Date(key.created_at).toLocaleDateString()}
                          {key.last_used_at
                            ? ` · last used ${new Date(key.last_used_at).toLocaleDateString()}`
                            : ' · never used'}
                        </span>
                      </p>
                    </div>
                    <button
                      onClick={() => revokeApiKey(key.id)}
                      className={`px-3 py-1 text-sm rounded ${darkMode ? 'bg-red-900/40 text-red-300 hover:bg-red-900/60' : 'bg-red-50 text-red-600 hover:bg-red-100'}`}
                    >
                      Revoke
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>

          <div className="border rounded-lg p-6" style={cardStyle}>
            <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
              Provider API Keys
            </h3>
            <p className={`text-sm mb-4 ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
              Configure your own LLM provider credentials. Agent runs and evaluations on this
              account use these instead of the platform defaults. Keys are encrypted at rest.
            </p>
            <div className="space-y-4">
              {providerKeys.map(({ provider, host_based: hostBased, configured, hint }) => {
                const meta = PROVIDER_META[provider] || { label: provider, icon: '🔑', placeholder: '' };
                const editing = editingProvider === provider;
                return (
                  <div key={provider} className="p-4 rounded-lg" style={{ backgroundColor: darkMode ? '#252525' : '#f9fafb' }}>
                    <div className="flex items-center justify-between">
                      <div className="flex items-center space-x-3">
                        <span className="text-xl">{meta.icon}</span>
                        <div>
                          <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>{meta.label}</p>
                          <p className={`text-sm ${configured ? (darkMode ? 'text-green-400' : 'text-green-600') : (darkMode ? 'text-gray-400' : 'text-gray-500')}`}>
                            {configured ? (hostBased ? hint : `Configured (${hint})`) : 'Not configured'}
                          </p>
                        </div>
                      </div>
                      <div className="flex items-center space-x-2">
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
                            setProviderInput('');
                          }}
                          className={`px-3 py-1 text-sm rounded ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`}
                        >
                          {editing ? 'Cancel' : configured ? 'Update' : 'Configure'}
                        </button>
                      </div>
                    </div>
                    {editing && (
                      <div className="mt-3 flex items-center space-x-2">
                        <input
                          type={hostBased ? 'text' : 'password'}
                          value={providerInput}
                          onChange={(e) => setProviderInput(e.target.value)}
                          onKeyDown={(e) => e.key === 'Enter' && saveProviderKey(provider)}
                          placeholder={hostBased ? meta.placeholder : `${meta.label} API key (${meta.placeholder})`}
                          autoFocus
                          className={`flex-1 px-3 py-2 border rounded-lg text-sm font-mono ${
                            darkMode
                              ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500'
                              : 'bg-white border-gray-300 text-gray-900'
                          }`}
                        />
                        <button
                          onClick={() => saveProviderKey(provider)}
                          disabled={!providerInput.trim() || savingProvider}
                          className="px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600 disabled:opacity-50 text-sm"
                        >
                          {savingProvider ? 'Saving…' : 'Save'}
                        </button>
                      </div>
                    )}
                    {hostBased && editing && (
                      <p className={`mt-2 text-xs ${darkMode ? 'text-gray-500' : 'text-gray-400'}`}>
                        URL of your Ollama server's OpenAI-compatible endpoint. For a locally
                        running Ollama use http://localhost:11434/v1 (the hosted platform needs a
                        publicly reachable URL, e.g. a tunnel).
                      </p>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      )}

      {/* Notifications Tab */}
      {activeTab === 'notifications' && (
        <div className="border rounded-lg p-6" style={cardStyle}>
          <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
            Email Notifications
          </h3>
          <div className="space-y-4">
            {[
              { label: 'Agent execution alerts', desc: 'Get notified when agents fail or complete', enabled: true },
              { label: 'Weekly usage reports', desc: 'Summary of traces, costs, and performance', enabled: true },
              { label: 'Security alerts', desc: 'Important security notifications', enabled: true },
              { label: 'Product updates', desc: 'New features and improvements', enabled: false },
            ].map((item, i) => (
              <div key={i} className="flex items-center justify-between py-3 border-b" style={{ borderColor: darkMode ? '#2a2a2a' : '#e5e7eb' }}>
                <div>
                  <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>{item.label}</p>
                  <p className={`text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>{item.desc}</p>
                </div>
                <button className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                  item.enabled ? 'bg-red-500' : (darkMode ? 'bg-gray-700' : 'bg-gray-300')
                }`}>
                  <span className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                    item.enabled ? 'translate-x-6' : 'translate-x-1'
                  }`} />
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Billing Tab */}
      {activeTab === 'billing' && (
        <div className="space-y-6">
          <div className="border rounded-lg p-6" style={cardStyle}>
            <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
              Subscription
            </h3>
            <div className="flex items-center justify-between p-4 rounded-lg" style={{ backgroundColor: darkMode ? '#252525' : '#f9fafb' }}>
              <div>
                <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>Free Plan</p>
                <p className={`text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>Current plan</p>
              </div>
              <button className="px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600">
                Upgrade to Pro
              </button>
            </div>
          </div>

          <div className="border rounded-lg p-6" style={cardStyle}>
            <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
              Payment Method
            </h3>
            <p className={`${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
              No payment method on file
            </p>
            <button className={`mt-4 px-4 py-2 rounded-lg ${
              darkMode ? 'bg-gray-700 text-gray-300' : 'bg-gray-200 text-gray-700'
            }`}>
              Add Payment Method
            </button>
          </div>

          <div className="border rounded-lg p-6" style={cardStyle}>
            <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
              Invoices
            </h3>
            <p className={`${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
              No invoices yet
            </p>
          </div>
        </div>
      )}
    </div>
  );
}
