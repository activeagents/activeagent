import React, { useState, useRef, useEffect } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { ICONS } from '../../utils/designTokens';
import { dashboardNavSections } from '../../utils/dashboardRoutes.mjs';
import { MONO } from './primitives';

// The dashboard's one navigation surface: the workspace button, which opens
// the account menu, then every destination as a flat list with Settings
// pinned at the bottom. features: what the server enabled on this dashboard
// (dashboardFeatures); a view it turned off has no nav item.
// pendingInputCount: the requests for input waiting for an answer, undefined
// when none are. agentCount is accepted so callers need not change, but the
// count lives in the Agents page title now, not beside the nav item.
export default function Sidebar({ currentView, onNavigate, agentCount, pendingInputCount, account, user, gemVersion, features = {} }) {
  const { darkMode, toggleDarkMode } = useTheme();
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
  // The first letters of the account's first two words, so a workspace reads
  // as a two-letter key the way an agent's avatar does.
  const initials = accountName.split(/\s+/).filter(Boolean).slice(0, 2).map((word) => word[0].toUpperCase()).join('');
  // The line under the workspace name: whoever is signed in, when the host
  // told us; nothing otherwise, rather than a placeholder.
  const userLine = user?.name || user?.email;

  // Sign-out belongs to the host app: the engine has no session of its own,
  // so the path comes from ActionAgent.sign_out_path (published in the meta
  // blob) and the menu item is hidden when the host configured none. The
  // extracted copy posted to the platform's /session, which 404s on any
  // other host.
  const signOutPath = window.ACTIVE_AGENT_DASHBOARD?.meta?.signOutPath;

  const handleSignOut = () => {
    if (!signOutPath) return;

    // Get CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;

    // Create and submit a form to sign out
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = signOutPath;

    const methodInput = document.createElement('input');
    methodInput.type = 'hidden';
    methodInput.name = '_method';
    methodInput.value = 'delete';
    form.appendChild(methodInput);

    const csrfInput = document.createElement('input');
    csrfInput.type = 'hidden';
    csrfInput.name = 'authenticity_token';
    csrfInput.value = csrfToken;
    form.appendChild(csrfInput);

    document.body.appendChild(form);
    form.submit();
  };

  const badges = { pendingInputCount };
  const badgeFor = (item) => {
    const value = item.badge ? badges[item.badge] : undefined;
    return item.badgeTone === 'attention' && !value ? undefined : value;
  };
  const sections = dashboardNavSections(features).map((section) => ({
    ...section,
    items: section.items.map((item) => ({
      id: item.view,
      label: item.label,
      icon: item.glyph ?? ICONS.nav[item.icon],
      badge: badgeFor(item),
      badgeTone: item.badgeTone,
      badgeTitle: item.badgeTitle,
    })),
  }));

  // The hover tint is set by hand: an inline background on the current item
  // would win over a :hover rule, so the rule would have to know which item
  // is current.
  const NavButton = ({ item }) => {
    const current = currentView === item.id;
    return (
      <button
        type="button"
        onClick={() => onNavigate(item.id)}
        aria-current={current ? 'page' : undefined}
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          width: '100%',
          minHeight: 36,
          padding: '0 10px',
          border: 0,
          borderRadius: 8,
          textAlign: 'left',
          cursor: 'pointer',
          fontFamily: 'inherit',
          fontSize: 13,
          fontWeight: 500,
          background: current ? 'var(--color-accent-ui-tint)' : 'transparent',
          color: current ? 'var(--color-accent-ui)' : 'var(--color-text-cell)',
        }}
        onMouseEnter={(e) => {
          if (!current) e.currentTarget.style.background = 'var(--color-hover)';
        }}
        onMouseLeave={(e) => {
          if (!current) e.currentTarget.style.background = 'transparent';
        }}
      >
        <span
          aria-hidden="true"
          style={{
            fontFamily: MONO,
            fontSize: 12,
            width: 22,
            flexShrink: 0,
            color: current ? 'var(--color-accent-ui)' : 'var(--color-text-dim)',
          }}
        >
          {item.icon}
        </span>
        <span style={{ flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{item.label}</span>
        {item.badge !== undefined && item.badgeTone === 'attention' && (
          <span
            data-testid={`nav-badge-${item.id}`}
            className="px-2 py-0.5 text-xs rounded-full font-semibold"
            title={`${item.badge} ${item.badgeTitle || ''}`.trim()}
            aria-label={`${item.badge} ${item.badgeTitle || ''}`.trim()}
            style={{ backgroundColor: 'var(--color-warning-soft)', color: 'var(--color-warning-text)' }}
          >
            {item.badge}
          </span>
        )}
        {item.badge !== undefined && item.badgeTone !== 'attention' && (
          <span
            className="px-2 py-0.5 text-xs rounded-full"
            style={{
              fontFamily: MONO,
              backgroundColor: current ? 'var(--color-accent-ui-muted)' : 'var(--color-muted)',
              color: current ? 'var(--color-accent-ui)' : 'var(--color-text-cell)',
            }}
          >
            {item.badge}
          </span>
        )}
      </button>
    );
  };

  // One row of the account menu: text only, the hover tint from the
  // aa-menu-item rule in tokens.css.
  const menuItemStyle = {
    display: 'flex',
    alignItems: 'center',
    gap: 10,
    width: '100%',
    boxSizing: 'border-box',
    padding: '7px 10px',
    border: 0,
    borderRadius: 6,
    background: 'transparent',
    color: 'var(--color-text-primary)',
    fontFamily: 'inherit',
    fontSize: 13,
    textAlign: 'left',
    textDecoration: 'none',
    cursor: 'pointer',
  };
  const closeAnd = (action) => () => {
    setShowAccountMenu(false);
    action();
  };
  const divider = { borderTop: '1px solid var(--color-border-light)', margin: '4px 0' };

  return (
    <aside
      style={{
        width: 220,
        flexShrink: 0,
        boxSizing: 'border-box',
        padding: '16px 12px',
        background: 'var(--color-surface)',
        borderRight: '1px solid var(--color-border)',
        display: 'flex',
        flexDirection: 'column',
        gap: 4,
      }}
    >
      {/* The workspace button and the account menu it opens. */}
      <div ref={menuRef} style={{ position: 'relative', marginBottom: 12 }}>
        <button
          type="button"
          aria-label="Workspace menu"
          aria-haspopup="menu"
          aria-expanded={showAccountMenu}
          onClick={() => setShowAccountMenu(!showAccountMenu)}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            width: '100%',
            minHeight: 44,
            boxSizing: 'border-box',
            padding: '6px 10px',
            border: '1px solid var(--color-border)',
            borderRadius: 10,
            background: showAccountMenu ? 'var(--color-hover)' : 'var(--color-card)',
            color: 'var(--color-text-primary)',
            fontFamily: 'inherit',
            textAlign: 'left',
            cursor: 'pointer',
          }}
        >
          <span
            aria-hidden="true"
            style={{
              width: 24,
              height: 24,
              flexShrink: 0,
              borderRadius: 6,
              background: 'var(--color-accent-ui)',
              color: 'var(--color-on-accent)',
              fontFamily: MONO,
              fontSize: 12,
              fontWeight: 500,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            {initials}
          </span>
          <span style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column' }}>
            <span style={{ fontSize: 13, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {accountName}
            </span>
            {userLine && (
              <span style={{ fontSize: 11, color: 'var(--color-text-muted)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {userLine}
              </span>
            )}
          </span>
          <svg
            className={`w-4 h-4 flex-shrink-0 transition-transform ${showAccountMenu ? 'rotate-180' : ''}`}
            style={{ color: 'var(--color-text-muted)' }}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-hidden="true"
          >
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>

        {showAccountMenu && (
          <div
            role="menu"
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              top: 'calc(100% + 4px)',
              zIndex: 50,
              padding: 4,
              background: 'var(--color-surface)',
              border: '1px solid var(--color-border)',
              borderRadius: 10,
              boxShadow: 'var(--shadow-popover)',
            }}
          >
            <div style={{ padding: '8px 10px 10px', borderBottom: '1px solid var(--color-border-light)', marginBottom: 4 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {accountName}
              </div>
              {userLine && (
                <div style={{ fontSize: 12, color: 'var(--color-text-muted)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {[user?.name, user?.email].filter(Boolean).join(' · ')}
                </div>
              )}
            </div>

            {/* The theme row stays open after a toggle so the state glyph can
                be seen flipping; it is a setting, not a destination. */}
            <button
              type="button"
              role="menuitemcheckbox"
              aria-checked={darkMode}
              className="aa-menu-item"
              onClick={toggleDarkMode}
              style={menuItemStyle}
            >
              <span aria-hidden="true" style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-dim)' }}>{darkMode ? '[x]' : '[ ]'}</span>
              <span>Dark mode</span>
            </button>
            <button type="button" role="menuitem" className="aa-menu-item" onClick={closeAnd(() => onNavigate('organization'))} style={menuItemStyle}>
              Organization
            </button>
            <button type="button" role="menuitem" className="aa-menu-item" onClick={closeAnd(() => onNavigate('settings'))} style={menuItemStyle}>
              Settings
            </button>

            <div style={divider} />
            <a
              role="menuitem"
              className="aa-menu-item"
              href="https://docs.activeagents.ai"
              target="_blank"
              rel="noopener noreferrer"
              onClick={() => setShowAccountMenu(false)}
              style={menuItemStyle}
            >
              Documentation
            </a>
            <a
              role="menuitem"
              className="aa-menu-item"
              href="https://github.com/activeagents/activeagent"
              target="_blank"
              rel="noopener noreferrer"
              onClick={() => setShowAccountMenu(false)}
              style={menuItemStyle}
            >
              GitHub
            </a>

            {signOutPath && (
              <>
                <div style={divider} />
                <button type="button" role="menuitem" className="aa-menu-item" onClick={closeAnd(handleSignOut)} style={menuItemStyle}>
                  Sign out
                </button>
              </>
            )}

            <div style={{ padding: '8px 10px 4px', marginTop: 4, borderTop: '1px solid var(--color-border-light)', fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' }}>
              Active Agent{gemVersion ? ` v${gemVersion}` : ''}
            </div>
          </div>
        )}
      </div>

      {/* Destinations, then a spacer that pins the workspace section to the
          bottom. No section has a heading. */}
      <nav aria-label="Main" style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4 }}>
        {sections.map((section, index) => (
          <React.Fragment key={section.id}>
            {index > 0 && <div aria-hidden="true" style={{ flex: 1, minHeight: 24 }} />}
            {section.items.map((item) => (
              <NavButton key={item.id} item={item} />
            ))}
          </React.Fragment>
        ))}
      </nav>
    </aside>
  );
}
