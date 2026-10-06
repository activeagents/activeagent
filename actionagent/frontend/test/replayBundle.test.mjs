import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// The dashboard bundle (index.jsx) must carry no rrweb code: the replayer
// ships in its own bundle (replay/player.js), loaded only by the session
// player's frame, and the recorder in another (recorder/recorder.js), which
// the dashboard imports by URL while the Run Agent workbench is open.
// Checked on the source import graph, so it holds before the bundles are
// rebuilt.

const FRONTEND = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const EXTENSIONS = ['', '.jsx', '.js', '.mjs', '/index.js', '/index.jsx'];
const IMPORT = /(?:import|export)\s[^'"]*?from\s*['"]([^'"]+)['"]|import\s*['"]([^'"]+)['"]|import\(\s*['"]([^'"]+)['"]\s*\)/g;

function resolveLocal(fromFile, specifier) {
  const base = resolve(dirname(fromFile), specifier);
  const found = EXTENSIONS.map((ext) => base + ext).find((candidate) => existsSync(candidate) && !candidate.endsWith('/'));
  assert.ok(found, `${specifier} imported by ${fromFile} resolves`);
  return found;
}

// Every package a module imports, directly or through its local imports.
function packagesReachableFrom(entry) {
  const seen = new Set();
  const packages = new Set();
  const pending = [entry];
  while (pending.length) {
    const file = pending.pop();
    if (seen.has(file)) continue;
    seen.add(file);
    for (const match of readFileSync(file, 'utf8').matchAll(IMPORT)) {
      const specifier = match[1] || match[2] || match[3];
      if (specifier.startsWith('.')) pending.push(resolveLocal(file, specifier));
      else packages.add(specifier);
    }
  }
  return packages;
}

test('the dashboard bundle imports no rrweb package', () => {
  const rrweb = [...packagesReachableFrom(join(FRONTEND, 'index.jsx'))].filter((name) => name.includes('rrweb'));

  assert.deepEqual(rrweb, []);
});

test('the replay bundle imports the rrweb replayer', () => {
  assert.ok(packagesReachableFrom(join(FRONTEND, 'replay/player.js')).has('@rrweb/replay'));
});

test('the recorder bundle imports the rrweb recorder and nothing else', () => {
  assert.deepEqual([...packagesReachableFrom(join(FRONTEND, 'recorder/recorder.js'))], ['@rrweb/record']);
});
