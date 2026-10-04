#!/usr/bin/env node
// activeagents-browser-sidecar [serve [--config-file PATH] | check | install-browser [ARGS...] | --version]
//
//   serve            reads the start configuration (lib/config.mjs) from stdin, or
//                    from --config-file, starts the browser, and prints one JSON line
//                    to stdout once it listens: { ready, port, version, pid }. Logs go
//                    to stderr. SIGTERM or SIGINT stops it cleanly.
//   check            prints { version, node, chromium: { installed, executable } }
//   install-browser  installs the Chromium this sidecar drives (Playwright's installer)
//   --version        prints the version
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';

import { ConfigError, parseConfig } from '../lib/config.mjs';
import { VERSION } from '../lib/version.mjs';

const require = createRequire(import.meta.url);

function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on('data', (chunk) => chunks.push(chunk));
    process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    process.stdin.on('error', reject);
  });
}

async function check() {
  const { chromium } = await import('playwright');
  const executable = chromium.executablePath();
  const installed = Boolean(executable) && existsSync(executable);
  process.stdout.write(`${JSON.stringify({ version: VERSION, node: process.version, chromium: { installed, executable } })}\n`);
}

function installBrowser(args) {
  const cli = join(dirname(require.resolve('playwright/package.json')), 'cli.js');
  const result = spawnSync(process.execPath, [cli, 'install', 'chromium', ...args], { stdio: 'inherit' });
  process.exit(result.status ?? 1);
}

async function serve(args) {
  const fileIndex = args.indexOf('--config-file');
  const source = fileIndex === -1 ? await readStdin() : readFileSync(args[fileIndex + 1], 'utf8');
  const config = parseConfig(source);

  // Only the ready line goes to stdout; whoever started the sidecar may stop
  // reading it after that.
  console.log = console.error;
  const { startSidecar } = await import('../lib/sidecar.mjs');
  const sidecar = await startSidecar(config);
  process.stdout.write(`${JSON.stringify({ ready: true, port: sidecar.port, version: VERSION, pid: process.pid })}\n`);

  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
    process.once(signal, () => void sidecar.close(`received ${signal}`));
  }
  sidecar.done.then((status) => process.exit(status));
}

const [command = 'serve', ...rest] = process.argv.slice(2);

try {
  switch (command) {
    case '--version':
    case 'version':
      process.stdout.write(`${VERSION}\n`);
      break;
    case 'check':
      await check();
      break;
    case 'install-browser':
      installBrowser(rest);
      break;
    case 'serve':
      await serve(rest);
      break;
    default:
      process.stderr.write('usage: activeagents-browser-sidecar [serve [--config-file PATH] | check | install-browser | --version]\n');
      process.exit(2);
  }
} catch (error) {
  process.stderr.write(`browser-sidecar: ${error instanceof ConfigError ? `invalid configuration: ${error.message}` : error.stack ?? error}\n`);
  process.exit(1);
}
