import assert from 'node:assert/strict';
import test from 'node:test';
import { fixPromptMarkdown, fixPromptTitle, resultsForFixItem, samplingFixPromptMarkdown } from '../utils/fixPrompt.mjs';

// The brief a What-to-fix card copies for a coding harness. Everything a
// harness needs to act is in the text: which agent and evaluation, what
// failed and on which scenarios, each scenario's prompt, expectations,
// tool calls and answer, where to look, and the MCP calls that prove the
// fix. Nothing in it is invented: every line traces to the card, the run,
// its results or the suite's scenarios.

const evaluation = {
  id: 42,
  name: 'Support lookups',
  agent: { id: 7, name: 'Support', slug: 'support' },
  criteria: [{ key: 'answer_quality', type: 'llm_judge', config: { prompt: 'Is the answer grounded?' } }],
};

const run = { id: 900, status: 'complete', models: ['openai/gpt-4o-mini', 'anthropic/claude-haiku'] };

const result = (overrides = {}) => ({
  id: 1, scenario_key: 'order_lookup', prompt: 'Where is order ABC-123?', provider: 'openai', model: 'gpt-4o-mini',
  status: 'failed', score: 0.4, fault: 'expected_tool_not_called',
  scenario: { key: 'order_lookup', prompt: 'Where is order ABC-123?', expectations: { tools: ['lookup_order'], contains: ['shipped'] }, notes: 'Looks the order up first.' },
  tool_calls: [], output: 'Your order has shipped and should arrive tomorrow.',
  diagnosis: { summary: 'Stated a delivery date without calling lookup_order.', recommendation: 'Call lookup_order before answering.' },
  agent_run_id: 55,
  ...overrides,
});

const faultItem = {
  kind: 'fault', fault: 'expected_tool_not_called', count: 2, scenario_keys: ['order_lookup', 'order_status'],
  models: ['openai/gpt-4o-mini', 'anthropic/claude-haiku'],
  recommendation: 'Enable the orders server and tell the agent to look orders up before answering.',
  tools_label: 'missing tools',
  tools: [{ name: 'lookup_order', note: 'Orders', server: { key: 'orders', name: 'Orders', status: 'available' } }],
  server: { key: 'orders', name: 'Orders', status: 'available' },
  note: null,
  action: { label: 'Enable Orders for Support', hint: 'MCP Services ->', path: '/mcp/orders' },
};

const labelFor = (r) => `${r.provider}/${r.model}`;

test('titles name the fault, the judge suggestion or the sampling card', () => {
  assert.equal(fixPromptTitle(faultItem), 'Fix: expected tool not called');
  assert.equal(fixPromptTitle({ kind: 'instruction', fault: 'instruction change' }), 'Add to the instructions');
  assert.equal(fixPromptTitle({ kind: 'below', label: 'below pass mark ×2' }), 'Fix: below pass mark ×2');
  assert.equal(fixPromptTitle(null), 'Fix');
});

