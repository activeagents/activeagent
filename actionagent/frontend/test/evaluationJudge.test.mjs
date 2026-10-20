import assert from 'node:assert/strict';
import test, { before, after } from 'node:test';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { judgeInfo, judgeTitle } from '../utils/evaluationJudge.mjs';

const routed = {
  scores: {
    _judge_label: 'z-ai/glm-5.3-flash',
    _judge: { agent: 'EvaluationJudgeAgent', provider: 'openrouter', model: null, model_source: 'provider_default', answered: { 'z-ai/glm-5.3-flash': 27 } },
  },
};

test('a run with no recorded judge has no judge info', () => {
  assert.equal(judgeInfo({ judge_model: 'x' }, { scores: { _judge_label: 'x' } }), null);
  assert.equal(judgeInfo(null, null), null);
});

test('an unpinned judge is auto, names the provider default and offers the model that answered', () => {
  const info = judgeInfo({ id: 1, judge_model: null }, routed);
  assert.equal(info.auto, true);
  assert.equal(info.requested, null);
  assert.equal(info.providerDefault, 'openrouter/auto');
  assert.deepEqual(info.answered, [['z-ai/glm-5.3-flash', 27]]);
  assert.equal(info.suggestion, 'z-ai/glm-5.3-flash');
  assert.equal(
    judgeTitle(info),
    "EvaluationJudgeAgent on openrouter · asked for openrouter/auto (the provider's own default) · answered by z-ai/glm-5.3-flash ×27",
  );
});

test('a pinned judge names its model and source, and the evaluation setting leads the suggestion', () => {
  const run = { scores: { _judge: { provider: 'anthropic', model: 'claude-opus-5', model_source: 'evaluation', answered: { 'claude-opus-5': 3 } } } };
  const info = judgeInfo({ id: 1, judge_model: 'claude-sonnet-4.5' }, run);
  assert.equal(info.auto, false);
  assert.equal(info.agent, 'EvaluationJudgeAgent');
  assert.equal(info.sourceText, 'pinned on this evaluation');
  assert.equal(info.pinned, 'claude-sonnet-4.5');
  assert.equal(info.suggestion, 'claude-sonnet-4.5');
});

test('several answering models are listed most-used first, with no single suggestion', () => {
  const run = { scores: { _judge: { provider: 'openrouter', model: null, model_source: 'bogus', answered: { b: 2, a: 5, c: 0 } } } };
  const info = judgeInfo({}, run);
  assert.deepEqual(info.answered, [['a', 5], ['b', 2]]);
  assert.equal(info.source, 'provider_default');
  assert.equal(info.suggestion, '');
});

const output = fileURLToPath(new URL(`../node_modules/.cache/judge-chip-${process.pid}.mjs`, import.meta.url));
let view, window, container, root;
let requests = [];
let changed = 0;

before(async () => {
  ({ window } = new JSDOM('<!doctype html><body><div id="root"></div></body>', { url: 'http://localhost/dashboard' }));
  for (const key of ['window', 'document', 'navigator', 'Event']) Object.defineProperty(globalThis, key, { value: key === 'window' ? window : window[key], configurable: true });
  window.ACTIVE_AGENT_DASHBOARD = { mountPath: '/dashboard' };
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.fetch = async (url, init) => { requests.push({ url, init }); return { ok: true, json: async () => ({ evaluation: {} }) }; };
  const result = await build({ stdin: { contents: `
    import React, { act } from 'react';
    import { createRoot } from 'react-dom/client';
    import JudgeChip from './components/dashboard/evaluations/JudgeChip.jsx';
    export { act };
    export function mount(node, props) { const root = createRoot(node); root.render(React.createElement(JudgeChip, props)); return root; }
    export function rerender(root, props) { root.render(React.createElement(JudgeChip, props)); }
  `, resolveDir: fileURLToPath(new URL('..', import.meta.url)), loader: 'jsx' }, bundle: true, write: false, platform: 'node', format: 'esm', external: ['react', 'react-dom/client'], logLevel: 'error' });
  mkdirSync(dirname(output), { recursive: true }); writeFileSync(output, result.outputFiles[0].text);
  view = await import(pathToFileURL(output).href);
  container = window.document.getElementById('root');
});
after(async () => { if (root) await view.act(async () => root.unmount()); rmSync(output, { force: true }); window.close(); });

const click = async (node) => view.act(async () => node.dispatchEvent(new window.MouseEvent('click', { bubbles: true })));
const button = (text) => [...container.querySelectorAll('button')].find((node) => node.textContent.trim() === text);

test('the chip names the model that judged, opens the judge, and pins and unpins its model', async () => {
  const props = { evaluation: { id: 7, judge_model: null }, run: routed, label: 'z-ai/glm-5.3-flash', onChanged: () => { changed += 1; } };
  await view.act(async () => { root = view.mount(container, props); });

  assert.match(container.textContent, /judged by z-ai\/glm-5\.3-flash/);
  assert.match(container.textContent, /auto/);
  assert.equal(container.querySelector('[data-testid="judge-chip-panel"]'), null);

  await click(container.querySelector('button'));
  const panel = container.querySelector('[data-testid="judge-chip-panel"]');
  assert.match(panel.textContent, /EvaluationJudgeAgent/);
  assert.match(panel.textContent, /openrouter\/auto · the provider's own default/);
  assert.match(panel.textContent, /z-ai\/glm-5\.3-flash ×27/);
  assert.equal(container.querySelector('[data-testid="judge-chip-model"]').value, 'z-ai/glm-5.3-flash');
  assert.equal(panel.querySelector('a').getAttribute('href'), '/dashboard/settings?tab=api-keys');
  assert.equal(button('Unpin'), undefined, 'nothing to unpin yet');

  await click(container.querySelector('[data-testid="judge-chip-pin"]'));
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/api/evaluations/7');
  assert.equal(requests[0].init.method, 'PATCH');
  assert.deepEqual(JSON.parse(requests[0].init.body), { evaluation: { judge_model: 'z-ai/glm-5.3-flash' } });
  assert.equal(changed, 1);

  await view.act(async () => view.rerender(root, { ...props, evaluation: { id: 7, judge_model: 'z-ai/glm-5.3-flash' } }));
  assert.match(container.textContent, /next run: z-ai\/glm-5\.3-flash/);
  await click(button('Unpin'));
  assert.deepEqual(JSON.parse(requests[1].init.body), { evaluation: { judge_model: '' } });
  assert.equal(changed, 2);
});

test('a run with no recorded judge shows its label alone', async () => {
  await view.act(async () => view.rerender(root, { evaluation: { id: 7 }, run: { scores: { _judge_label: 'claude-opus-5' } }, label: 'claude-opus-5' }));
  assert.equal(container.textContent, 'judged by claude-opus-5');
  assert.equal(container.querySelector('button'), null);
});
