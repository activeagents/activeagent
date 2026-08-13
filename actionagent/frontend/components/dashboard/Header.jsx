import React, { useState, useRef, useEffect } from 'react';
import { useTheme } from '../../contexts/ThemeContext';

export default function Header({ user, account }) {
  const { darkMode, toggleDarkMode } = useTheme();
  const [showUserMenu, setShowUserMenu] = useState(false);
  const menuRef = useRef(null);

  // Close menu when clicking outside
  useEffect(() => {
    function handleClickOutside(event) {
      if (menuRef.current && !menuRef.current.contains(event.target)) {
        setShowUserMenu(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const handleSignOut = () => {
    // Get CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;

    // Create and submit a form to sign out
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = '/session';

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

  const userName = user?.name || user?.email?.split('@')[0] || 'User';
  const userInitial = userName.charAt(0).toUpperCase();

  return (
    <header
      className="h-16 border-b flex items-center justify-between px-6"
      style={{
        backgroundColor: darkMode ? '#1a1a1a' : '#ffffff',
        borderColor: darkMode ? '#2a2a2a' : '#e5e7eb'
      }}
    >
      {/* Left side - can be used for breadcrumbs or search later */}
      <div className="flex items-center space-x-4">
        {/* Placeholder for future search or breadcrumbs */}
      </div>

      {/* Right side - User controls */}
      <div className="flex items-center space-x-4">
        {/* Dark mode toggle */}
        <button
          onClick={toggleDarkMode}
          className="p-2 rounded-lg transition-colors"
          style={{
            backgroundColor: darkMode ? '#252525' : '#f3f4f6',
            color: darkMode ? '#fbbf24' : '#4b5563'
          }}
          title={darkMode ? 'Switch to light mode' : 'Switch to dark mode'}
        >
          {darkMode ? (
            <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
              <path fillRule="evenodd" d="M10 2a1 1 0 011 1v1a1 1 0 11-2 0V3a1 1 0 011-1zm4 8a4 4 0 11-8 0 4 4 0 018 0zm-.464 4.95l.707.707a1 1 0 001.414-1.414l-.707-.707a1 1 0 00-1.414 1.414zm2.12-10.607a1 1 0 010 1.414l-.706.707a1 1 0 11-1.414-1.414l.707-.707a1 1 0 011.414 0zM17 11a1 1 0 100-2h-1a1 1 0 100 2h1zm-7 4a1 1 0 011 1v1a1 1 0 11-2 0v-1a1 1 0 011-1zM5.05 6.464A1 1 0 106.465 5.05l-.708-.707a1 1 0 00-1.414 1.414l.707.707zm1.414 8.486l-.707.707a1 1 0 01-1.414-1.414l.707-.707a1 1 0 011.414 1.414zM4 11a1 1 0 100-2H3a1 1 0 000 2h1z" clipRule="evenodd" />
            </svg>
          ) : (
            <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
              <path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z" />
            </svg>
          )}
        </button>

        {/* Status indicator */}
        <div className={`flex items-center space-x-2 text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
          <span className="w-2 h-2 bg-green-400 rounded-full"></span>
          <span>Connected</span>
        </div>

        {/* User menu */}
        <div className="relative" ref={menuRef}>
          <button
            onClick={() => setShowUserMenu(!showUserMenu)}
            className="flex items-center space-x-2 p-1 rounded-lg transition-colors"
            style={{
              backgroundColor: showUserMenu ? (darkMode ? '#252525' : '#f3f4f6') : 'transparent'
            }}
          >
            <div className="w-8 h-8 bg-red-100 rounded-full flex items-center justify-center">
              <span className="text-red-600 font-medium text-sm">{userInitial}</span>
            </div>
          </button>

          {/* User dropdown menu */}
          {showUserMenu && (
            <div
              className="absolute right-0 mt-2 w-64 rounded-lg shadow-lg border overflow-hidden z-50"
              style={{
                backgroundColor: darkMode ? '#1a1a1a' : '#ffffff',
                borderColor: darkMode ? '#2a2a2a' : '#e5e7eb'
              }}
            >
              {/* User info header */}
              <div className="px-4 py-3 border-b" style={{ borderColor: darkMode ? '#2a2a2a' : '#e5e7eb' }}>
                <div className="flex items-center space-x-3">
                  <div className="w-10 h-10 bg-red-100 rounded-full flex items-center justify-center">
                    <span className="text-red-600 font-medium">{userInitial}</span>
                  </div>
                  <div>
                    <div className={`font-medium ${darkMode ? 'text-white' : 'text-gray-900'}`}>
                      {userName}
                    </div>
                    <div className={`text-sm ${darkMode ? 'text-gray-400' : 'text-gray-500'}`}>
                      {user?.email}
                    </div>
                  </div>
                </div>
              </div>

              {/* Menu items */}
              <div className="py-1">
                <button
                  onClick={handleSignOut}
                  className={`w-full flex items-center space-x-3 px-4 py-2 text-left text-sm transition-colors ${
                    darkMode
                      ? 'text-gray-300 hover:bg-gray-800'
                      : 'text-gray-700 hover:bg-gray-100'
                  }`}
                >
                  <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1" />
                  </svg>
                  <span>Sign out</span>
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
