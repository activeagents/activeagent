#!/usr/bin/env node

/**
 * Tests that llms.txt is valid and complete.
 * Run: node scripts/test-llms-txt.mjs
 */

import { execSync } from 'child_process';
import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUTPUT = join(__dirname, '..', 'docs', 'public', 'llms.txt');

let failures = 0;

function assert(condition, msg) {
  if (!condition) {
    console.error(`FAIL: ${msg}`);
    failures++;
  } else {
    console.log(`  ok: ${msg}`);
  }
}

// Step 1: Run the generator
console.log('Running generator...');
execSync('node scripts/generate-llms-txt.mjs', {
  cwd: join(__dirname, '..'),
  stdio: 'inherit',
});

// Step 2: Read output
const content = readFileSync(OUTPUT, 'utf-8');
const lines = content.split('\n');

// Test: starts with H1
assert(lines[0] === '# Active Agent', 'starts with "# Active Agent"');

// Test: has exactly one H1
const h1s = lines.filter(l => /^# /.test(l));
assert(h1s.length === 1, `exactly one H1 (got ${h1s.length})`);

// Test: has blockquote description
const blockquotes = lines.filter(l => l.startsWith('> '));
assert(blockquotes.length >= 1, 'has blockquote description');

// Test: has H2 sections
const h2s = lines.filter(l => /^## /.test(l));
assert(h2s.length >= 5, `has at least 5 H2 sections (got ${h2s.length})`);

// Test: all entries are markdown links with descriptions
const entries = lines.filter(l => /^- \[.+\]\(https:\/\//.test(l));
assert(entries.length >= 30, `has at least 30 doc entries (got ${entries.length})`);

// Test: every entry has a description after the link
for (const entry of entries) {
  const hasDesc = /\): .+/.test(entry);
  if (!hasDesc) {
    assert(false, `entry missing description: ${entry.substring(0, 80)}`);
  }
}

// Test: expected sections present
const sectionNames = h2s.map(l => l.replace('## ', ''));
for (const expected of ['Getting Started', 'Framework', 'Agents', 'Actions', 'Providers', 'Examples', 'Contributing']) {
  assert(sectionNames.includes(expected), `section "${expected}" present`);
}

// Test: key pages are present
const entryText = entries.join('\n');
for (const keyword of ['Getting Started', 'Configuration', 'Anthropic', 'OpenAI', 'Streaming', 'Tools', 'Callbacks']) {
  assert(entryText.includes(keyword), `key page "${keyword}" present`);
}

// Test: URLs point to docs.activeagents.ai
const urls = entries.map(l => l.match(/\((https:\/\/[^)]+)\)/)?.[1]).filter(Boolean);
for (const url of urls) {
  assert(url.startsWith('https://docs.activeagents.ai/'), `valid URL: ${url}`);
}

console.log(`\n${failures === 0 ? 'ALL TESTS PASSED' : `${failures} FAILURE(S)`}`);
process.exit(failures === 0 ? 0 : 1);