test('a fault brief carries the context, the scenarios with their evidence, the tools, where to look and how to verify', () => {
  const results = [
    result(),
    result({ id: 2, provider: 'anthropic', model: 'claude-haiku', tool_calls: [{ name: 'search_help', error: true, detail: 'timed out' }], output: null }),
    result({ id: 3, scenario_key: 'order_status', prompt: 'Has order XYZ shipped?', scenario: { key: 'order_status', prompt: 'Has order XYZ shipped?', expectations: { tools: ['lookup_order'] } }, status: 'passed', fault: null, score: 0.9 }),
  ];

  const text = fixPromptMarkdown({
    item: faultItem, evaluation, run, runNumber: 3, results, agentName: 'Support', dashboardUrl: 'https://app.example.com/activeagents/', labelFor,
  });

  assert.match(text, /^# Fix: expected tool not called\n/);
  assert.match(text, /Agent \*\*Support\*\* \(id 7, slug `support`\)/);
  assert.match(text, /Evaluation \*\*Support lookups\*\* \(id 42\), run #3 \(id 900\)/);
  assert.match(text, /Dashboard: https:\/\/app\.example\.com\/activeagents\/evaluations\/42\/runs\/900/);
  assert.match(text, /## What went wrong\n\n2 results: expected tool not called on 2 scenarios under openai\/gpt-4o-mini, anthropic\/claude-haiku\./);
  assert.match(text, /Enable the orders server and tell the agent/);
  assert.match(text, /## Missing tools\n\n- `lookup_order` · served by Orders \(available\)/);
  assert.match(text, /MCP server \*\*Orders\*\* \(`orders`\) is available for the agent: https:\/\/app\.example\.com\/activeagents\/mcp\/orders/);
  assert.match(text, /## Scenarios \(2\)/);
  assert.match(text, /### `order_lookup`\n\nPrompt:\n> Where is order ABC-123\?/);
  assert.match(text, /Expects: tools: lookup_order; contains: shipped/);
  assert.match(text, /Notes: Looks the order up first\./);
  assert.match(text, /\*\*openai\/gpt-4o-mini\*\* · failed · score 0\.40 · expected tool not called\n- Tools called: none\n- Diagnosis: Stated a delivery date without calling lookup_order\. Call lookup_order before answering\.\n- Result id: 1 · agent run 55\n\nAnswer:\n> Your order has shipped/);
  assert.match(text, /\*\*anthropic\/claude-haiku\*\* · failed[^\n]*\n- Tools called: search_help \(error: timed out\)/);
  assert.match(text, /- Answer: not retained for this run/);
  // The passed result on order_status is not evidence for the fault, so its
  // section carries the prompt alone.
  assert.match(text, /### `order_status`\n\nPrompt:\n> Has order XYZ shipped\?\n\nExpects: tools: lookup_order\n\n## Where to look/);
  assert.doesNotMatch(text, /score 0\.90/);
  assert.match(text, /- The agent's instructions and action prompts: https:\/\/app\.example\.com\/activeagents\/agents\/7\/edit\./);
  assert.match(text, /- Its tools and MCP servers: https:\/\/app\.example\.com\/activeagents\/tools\./);
  assert.match(text, /- On the dashboard: \*\*Enable Orders for Support\*\* \(MCP Services ->\) https:\/\/app\.example\.com\/activeagents\/mcp\/orders\./);
  assert.match(text, /## Verify\n\n1\. Make the change in the agent, not in the scenarios or their expectations\./);
  assert.match(text, /`evaluations_run` \(evaluation_id: 42, keys: \["order_lookup", "order_status"\], models: \["openai\/gpt-4o-mini", "anthropic\/claude-haiku"\]\), served at https:\/\/app\.example\.com\/activeagents\/mcp, or POST https:\/\/app\.example\.com\/activeagents\/api\/evaluations\/42\/run with the same keys\[\] and models\[\]\./);
  assert.match(text, /3\. Poll `evaluation_runs_get` until the run is complete: every scenario above should pass with no fault\./);
  assert.match(text, /4\. `evaluation_runs_compare` against run #3 \(id 900\) should list them as fixed and nothing as regressed\./);
  assert.match(text, /When done, say what you changed and which run proved it\.\n$/);
});

test('a card scoped to one model briefs that model alone', () => {
  const scoped = { ...faultItem, count: 1, models: ['anthropic/claude-haiku'], scenario_keys: ['order_lookup'] };
  const results = [result(), result({ id: 2, provider: 'anthropic', model: 'claude-haiku', output: 'No idea.' })];

  const text = fixPromptMarkdown({ item: scoped, evaluation, run, results, labelFor });

  assert.match(text, /expected tool not called on 1 scenario under anthropic\/claude-haiku\./);
  assert.match(text, /\*\*anthropic\/claude-haiku\*\* · failed/);
  assert.doesNotMatch(text, /\*\*openai\/gpt-4o-mini\*\*/);
  assert.match(text, /models: \["anthropic\/claude-haiku"\]/);
  // No dashboard URL: the links are left out rather than written relative.
  assert.doesNotMatch(text, /Dashboard:/);
  assert.match(text, /- The agent's instructions and action prompts\.\n/);
  assert.match(text, /\(evaluation_id: 42, keys: \["order_lookup"\], models: \["anthropic\/claude-haiku"\]\), or POST \/api\/evaluations\/42\/run/);
});

test('an instruction card quotes the judge and points at the instructions', () => {
  const item = {
    kind: 'instruction', fault: 'instruction change', count: 1, scenario_keys: ['order_lookup'], models: ['openai/gpt-4o-mini'],
    recommendation: null, quote: 'Always call lookup_order before stating a delivery date.', tools: [], server: null, note: null,
    action: { label: 'Add to instructions', hint: 'Agent -> Instructions', path: '/agents/7/edit' },
  };
  const results = [result({ diagnosis: { summary: 'Guessed the date.', judge: { instruction_change: 'Always call lookup_order before stating a delivery date.' } } })];

  const text = fixPromptMarkdown({ item, evaluation, run, results, labelFor, dashboardUrl: 'http://localhost:3000/activeagents' });

  assert.match(text, /^# Add to the instructions\n/);
  assert.match(text, /The judge proposes adding this to the instructions:\n\n> Always call lookup_order before stating a delivery date\./);
  assert.match(text, /### `order_lookup`[\s\S]*- Diagnosis: Guessed the date\./);
  assert.match(text, /\*\*Add to instructions\*\* \(Agent -> Instructions\) http:\/\/localhost:3000\/activeagents\/agents\/7\/edit\./);
  assert.doesNotMatch(text, /## Missing tools|## Tools/);
});

test('without results the brief still names the scenarios, reading prompts from the suite', () => {
  const scenarios = [{ key: 'order_lookup', prompt: 'Where is order ABC-123?', expectations: { tools: ['lookup_order'] } }, { key: 'order_status', prompt: 'Has order XYZ shipped?' }];

  const text = fixPromptMarkdown({ item: faultItem, evaluation, run: null, results: [], scenarios });

  assert.match(text, /### `order_lookup`\n\nPrompt:\n> Where is order ABC-123\?\n\nExpects: tools: lookup_order/);
  assert.match(text, /### `order_status`\n\nPrompt:\n> Has order XYZ shipped\?/);
  assert.doesNotMatch(text, /evaluation_runs_compare/);
  assert.equal(fixPromptMarkdown({ item: null }), '');
});

test('more than six scenarios are briefed in full for the first six and listed after', () => {
  const keys = Array.from({ length: 8 }, (_, i) => `case_${i + 1}`);
  const item = { ...faultItem, scenario_keys: keys, count: 8, tools: [], server: null };

  const text = fixPromptMarkdown({ item, evaluation, run, results: keys.map((key, i) => result({ id: i, scenario_key: key, prompt: `Question ${i + 1}`, scenario: { key, prompt: `Question ${i + 1}` } })), labelFor });

  assert.match(text, /## Scenarios \(8\)/);
  assert.match(text, /### `case_6`/);
  assert.doesNotMatch(text, /### `case_7`/);
  assert.match(text, /Also failing: `case_7`, `case_8`\./);
});

test('resultsForFixItem keeps the results that carry the fault, narrowed to the card\'s models', () => {
  const results = [
    result(),
    result({ id: 2, provider: 'anthropic', model: 'claude-haiku', fault: 'low_quality' }),
    result({ id: 3, scenario_key: 'other', fault: 'expected_tool_not_called' }),
    result({ id: 4, status: 'pending', fault: null }),
  ];

  assert.deepEqual(resultsForFixItem(faultItem, results, { labelFor }).map((r) => r.id), [1]);
  assert.deepEqual(resultsForFixItem({ ...faultItem, models: ['anthropic/claude-haiku'] }, results, { labelFor }).map((r) => r.id), [2]);
  assert.deepEqual(resultsForFixItem({ ...faultItem, fault: 'nothing_like_this', models: [] }, results, { labelFor }).map((r) => r.id), [1, 2]);
});

test('a sampling brief carries the card text, its chips and details, the criteria it names and the verify steps', () => {
  const item = {
    kind: 'below', label: 'below pass mark ×2', scope: '1 criterion · 2 models',
    text: 'Scored under the pass mark (pass ≥ 70%).',
    chipsLabel: 'unscored criteria', chips: ['answer_quality'],
    details: ['answer_quality · gpt-4o-mini 40% · expects judge scores 0.0–1.0 · 2/5 · 40% passed'],
    action: { label: 'Add provider key', path: '/settings', hint: 'Settings ->' },
  };
  const samplingRun = { id: 901, status: 'complete', scores: { _cohorts: { 'gpt-4o-mini': { samples: 5 }, 'claude-haiku': { samples: 5 } } } };

  const text = samplingFixPromptMarkdown({ item, evaluation, run: samplingRun, runNumber: 2, dashboardUrl: 'https://app.example.com' });

  assert.match(text, /^# Fix: below pass mark ×2\n/);
  assert.match(text, /Evaluation \*\*Support lookups\*\* \(id 42\), run #2 \(id 901\)\./);
  assert.match(text, /## What went wrong\n\nbelow pass mark ×2 · 1 criterion · 2 models\.\n\nScored under the pass mark \(pass ≥ 70%\)\./);
  assert.match(text, /Unscored criteria: `answer_quality`\./);
  assert.match(text, /- answer_quality · gpt-4o-mini 40%/);
  assert.match(text, /## Criteria\n\n- `answer_quality` \(llm_judge\): \{"prompt":"Is the answer grounded\?"\}/);
  assert.match(text, /\*\*Add provider key\*\* \(Settings ->\) https:\/\/app\.example\.com\/settings\./);
  assert.match(text, /`evaluations_run` \(evaluation_id: 42, models: \["gpt-4o-mini", "claude-haiku"\]\), served at https:\/\/app\.example\.com\/mcp/);
  assert.match(text, /until the run is complete and nothing is skipped or below the pass mark\./);
  assert.match(text, /`evaluation_runs_compare` against run #2 \(id 901\)/);
});

test('a missing-models card asks for runs under exactly those models', () => {
  const item = { kind: 'missing', label: 'no generations ×1', scope: 'comparison cohorts', text: 'No recorded generations.', chipsLabel: 'missing models', chips: ['claude-haiku'] };

  const text = samplingFixPromptMarkdown({ item, evaluation, run: { id: 902 } });

  assert.match(text, /Missing models: `claude-haiku`\./);
  assert.match(text, /models: \["claude-haiku"\]/);
  assert.equal(samplingFixPromptMarkdown({ item: null }), '');
});
