// Product surface tokens for the dashboard.
//
// The dashboard views each used to build this object inline, per theme. The
// values are now the custom properties frontend/tokens.css declares on the
// .aa-dashboard root (light by default, .theme-dark overrides), so every
// importer follows the theme through CSS alone. `darkMode` stays in the
// signature so callers need not change; the variables resolve per theme.
export const paletteFor = (darkMode) => ({
  cardBg: 'var(--color-card)',
  cardBorder: 'var(--color-border)',
  borderStrong: 'var(--color-border-strong)',
  mutedBg: 'var(--color-muted)',
  innerBg: 'var(--color-background)',
  textPrimary: 'var(--color-text-primary)',
  textCell: 'var(--color-text-cell)',
  textSecondary: 'var(--color-text-secondary)',
  textMuted: 'var(--color-text-muted)',
  inputBg: 'var(--color-surface)',
  inputBorder: 'var(--color-border-strong)',
  trackBg: 'var(--color-muted)'
});

export const ACCENT = 'var(--color-accent-ui)';
