import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import GithubIntegrationCard from './GithubIntegrationCard';
import ClaudeCodeIntegrationCard from './ClaudeCodeIntegrationCard';
import CodexIntegrationCard from './CodexIntegrationCard';
import ProviderKeysCard, { useProviderKeyEditor } from './ProviderKeysCard';
import { providerKeysPath } from '../../utils/providerKeys.mjs';
import { PageHeader, Tabs, Button, MONO } from './primitives';

// The tab ids outlive their labels, so ?tab=profile still opens Appearance.
const TABS = [
  { id: 'profile', label: 'Appearance' },
  { id: 'api-keys', label: 'API Keys' },
  { id: 'integrations', label: 'Integrations' },
];

const TAB_IDS = TABS.map((tab) => tab.id);

// ?tab=… opens a tab directly; the GitHub OAuth callback lands on
// ?tab=integrations&github=<outcome>, and the GitHub App installation and
// manifest callbacks on ?tab=integrations&github_app=<outcome>.
function initialQuery() {
  const query = new URLSearchParams(window.location.search);
  const tab = query.get('tab');
  return { tab: TAB_IDS.includes(tab) ? tab : 'profile', github: query.get('github'), githubApp: query.get('github_app') };
}

const cardStyle = { backgroundColor: 'var(--color-card)', borderColor: 'var(--color-border)' };
const heading = { color: 'var(--color-text-primary)' };
const secondary = { color: 'var(--color-text-secondary)' };
const fieldStyle = {
  padding: '8px 12px', borderRadius: 8, fontSize: 13, fontFamily: 'inherit',
  background: 'var(--color-surface)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)',
};

