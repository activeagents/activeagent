import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { readThemeChoice, resolveDarkMode, systemDarkQuery, THEME_CHOICES, toggledChoice, writeThemeChoice } from '../utils/theme.mjs';

const ThemeContext = createContext();

// `theme` is the viewer's choice: 'system' (the default) follows the OS
// appearance and changes with it; 'light' and 'dark' are fixed. `darkMode`
// is what shows, and what every component reads. `setTheme` saves a
// choice; `toggleDarkMode` is the one-click flip, which saves the opposite
// of what shows as a fixed choice.
export function ThemeProvider({ children }) {
  const [theme, setThemeState] = useState(() => readThemeChoice(globalThis.localStorage));
  const [systemDark, setSystemDark] = useState(() => Boolean(systemDarkQuery()?.matches));

  // Follow the OS while the page is open. The listener stays on whatever
  // the choice is, so switching back to 'system' shows the current
  // appearance at once.
  useEffect(() => {
    const query = systemDarkQuery();
    if (!query) return undefined;
    const handler = (event) => setSystemDark(event.matches);
    setSystemDark(query.matches);
    query.addEventListener('change', handler);
    return () => query.removeEventListener('change', handler);
  }, []);

  const setTheme = useCallback((choice) => {
    const next = THEME_CHOICES.includes(choice) ? choice : 'system';
    setThemeState(next);
    writeThemeChoice(globalThis.localStorage, next);
  }, []);

  const darkMode = resolveDarkMode(theme, systemDark);
  const toggleDarkMode = useCallback(() => setTheme(toggledChoice(darkMode)), [darkMode, setTheme]);

  const value = useMemo(
    () => ({ darkMode, theme, systemDark, setTheme, toggleDarkMode }),
    [darkMode, theme, systemDark, setTheme, toggleDarkMode],
  );

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme() {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error('useTheme must be used within a ThemeProvider');
  }
  return context;
}
