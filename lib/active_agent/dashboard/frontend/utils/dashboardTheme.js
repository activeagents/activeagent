// Product surface tokens for the dashboard, resolved per theme.
//
// The dashboard views each used to build this object inline. It lives here so
// the agent page and the panels it embeds resolve the same values — a panel
// that keeps its own copy drifts, and an embedded panel that keeps none renders
// light-on-dark inside a themed host.
export const paletteFor = (darkMode) => ({
  cardBg: darkMode ? '#1f1f1f' : '#ffffff',
  cardBorder: darkMode ? '#2a2a2a' : '#e5e7eb',
  borderStrong: darkMode ? 'rgba(255,255,255,0.2)' : '#d1d5db',
  mutedBg: darkMode ? 'rgba(255,255,255,0.06)' : '#f3f4f6',
  innerBg: darkMode ? 'rgba(255,255,255,0.04)' : '#f9fafb',
  textPrimary: darkMode ? '#ffffff' : '#111827',
  textCell: darkMode ? 'rgba(255,255,255,0.75)' : '#4b5563',
  textSecondary: darkMode ? 'rgba(255,255,255,0.6)' : '#6b7280',
  textMuted: darkMode ? 'rgba(255,255,255,0.4)' : '#9ca3af',
  inputBg: darkMode ? 'rgba(255,255,255,0.06)' : '#ffffff',
  inputBorder: darkMode ? 'rgba(255,255,255,0.2)' : '#d1d5db',
  trackBg: darkMode ? 'rgba(255,255,255,0.1)' : '#f3f4f6'
});

export const ACCENT = '#ef4444';
