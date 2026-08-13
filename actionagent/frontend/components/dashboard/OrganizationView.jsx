import React, { useState, useEffect } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { startCheckout } from '../../utils/checkout';

const formatNumber = (num) => {
  if (num == null) return '0';
  if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
  if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
  return num.toString();
};

export default function OrganizationView({ account, user, subscription, agentCount = 0 }) {
  const { darkMode } = useTheme();
  const [usage, setUsage] = useState(null);
  const [keyCopied, setKeyCopied] = useState(false);
  const [showKey, setShowKey] = useState(false);
  const [isUpgrading, setIsUpgrading] = useState(false);
  const [upgradeError, setUpgradeError] = useState(null);

  useEffect(() => {
    fetch('/api/usage')
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => setUsage(data?.usage || null))
      .catch(() => setUsage(null));
  }, []);

  const handleUpgrade = async () => {
    setIsUpgrading(true);
    setUpgradeError(null);
    try {
      await startCheckout({ planSlug: 'pro' });
    } catch (err) {
      setUpgradeError(err.message);
      setIsUpgrading(false);
    }
  };

  const copyKey = () => {
    if (!account?.telemetry_api_key) return;
    navigator.clipboard.writeText(account.telemetry_api_key).then(() => {
      setKeyCopied(true);
      setTimeout(() => setKeyCopied(false), 2000);
    });
  };

  const cardStyle = {
    backgroundColor: darkMode ? '#1f1f1f' : '#ffffff',
    borderColor: darkMode ? '#2a2a2a' : '#e5e7eb',
  };

  const planName = subscription?.plan_name || 'Free';
  const planFeatures = {
    free: {
      seats: 1,
      workspaces: 1,
      agents: 3,
      traces: '250/mo trial',
    },
    pro: {
      seats: 5,
      workspaces: 3,
      agents: 'Unlimited',
      traces: '25,000/mo',
    },
    enterprise: {
      seats: 'Unlimited',
      workspaces: 'Unlimited',
      agents: 'Unlimited',
      traces: '500,000+/mo',
    },
  };

  const features = planFeatures[planName.toLowerCase()] || planFeatures.free;

  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div>
        <h2 className={`text-2xl font-bold ${darkMode ? 'text-white' : 'text-gray-900'}`}>
          Organization
        </h2>
        <p className={`mt-1 ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
          Manage your workspace, team, and billing
        </p>
      </div>

      {/* Account Overview */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {/* Workspace Info */}
        <div className="border rounded-lg p-6" style={cardStyle}>
          <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
            Workspace
          </h3>
          <div className="space-y-3">
            <div className="flex justify-between items-center">
              <span className={darkMode ? 'text-gray-400' : 'text-gray-500'}>Name</span>
              <span className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                {account?.name || "My Workspace"}
              </span>
            </div>
            <div className="flex justify-between items-center">
              <span className={darkMode ? 'text-gray-400' : 'text-gray-500'}>Owner</span>
              <span className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                {user?.email || "you@example.com"}
              </span>
            </div>
            <div className="flex justify-between items-center">
              <span className={darkMode ? 'text-gray-400' : 'text-gray-500'}>Created</span>
              <span className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                {account?.created_at ? new Date(account.created_at).toLocaleDateString() : 'Today'}
              </span>
            </div>
          </div>
        </div>

        {/* Current Plan */}
        <div className="border rounded-lg p-6" style={cardStyle}>
          <div className="flex items-center justify-between mb-4">
            <h3 className={`text-lg font-semibold ${darkMode ? 'text-white' : 'text-gray-900'}`}>
              Current Plan
            </h3>
            <span className="px-3 py-1 bg-red-100 text-red-700 rounded-full text-sm font-medium">
              {planName}
            </span>
          </div>
          <div className="space-y-3">
            <div className="flex justify-between items-center">
              <span className={darkMode ? 'text-gray-400' : 'text-gray-500'}>Team Seats</span>
              <span className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                {features.seats}
              </span>
            </div>
            <div className="flex justify-between items-center">
              <span className={darkMode ? 'text-gray-400' : 'text-gray-500'}>Workspaces</span>
              <span className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                {features.workspaces}
              </span>
            </div>
            <div className="flex justify-between items-center">
              <span className={darkMode ? 'text-gray-400' : 'text-gray-500'}>Agents</span>
              <span className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                {features.agents}
              </span>
            </div>
            <div className="flex justify-between items-center">
              <span className={darkMode ? 'text-gray-400' : 'text-gray-500'}>Traces</span>
              <span className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                {features.traces}
              </span>
            </div>
          </div>
          {planName.toLowerCase() !== 'enterprise' && (
            <>
              <button
                onClick={handleUpgrade}
                disabled={isUpgrading}
                className="mt-4 w-full px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {isUpgrading ? 'Redirecting to checkout…' : 'Upgrade Plan'}
              </button>
              {upgradeError && (
                <p className="mt-2 text-sm text-red-500 text-center">{upgradeError}</p>
              )}
            </>
          )}
        </div>
      </div>

      {/* Team Members */}
      <div className="border rounded-lg p-6" style={cardStyle}>
        <div className="flex items-center justify-between mb-4">
          <h3 className={`text-lg font-semibold ${darkMode ? 'text-white' : 'text-gray-900'}`}>
            Team Members
          </h3>
          <button className="px-4 py-2 text-sm bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 transition-colors">
            + Invite Member
          </button>
        </div>
        <div className="overflow-hidden">
          <table className="min-w-full">
            <thead>
              <tr className={darkMode ? 'border-b border-gray-700' : 'border-b border-gray-200'}>
                <th className={`text-left py-3 px-4 text-sm font-medium ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
                  Member
                </th>
                <th className={`text-left py-3 px-4 text-sm font-medium ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
                  Role
                </th>
                <th className={`text-left py-3 px-4 text-sm font-medium ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
                  Status
                </th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td className="py-3 px-4">
                  <div className="flex items-center space-x-3">
                    <div className="w-8 h-8 bg-red-100 rounded-full flex items-center justify-center">
                      <span className="text-red-600 font-medium text-sm">
                        {user?.name?.charAt(0).toUpperCase() || 'U'}
                      </span>
                    </div>
                    <div>
                      <p className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                        {user?.name || 'You'}
                      </p>
                      <p className={`text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
                        {user?.email}
                      </p>
                    </div>
                  </div>
                </td>
                <td className="py-3 px-4">
                  <span className="px-2 py-1 bg-purple-100 text-purple-700 rounded text-sm">
                    Owner
                  </span>
                </td>
                <td className="py-3 px-4">
                  <span className="flex items-center text-green-600">
                    <span className="w-2 h-2 bg-green-500 rounded-full mr-2"></span>
                    Active
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      {/* Usage Stats */}
      <div className="border rounded-lg p-6" style={cardStyle}>
        <h3 className={`text-lg font-semibold mb-4 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
          Usage This Month
        </h3>
        <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
          <div className="text-center p-4 rounded-lg" style={{ backgroundColor: darkMode ? '#252525' : '#f9fafb' }}>
            <p className={`text-2xl font-bold ${darkMode ? 'text-white' : 'text-gray-900'}`}>{agentCount}</p>
            <p className={`text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>Agents</p>
          </div>
          <div className="text-center p-4 rounded-lg" style={{ backgroundColor: darkMode ? '#252525' : '#f9fafb' }}>
            <p className={`text-2xl font-bold ${darkMode ? 'text-white' : 'text-gray-900'}`}>
              {formatNumber(usage?.traces_used)}
              {usage?.traces_limit > 0 && (
                <span className={`text-sm font-normal ${darkMode ? 'text-gray-500' : 'text-gray-400'}`}> / {formatNumber(usage.traces_limit)}</span>
              )}
            </p>
            <p className={`text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>Traces</p>
          </div>
          <div className="text-center p-4 rounded-lg" style={{ backgroundColor: darkMode ? '#252525' : '#f9fafb' }}>
            <p className={`text-2xl font-bold ${darkMode ? 'text-white' : 'text-gray-900'}`}>{formatNumber(usage?.runs_used)}</p>
            <p className={`text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>Executions</p>
          </div>
          <div className="text-center p-4 rounded-lg" style={{ backgroundColor: darkMode ? '#252525' : '#f9fafb' }}>
            <p className={`text-2xl font-bold ${darkMode ? 'text-white' : 'text-gray-900'}`}>{formatNumber(usage?.tokens_used)}</p>
            <p className={`text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>Tokens</p>
          </div>
        </div>
      </div>

      {/* Telemetry Ingestion */}
      <div className="border rounded-lg p-6" style={cardStyle}>
        <h3 className={`text-lg font-semibold mb-1 ${darkMode ? 'text-white' : 'text-gray-900'}`}>
          Telemetry
        </h3>
        <p className={`text-sm mb-4 ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
          Send traces from your own ActiveAgent app to this workspace. Add this to your{' '}
          <code className={`px-1 rounded text-xs ${darkMode ? 'bg-gray-800 text-gray-300' : 'bg-gray-100 text-gray-700'}`}>config/active_agent.yml</code>:
        </p>
        <pre
          className={`text-xs rounded-lg p-4 overflow-x-auto mb-4 ${darkMode ? 'bg-black text-gray-300' : 'bg-gray-900 text-gray-100'}`}
        >
{`telemetry:
  enabled: true
  endpoint: ${window.location.origin}/v1/traces
  api_key: <%= ENV["ACTIVEAGENTS_API_KEY"] %>`}
        </pre>
        <div className="flex items-center justify-between gap-3">
          <div className="min-w-0 flex-1">
            <p className={`text-xs uppercase tracking-wide mb-1 ${darkMode ? 'text-gray-500' : 'text-gray-400'}`}>API Key</p>
            <code
              className={`block truncate text-sm font-mono px-3 py-2 rounded-lg border ${
                darkMode ? 'bg-gray-900 border-gray-700 text-gray-300' : 'bg-gray-50 border-gray-200 text-gray-700'
              }`}
            >
              {account?.telemetry_api_key
                ? (showKey ? account.telemetry_api_key : '•'.repeat(24))
                : 'Not available'}
            </code>
          </div>
          <div className="flex gap-2 flex-shrink-0 self-end">
            <button
              onClick={() => setShowKey(!showKey)}
              className="px-3 py-2 text-sm bg-gray-100 text-gray-700 rounded-lg hover:bg-gray-200 transition-colors"
            >
              {showKey ? 'Hide' : 'Show'}
            </button>
            <button
              onClick={copyKey}
              className="px-3 py-2 text-sm bg-red-500 text-white rounded-lg hover:bg-red-600 transition-colors"
            >
              {keyCopied ? 'Copied!' : 'Copy'}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