export default function SettingsView() {
  const { darkMode, toggleDarkMode } = useTheme();
  // With personal keys on, the API Keys tab manages the signed-in user's own
  // provider keys; the organization's are on the Organization page.
  const [providerKeyScope] = useState(() => (window.ACTIVE_AGENT_DASHBOARD?.meta?.personalProviderKeys ? 'personal' : undefined));
  const [{ tab: firstTab, github: githubCallback, githubApp: githubAppCallback }] = useState(initialQuery);
  const [activeTab, setActiveTab] = useState(firstTab);
  // Bumped when the Claude Code card changes, so the GitHub card re-reads
  // whether sandboxes can run Claude Code sessions.
  const [integrationsVersion, setIntegrationsVersion] = useState(0);

  // API Keys tab state
  const [apiKeys, setApiKeys] = useState([]);
  const [providerKeys, setProviderKeys] = useState([]);
  const [keysLoaded, setKeysLoaded] = useState(false);
  const [newKeyName, setNewKeyName] = useState('');
  const [creatingKey, setCreatingKey] = useState(false);
  const [createdKey, setCreatedKey] = useState(null); // { name, token } shown once
  const [copied, setCopied] = useState(false);
  // Shown in the API Keys card, for its own failures and the provider keys
  // card's.
  const [keysError, setKeysError] = useState(null);

  const loadKeys = useCallback(async () => {
    try {
      const [keysRes, providersRes] = await Promise.all([
        fetch('/api/api_keys'),
        fetch(providerKeysPath('/api/provider_keys', providerKeyScope)),
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
  }, [providerKeyScope]);

  useEffect(() => {
    if (activeTab === 'api-keys' && !keysLoaded) loadKeys();
  }, [activeTab, keysLoaded, loadKeys]);

  const providerKeyEditor = useProviderKeyEditor({ onKeysChanged: loadKeys, onError: setKeysError, scope: providerKeyScope });

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

  const copyToken = async (token) => {
    try {
      await navigator.clipboard.writeText(token);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch (e) {
      // Clipboard unavailable (e.g. insecure context); the token stays visible for manual copy.
    }
  };

  return (
    <div className="space-y-6">
      <PageHeader title="Settings" />

      <Tabs tabs={TABS} active={activeTab} onChange={setActiveTab} ariaLabel="Settings sections" />

      {/* Appearance Tab */}
      {activeTab === 'profile' && (
        <div className="border rounded-lg p-6" style={cardStyle}>
          <div className="flex items-center justify-between gap-4">
            <div>
              <p className="font-medium" style={heading}>Dark Mode</p>
              <p className="text-sm" style={secondary}>Use dark theme across the dashboard</p>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={darkMode}
              aria-label="Dark mode"
              onClick={toggleDarkMode}
              className="relative inline-flex h-6 w-11 items-center rounded-full transition-colors"
              style={{ background: darkMode ? 'var(--color-accent-ui)' : 'var(--color-border-strong)', border: 0, padding: 0, cursor: 'pointer' }}
            >
              <span
                className={`inline-block h-4 w-4 transform rounded-full transition-transform ${darkMode ? 'translate-x-6' : 'translate-x-1'}`}
                style={{ background: 'var(--color-on-accent)' }}
              />
            </button>
          </div>
        </div>
      )}

      {/* API Keys Tab */}
      {activeTab === 'api-keys' && (
        <div className="space-y-6">
          <div className="border rounded-lg p-6" style={cardStyle}>
            <div className="flex items-center justify-between gap-4 flex-wrap mb-4">
              <h3 className="text-lg font-semibold" style={heading}>
                API Keys
              </h3>
              <div className="flex items-center gap-2">
                <label htmlFor="settings-new-key-name" className="sr-only">Key name</label>
                <input
                  id="settings-new-key-name"
                  type="text"
                  value={newKeyName}
                  onChange={(e) => setNewKeyName(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && createApiKey()}
                  placeholder="Key name (e.g. production)"
                  style={fieldStyle}
                />
                <Button variant="primary" onClick={createApiKey} disabled={!newKeyName.trim() || creatingKey}>
                  {creatingKey ? 'Creating…' : '+ Create New Key'}
                </Button>
              </div>
            </div>

            <p className="text-sm mb-4" style={{ color: 'var(--color-text-muted)' }}>
              API keys are secrets. Never share them or commit them to version control.
            </p>

            {keysError && (
              <div className="text-sm mb-4" style={{ padding: '12px 14px', borderRadius: 8, background: 'var(--color-error-soft)', border: '1px solid var(--color-error)', color: 'var(--color-error-text)' }}>
                {keysError}
              </div>
            )}

            {createdKey && (
              <div className="mb-4" style={{ padding: '12px 14px', borderRadius: 8, background: 'var(--color-success-soft)', border: '1px solid var(--color-success)' }}>
                <p className="text-sm font-medium mb-2" style={{ color: 'var(--color-success-text)' }}>
                  Key “{createdKey.name}” created. Copy it now — it won't be shown again.
                </p>
                <div className="flex items-center gap-2">
                  <code
                    data-aa-secret=""
                    className="flex-1 px-3 py-2 text-sm break-all"
                    style={{ fontFamily: MONO, borderRadius: 6, background: 'var(--color-surface)', border: '1px solid var(--color-border)', color: 'var(--color-text-primary)' }}
                  >
                    {createdKey.token}
                  </code>
                  <Button size="sm" onClick={() => copyToken(createdKey.token)}>
                    {copied ? 'Copied!' : 'Copy'}
                  </Button>
                  <Button variant="ghost" size="sm" onClick={() => setCreatedKey(null)}>
                    Dismiss
                  </Button>
                </div>
              </div>
            )}

            {apiKeys.length === 0 ? (
              <div className="text-center py-8" style={{ color: 'var(--color-text-muted)' }}>
                <p>{keysLoaded ? 'No API keys yet' : 'Loading…'}</p>
                {keysLoaded && <p className="text-sm">Create your first API key to authenticate requests</p>}
              </div>
            ) : (
              <div className="space-y-2">
                {apiKeys.map((key) => (
                  <div
                    key={key.id}
                    className="flex items-center justify-between gap-4 p-4 rounded-lg"
                    style={{ backgroundColor: 'var(--color-muted)' }}
                  >
                    <div className="min-w-0">
                      <p className="font-medium" style={heading}>{key.name}</p>
                      <p className="text-sm" style={{ fontFamily: MONO, ...secondary }}>
                        {key.masked_token}
                        <span style={{ fontFamily: 'var(--font-text)' }}>
                          {' · created '}{new Date(key.created_at).toLocaleDateString()}
                          {key.last_used_at
                            ? ` · last used ${new Date(key.last_used_at).toLocaleDateString()}`
                            : ' · never used'}
                        </span>
                      </p>
                    </div>
                    <Button variant="danger" size="sm" onClick={() => revokeApiKey(key.id)}>
                      Revoke
                    </Button>
                  </div>
                ))}
              </div>
            )}
          </div>

          <ProviderKeysCard providerKeys={providerKeys} editor={providerKeyEditor} scope={providerKeyScope} />
        </div>
      )}

      {/* Integrations Tab */}
      {activeTab === 'integrations' && (
        <div className="space-y-6">
          <div className="border rounded-lg p-6" style={cardStyle}>
            <h3 className="text-lg font-semibold mb-1" style={heading}>
              Integrations
            </h3>
            <p className="text-sm mb-4" style={secondary}>
              Connect GitHub to choose which repositories this workspace may use. A sandbox started
              from one boots that app's own runtime, so agents and evaluations can run with its tools,
              and Claude Code or Codex can work on the checkout.
            </p>
            <GithubIntegrationCard callbackStatus={githubCallback} appCallbackStatus={githubAppCallback} refreshKey={integrationsVersion} />
          </div>
          <div className="border rounded-lg p-6" style={cardStyle}>
            <ClaudeCodeIntegrationCard onChange={() => setIntegrationsVersion((v) => v + 1)} />
          </div>
          <div className="border rounded-lg p-6" style={cardStyle}>
            <CodexIntegrationCard onChange={() => setIntegrationsVersion((v) => v + 1)} />
          </div>
        </div>
      )}
    </div>
  );
}
