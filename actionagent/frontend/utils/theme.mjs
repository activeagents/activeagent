// The dashboard's appearance: the choice a viewer saved (system, light or
// dark) and what it shows as right now. Saved under the key the old
// light/dark toggle used, so a dashboard that only ever saw that toggle
// keeps the choice it made.

export const THEME_STORAGE_KEY = 'dashboard-theme';
export const THEME_CHOICES = ['system', 'light', 'dark'];
export const THEME_OPTIONS = [
  { value: 'system', label: 'System' },
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
];
export const SYSTEM_DARK_QUERY = '(prefers-color-scheme: dark)';

// The saved choice; 'system' when nothing valid is saved.
export function readThemeChoice(storage) {
  try {
    const saved = storage?.getItem?.(THEME_STORAGE_KEY);
    return THEME_CHOICES.includes(saved) ? saved : 'system';
  } catch {
    return 'system';
  }
}

// Storage may be unavailable (private windows, blocked site data); the
// choice then lasts for the page.
export function writeThemeChoice(storage, choice) {
  try {
    storage?.setItem?.(THEME_STORAGE_KEY, THEME_CHOICES.includes(choice) ? choice : 'system');
  } catch {
    // nothing to do
  }
}

// Whether the dashboard shows dark for a choice, given what the system
// prefers right now.
export function resolveDarkMode(choice, systemDark) {
  return choice === 'system' ? Boolean(systemDark) : choice === 'dark';
}

// What the one-click toggle (the header's sun/moon) picks: the opposite of
// what shows now, as an explicit choice.
export function toggledChoice(darkMode) {
  return darkMode ? 'light' : 'dark';
}

// The line under "Theme" on the settings page.
export function themeDescription(choice, systemDark) {
  if (choice === 'system') return `Follows your system's appearance, ${systemDark ? 'dark' : 'light'} right now`;
  return choice === 'dark' ? 'Dark across the dashboard' : 'Light across the dashboard';
}

// The system's media query, where the page has one (a server render and
// some test windows do not).
export function systemDarkQuery(win = globalThis.window) {
  return typeof win?.matchMedia === 'function' ? win.matchMedia(SYSTEM_DARK_QUERY) : null;
}
