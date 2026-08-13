import React, { useState, useRef, useEffect } from 'react';
import AgentAvatar from '../AgentAvatar';
import { useTheme } from '../../contexts/ThemeContext';
import { ICONS, TYPOGRAPHY } from '../../utils/designTokens';

export default function Sidebar({ currentView, onNavigate, agentCount, account, user, gemVersion }) {
  const { darkMode } = useTheme();
  const [showAccountMenu, setShowAccountMenu] = useState(false);
  const menuRef = useRef(null);

  // Close menu when clicking outside
  useEffect(() => {
    function handleClickOutside(event) {
      if (menuRef.current && !menuRef.current.contains(event.target)) {
        setShowAccountMenu(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const accountName = account?.name || 'My Workspace';
  const userName = user?.name || user?.email?.split('@')[0] || 'User';

  const agentItems = [
    { id: 'list', label: 'Agents', icon: ICONS.nav.agents, badge: agentCount },
    { id: 'builder', label: 'New Agent', icon: ICONS.nav.newAgent },
    { id: 'sandbox', label: 'Run Agents', icon: ICONS.nav.demo, highlight: true },
  ];

  const observabilityItems = [
    { id: 'traces', label: 'Traces', icon: ICONS.nav.traces },
    { id: 'interactions', label: 'Interactions', icon: ICONS.nav.interactions },
    { id: 'metrics', label: 'Metrics', icon: ICONS.nav.metrics },
    { id: 'evaluations', label: 'Evaluations', icon: ICONS.nav.evaluations },
    { id: 'replay', label: 'Session Replay', icon: ICONS.nav.replay },
  ];

  const workspaceItems = [
    { id: 'organization', label: 'Organization', icon: '🏢' },
    { id: 'settings', label: 'Settings', icon: '⚙️' },
  ];

  const NavButton = ({ item }) => (
    <button
      onClick={() => onNavigate(item.id)}
      className={`w-full flex items-center justify-between py-3 rounded-lg text-left transition-colors ${
        item.indent ? 'pl-10 pr-4' : 'px-4'
      }`}
      style={{
        backgroundColor: currentView === item.id
          ? (darkMode ? 'rgba(239, 68, 68, 0.15)' : '#fef2f2')
          : 'transparent',
        color: currentView === item.id
          ? '#ef4444'
          : (darkMode ? '#d1d5db' : '#374151')
      }}
      onMouseEnter={(e) => {
        if (currentView !== item.id) {
          e.currentTarget.style.backgroundColor = darkMode ? '#252525' : '#f3f4f6';
        }
      }}
      onMouseLeave={(e) => {
        if (currentView !== item.id) {
          e.currentTarget.style.backgroundColor = 'transparent';
        }
      }}
    >
      <div className="flex items-center space-x-3">
        <span
          style={{
            fontFamily: TYPOGRAPHY.mono,
            fontSize: '12px',
            width: '20px',
            textAlign: 'center',
          }}
        >
          {item.icon}
        </span>
        <span className="font-medium">{item.label}</span>
      </div>
      {item.badge !== undefined && (
        <span
          className="px-2 py-0.5 text-xs rounded-full"
          style={{
            backgroundColor: currentView === item.id
              ? '#fee2e2'
              : (darkMode ? '#2a2a2a' : '#f3f4f6'),
            color: currentView === item.id
              ? '#ef4444'
              : (darkMode ? '#d1d5db' : '#4b5563')
          }}
        >
          {item.badge}
        </span>
      )}
    </button>
  );

  return (
    <aside
      className="w-64 border-r flex flex-col"
      style={{
        backgroundColor: darkMode ? '#1a1a1a' : '#ffffff',
        borderColor: darkMode ? '#2a2a2a' : '#e5e7eb'
      }}
    >
      {/* Account Switcher - Stripe-style */}
      <div
        className="h-16 flex items-center px-4 border-b relative"
        style={{ borderColor: darkMode ? '#2a2a2a' : '#e5e7eb' }}
        ref={menuRef}
      >
        <button
          onClick={() => setShowAccountMenu(!showAccountMenu)}
          className="w-full flex items-center justify-between px-2 py-2 rounded-lg transition-colors"
          style={{
            backgroundColor: showAccountMenu ? (darkMode ? '#252525' : '#f3f4f6') : 'transparent'
          }}
        >
          <div className="flex items-center space-x-3 min-w-0">
            <AgentAvatar size={28} />
            <span className={`font-semibold truncate ${darkMode ? 'text-white' : 'text-gray-900'}`}>
              {accountName}
            </span>
          </div>
          <svg
            className={`w-4 h-4 flex-shrink-0 transition-transform ${showAccountMenu ? 'rotate-180' : ''}`}
            style={{ color: darkMode ? '#9ca3af' : '#6b7280' }}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>

        {/* Account dropdown menu */}
        {showAccountMenu && (
          <div
            className="absolute left-4 right-4 top-14 rounded-lg shadow-lg border overflow-hidden z-50"
            style={{
              backgroundColor: darkMode ? '#1a1a1a' : '#ffffff',
              borderColor: darkMode ? '#2a2a2a' : '#e5e7eb'
            }}
          >
            {/* Account header */}
            <div className="px-4 py-3 border-b" style={{ borderColor: darkMode ? '#2a2a2a' : '#e5e7eb' }}>
              <div className="flex items-center space-x-3">
                <AgentAvatar size={32} />
                <div className="min-w-0">
                  <div className={`font-medium truncate ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                    {accountName}
                  </div>
                </div>
              </div>
            </div>

            {/* Menu items */}
            <div className="py-1">
              <button
                onClick={() => { onNavigate('settings'); setShowAccountMenu(false); }}
                className={`w-full flex items-center space-x-3 px-4 py-2 text-left text-sm transition-colors ${
                  darkMode
                    ? 'text-gray-300 hover:bg-gray-800'
                    : 'text-gray-700 hover:bg-gray-100'
                }`}
              >
                <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                </svg>
                <span>Settings</span>
              </button>

              <button
                onClick={() => { onNavigate('organization'); setShowAccountMenu(false); }}
                className={`w-full flex items-center space-x-3 px-4 py-2 text-left text-sm transition-colors ${
                  darkMode
                    ? 'text-gray-300 hover:bg-gray-800'
                    : 'text-gray-700 hover:bg-gray-100'
                }`}
              >
                <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4" />
                </svg>
                <span>Organization</span>
              </button>
            </div>

            {/* User section */}
            <div className="border-t py-1" style={{ borderColor: darkMode ? '#2a2a2a' : '#e5e7eb' }}>
              <div className={`px-4 py-2 flex items-center space-x-3 ${darkMode ? 'text-gray-300' : 'text-gray-700'}`}>
                <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z" />
                </svg>
                <span className="text-sm">{userName}</span>
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Navigation */}
      <nav className="flex-1 px-4 py-4 space-y-1 overflow-y-auto">
        {/* Agents Section */}
        <div className="space-y-1">
          {agentItems.map((item) => (
            <NavButton key={item.id} item={item} />
          ))}
        </div>

        {/* Observability Section */}
        <div className="pt-4">
          <div className="px-4 pb-2">
            <span className={`text-xs font-semibold uppercase tracking-wide ${
              darkMode ? 'text-gray-500' : 'text-gray-400'
            }`}>Observability</span>
          </div>
          <div className="space-y-1">
            {observabilityItems.map((item) => (
              <NavButton key={item.id} item={item} />
            ))}
          </div>
        </div>

        {/* Workspace Section */}
        <div className="pt-4">
          <div className="px-4 pb-2">
            <span className={`text-xs font-semibold uppercase tracking-wide ${
              darkMode ? 'text-gray-500' : 'text-gray-400'
            }`}>Workspace</span>
          </div>
          <div className="space-y-1">
            {workspaceItems.map((item) => (
              <NavButton key={item.id} item={item} />
            ))}
          </div>
        </div>
      </nav>

      {/* Quick Links */}
      <div className="px-4 py-4 border-t" style={{ borderColor: darkMode ? '#2a2a2a' : '#e5e7eb' }}>
        <div className={`text-xs font-semibold uppercase mb-3 ${
          darkMode ? 'text-gray-500' : 'text-gray-400'
        }`}>Resources</div>
        <div className="space-y-2">
          <a
            href="https://docs.activeagents.ai"
            target="_blank"
            rel="noopener noreferrer"
            className={`flex items-center space-x-2 text-sm transition-colors ${
              darkMode
                ? 'text-gray-400 hover:text-red-400'
                : 'text-gray-600 hover:text-red-600'
            }`}
          >
            <span style={{ fontFamily: TYPOGRAPHY.mono, fontSize: '12px', width: '20px', textAlign: 'center' }}>{ICONS.nav.docs}</span>
            <span>Documentation</span>
          </a>
          <a
            href="https://github.com/activeagents/activeagent"
            target="_blank"
            rel="noopener noreferrer"
            className={`flex items-center space-x-2 text-sm transition-colors ${
              darkMode
                ? 'text-gray-400 hover:text-red-400'
                : 'text-gray-600 hover:text-red-600'
            }`}
          >
            <span style={{ fontFamily: TYPOGRAPHY.mono, fontSize: '12px', width: '20px', textAlign: 'center' }}>{ICONS.nav.github}</span>
            <span>GitHub</span>
          </a>
        </div>
      </div>

      {/* Version */}
      <div className="px-6 py-4 border-t" style={{ borderColor: darkMode ? '#2a2a2a' : '#e5e7eb' }}>
        <div className={`text-xs ${darkMode ? 'text-gray-500' : 'text-gray-400'}`}>
          Active Agent {gemVersion ? `v${gemVersion}` : ''}
        </div>
      </div>
    </aside>
  );
}
