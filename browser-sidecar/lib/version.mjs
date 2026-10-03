import { readFileSync } from 'node:fs';

// The engine refuses a sidecar whose version is not its own, so the version
// is read from the package the code shipped in rather than kept twice.
export const VERSION = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;
