import assert from 'node:assert/strict';
import test from 'node:test';
import { readThemeChoice, resolveDarkMode, systemDarkQuery, themeDescription, toggledChoice, writeThemeChoice, THEME_OPTIONS } from '../utils/theme.mjs';

const storageOf = (saved) => {
  const store = new Map(saved === undefined ? [] : [['dashboard-theme', saved]]);
  return { getItem: (key) => (store.has(key) ? store.get(key) : null), setItem: (key, value) => store.set(key, value), store };
};

test('the saved choice is read back, and anything else means system', () => {
  assert.equal(readThemeChoice(storageOf('dark')), 'dark', 'the old toggle saved dark');
  assert.equal(readThemeChoice(storageOf('light')), 'light');
  assert.equal(readThemeChoice(storageOf('system')), 'system');
  assert.equal(readThemeChoice(storageOf()), 'system', 'nothing saved');
  assert.equal(readThemeChoice(storageOf('blue')), 'system');
  assert.equal(readThemeChoice(undefined), 'system', 'no storage at all');
  assert.equal(readThemeChoice({ getItem() { throw new Error('blocked'); } }), 'system', 'storage that throws');
});

test('a choice is saved under the old key; an unknown one saves as system; a throwing store is survived', () => {
  const storage = storageOf();
  writeThemeChoice(storage, 'dark');
  assert.equal(storage.store.get('dashboard-theme'), 'dark');
  writeThemeChoice(storage, 'sepia');
  assert.equal(storage.store.get('dashboard-theme'), 'system');
  assert.doesNotThrow(() => writeThemeChoice({ setItem() { throw new Error('blocked'); } }, 'light'));
  assert.doesNotThrow(() => writeThemeChoice(undefined, 'light'));
});

test('system resolves to what the OS prefers; light and dark ignore it', () => {
  assert.equal(resolveDarkMode('system', true), true);
  assert.equal(resolveDarkMode('system', false), false);
  assert.equal(resolveDarkMode('system', undefined), false);
  assert.equal(resolveDarkMode('dark', false), true);
  assert.equal(resolveDarkMode('light', true), false);
});

test('the one-click toggle picks the opposite of what shows, as a fixed choice', () => {
  assert.equal(toggledChoice(true), 'light');
  assert.equal(toggledChoice(false), 'dark');
});

test('the settings line says what system is showing right now', () => {
  assert.equal(themeDescription('system', true), "Follows your system's appearance, dark right now");
  assert.equal(themeDescription('system', false), "Follows your system's appearance, light right now");
  assert.equal(themeDescription('dark', false), 'Dark across the dashboard');
  assert.equal(themeDescription('light', true), 'Light across the dashboard');
  assert.deepEqual(THEME_OPTIONS.map((option) => option.label), ['System', 'Light', 'Dark']);
});

test('the system query is absent where the window has no matchMedia', () => {
  assert.equal(systemDarkQuery(undefined), null);
  assert.equal(systemDarkQuery({}), null);
  const query = { matches: true };
  assert.equal(systemDarkQuery({ matchMedia: (q) => (q === '(prefers-color-scheme: dark)' ? query : null) }), query);
});
