// The Markdown brief a What-to-fix card copies for a coding harness: what
// failed, the scenarios it failed on with their prompts, expectations, tool
// calls and answers, where in the agent to look, and how to prove the fix
// with the dashboard's MCP tools. Pure, so the node tests can pin it; the
// card supplies the dashboard's URL and the result-to-column mapping.
//
// Two card shapes are briefed: a scenario suite's fix items (the
// framework report's `fix_items`: kind fault | instruction) and a sampling
// run's (evaluationRuns#samplingFixItems: kind failed | missing | judge |
// telemetry | samples | below).

import { runModels } from './evaluationRuns.mjs';

const MAX_SCENARIOS = 6;
const MAX_ANSWER_CHARS = 600;
const MAX_LIST = 12;

const words = (fault) => String(fault || '').replace(/_/g, ' ');
const trim = (value) => String(value ?? '').trim();
const uniq = (list) => [...new Set(list.filter(Boolean))];

const quote = (text) => trim(text).split('\n').map((line) => `> ${line}`).join('\n');

const excerpt = (text, max = MAX_ANSWER_CHARS) => {
  const value = trim(text);
  return value.length > max ? `${value.slice(0, max - 1)}…` : value;
};

const code = (value) => `\`${String(value).replace(/`/g, 'ˋ')}\``;

const trimSlash = (url) => String(url || '').replace(/\/+$/, '');

// The title a brief opens with: the fault for a fault card, the judge's
// suggestion for an instruction card, the sampling card's label.
export const fixPromptTitle = (item) => {
  if (!item) return 'Fix';
  if (item.kind === 'instruction') return 'Add to the instructions';
  if (item.kind === 'fault') return `Fix: ${words(item.fault)}`;
  return `Fix: ${words(item.label || item.kind)}`;
};

// Model labels as the API takes them (`models: ["provider/model"]`): the
// card's own when it is scoped to models, else every model the run scored.
const modelLabels = (item, run) => {
  const scoped = uniq(item?.models || []);
  if (scoped.length) return scoped;
  return uniq(runModels(run).map((model) => (typeof model === 'string' ? model : model?.label)));
};

// A scenario's expectations as "tools lookup_order; contains refund" lines.
const expectationLines = (expectations) => {
  if (!expectations || typeof expectations !== 'object') return [];
  return Object.entries(expectations).flatMap(([key, value]) => {
    const list = Array.isArray(value) ? value : value == null || value === '' ? [] : [value];
    if (!list.length) return [];
    return [`${words(key)}: ${list.map((entry) => (typeof entry === 'object' ? JSON.stringify(entry) : String(entry))).join(', ')}`];
  });
};

// "lookup_order", "send_invoice (error: timed out)" from a result's tool calls.
const toolCallText = (calls) => {
  if (!Array.isArray(calls) || !calls.length) return 'none';
  return calls.map((call) => {
    if (typeof call === 'string') return call;
    const name = call?.name || call?.tool || 'tool';
    const failed = call?.error ? ` (error: ${excerpt(call.detail || call.error, 80)})` : '';
    return `${name}${failed}`;
  }).join(', ');
};

// The results a card speaks for: those carrying its fault (or the judge's
// instruction change it quotes) on its scenarios, narrowed to its models
// when it names some; else any settled result of those scenarios.
export const resultsForFixItem = (item, results = [], { labelFor = (result) => result?.model } = {}) => {
  const keys = new Set(item?.scenario_keys || []);
  const models = new Set(item?.models || []);
  const settled = results.filter((result) => result && result.status && result.status !== 'pending' && keys.has(result.scenario_key));
  const scoped = models.size ? settled.filter((result) => models.has(labelFor(result))) : settled;
  const matching = scoped.filter((result) => {
    if (item?.kind === 'instruction') return trim(result.diagnosis?.judge?.instruction_change) === trim(item.quote);
    if (item?.kind === 'fault') return result.fault === item.fault;
    return true;
  });
  return matching.length ? matching : scoped;
};

// What a scenario asked, from the suite's own entry when the panel has it,
// else from any result that replayed it: a result records the scenario as
// it was evaluated.
const scenarioEntry = (key, scenarios, results) => {
  const listed = (scenarios || []).find((scenario) => scenario?.key === key);
  if (listed) return listed;
  const replayed = results.find((result) => result?.scenario_key === key && (result.prompt || result.scenario));
  if (!replayed) return null;
  return { ...(replayed.scenario || {}), prompt: replayed.scenario?.prompt || replayed.prompt };
};

// One scenario's section: the question, what it expects, and what each
// faulted replay did with it.
const scenarioSection = (key, rows, scenario) => {
  const first = rows[0];
  const prompt = first?.prompt || first?.scenario?.prompt || scenario?.prompt;
  const expectations = first?.scenario?.expectations || scenario?.expectations;
  const notes = first?.scenario?.notes || scenario?.notes;
  const lines = [`### ${code(key)}`];
  if (prompt) lines.push('', 'Prompt:', quote(prompt));
  const expects = expectationLines(expectations);
  if (expects.length) lines.push('', `Expects: ${expects.join('; ')}`);
  if (notes) lines.push('', `Notes: ${trim(notes)}`);
  rows.forEach((result) => {
    const label = [result.provider, result.model].filter(Boolean).join('/') || 'model';
    const score = result.score == null ? '' : ` · score ${Number(result.score).toFixed(2)}`;
    const fault = result.fault || (result.status === 'errored' ? 'run_error' : null);
    lines.push('', `**${label}** · ${result.status}${score}${fault ? ` · ${words(fault)}` : ''}`);
    lines.push(`- Tools called: ${toolCallText(result.tool_calls)}`);
    const diagnosis = result.diagnosis || {};
    const explanation = [diagnosis.summary, diagnosis.recommendation || result.recommendation].map(trim).filter(Boolean).join(' ');
    if (explanation) lines.push(`- Diagnosis: ${explanation}`);
    if (diagnosis.judge?.suggested_tool?.name) {
      const tool = diagnosis.judge.suggested_tool;
      lines.push(`- Suggested tool: ${code(tool.name)}${tool.description ? ` (${trim(tool.description)})` : ''}`);
    }
    if (result.error_message) lines.push(`- Error: ${excerpt(result.error_message, 200)}`);
    if (result.id != null) lines.push(`- Result id: ${result.id}${result.agent_run_id ? ` · agent run ${result.agent_run_id}` : ''}`);
    if (result.output) lines.push('', 'Answer:', quote(excerpt(result.output)));
    else lines.push('- Answer: not retained for this run');
  });
  return lines;
};

const contextLines = ({ evaluation, run, runNumber, agentName, dashboardUrl }) => {
  const agent = evaluation?.agent || {};
  const name = agentName || agent.name || 'the agent';
  const base = trimSlash(dashboardUrl);
  const lines = [];
  const runText = run?.id != null ? `run ${runNumber != null ? `#${runNumber} ` : ''}(id ${run.id})` : null;
  lines.push(`Agent **${name}**${agent.id != null ? ` (id ${agent.id}${agent.slug ? `, slug ${code(agent.slug)}` : ''})` : ''}.`);
  if (evaluation?.name) lines.push(`Evaluation **${evaluation.name}**${evaluation.id != null ? ` (id ${evaluation.id})` : ''}${runText ? `, ${runText}` : ''}.`);
  if (base && evaluation?.id != null) {
    lines.push(`Dashboard: ${base}/evaluations/${evaluation.id}${run?.id != null ? `/runs/${run.id}` : ''}`);
  }
  return lines;
};

const verifyLines = ({ evaluation, run, runNumber, keys = [], models = [], dashboardUrl }) => {
  const base = trimSlash(dashboardUrl);
  const id = evaluation?.id;
  const args = [`evaluation_id: ${id ?? '<evaluation id>'}`];
  if (keys.length) args.push(`keys: [${keys.map((key) => `"${key}"`).join(', ')}]`);
  if (models.length) args.push(`models: [${models.map((model) => `"${model}"`).join(', ')}]`);
  const lines = [
    '## Verify',
    '',
    '1. Make the change in the agent, not in the scenarios or their expectations.',
    `2. Re-run with the dashboard's MCP tool ${code('evaluations_run')} (${args.join(', ')})${base ? `, served at ${base}/mcp` : ''}`
      + `${id != null ? `, or POST ${base || ''}/api/evaluations/${id}/run with the same ${keys.length ? 'keys[] and ' : ''}models[]` : ''}.`,
    `3. Poll ${code('evaluation_runs_get')} until the run is complete${keys.length ? `: every scenario above should pass with no fault` : ' and nothing is skipped or below the pass mark'}.`,
  ];
  if (run?.id != null) {
    lines.push(`4. ${code('evaluation_runs_compare')} against run ${runNumber != null ? `#${runNumber} ` : ''}(id ${run.id}) should list them as fixed and nothing as regressed.`);
  }
  lines.push('', 'When done, say what you changed and which run proved it.');
  return lines;
};

// The brief for one of a scenario suite's What-to-fix cards.
//
//   fixPromptMarkdown({ item, evaluation, run, runNumber, results, scenarios, agentName, dashboardUrl, labelFor })
//
// `results` are the run's results as the API serves them; `scenarios` the
// suite's scenarios, read for a prompt when no result carries it;
// `labelFor` maps a result to its model column (defaults to the model
// name); `dashboardUrl` is the mounted dashboard's absolute URL.
export const fixPromptMarkdown = ({
  item, evaluation = null, run = null, runNumber = null, results = [], scenarios = [], agentName = null, dashboardUrl = '', labelFor, target = 'dashboard',
} = {}) => {
  if (!item) return '';
  if (target === 'sandbox') dashboardUrl = '';
  const base = trimSlash(dashboardUrl);
  const keys = uniq(item.scenario_keys || []);
  const models = modelLabels(item, run);
  const rows = resultsForFixItem(item, results, { labelFor });
  const byKey = new Map();
  rows.forEach((result) => byKey.set(result.scenario_key, [...(byKey.get(result.scenario_key) || []), result]));

  const lines = [`# ${fixPromptTitle(item)}`, '', ...contextLines({ evaluation, run, runNumber, agentName, dashboardUrl }), ''];

  lines.push('## What went wrong', '');
  const count = item.count || keys.length;
  const scope = `${words(item.fault)} on ${keys.length} scenario${keys.length === 1 ? '' : 's'}${models.length && (item.models || []).length ? ` under ${models.join(', ')}` : ''}`;
  lines.push(`${count > 1 ? `${count} results: ` : ''}${scope}.`);
  if (item.recommendation) lines.push('', trim(item.recommendation));
  if (item.quote) lines.push('', 'The judge proposes adding this to the instructions:', '', quote(item.quote));
  if (item.note) lines.push('', trim(item.note));

  const tools = uniq((item.tools || []).map((tool) => (typeof tool === 'string' ? tool : tool?.name)));
  if (tools.length) {
    lines.push('', `## ${item.tools_label ? item.tools_label[0].toUpperCase() + item.tools_label.slice(1) : 'Tools'}`, '');
    (item.tools || []).forEach((tool) => {
      const name = typeof tool === 'string' ? tool : tool?.name;
      if (!name) return;
      const note = typeof tool === 'object' ? tool.note : null;
      const server = typeof tool === 'object' ? tool.server : null;
      const served = server ? ` · served by ${server.name || server.key}${server.status ? ` (${server.status})` : ''}` : '';
      lines.push(`- ${code(name)}${note && note !== server?.name ? ` — ${trim(note)}` : ''}${served}`);
    });
    if (item.server) {
      const enabled = item.server.status === 'enabled';
      lines.push('', `MCP server **${item.server.name || item.server.key}** (${code(item.server.key)}) is ${enabled ? 'enabled' : `${item.server.status || 'not enabled'}`} for the agent${base ? `: ${base}/mcp/${item.server.key}` : ''}.`);
    }
  }

  lines.push('', `## Scenario${keys.length === 1 ? '' : 's'} (${keys.length})`);
  keys.slice(0, MAX_SCENARIOS).forEach((key) => {
    lines.push('', ...scenarioSection(key, byKey.get(key) || [], scenarioEntry(key, scenarios, results)));
  });
  if (keys.length > MAX_SCENARIOS) {
    lines.push('', `Also failing: ${keys.slice(MAX_SCENARIOS).map(code).join(', ')}.`);
  }

  lines.push('', '## Where to look', '');
  const agentId = evaluation?.agent?.id;
  lines.push(`- The agent's instructions and action prompts${base && agentId != null ? `: ${base}/agents/${agentId}/edit` : ''}.`);
  lines.push(`- Its tools and MCP servers${base ? `: ${base}/tools` : ''}.`);
  if (item.action?.label) {
    lines.push(`- On the dashboard: **${item.action.label}**${item.action.hint ? ` (${item.action.hint})` : ''}${base && item.action.path ? ` ${base}${item.action.path.startsWith('/') ? '' : '/'}${item.action.path}` : ''}.`);
  }

  if (target === 'sandbox') {
    lines.push('', '- Find the agent in app/agents/ and its prompt views in app/views/agents/.', '', '## Verify', '',
      '1. Change the agent, not the scenarios or their expectations.',
      '2. Run the relevant tests in this checkout. Do not commit or push.',
      `3. The dashboard will re-run these scenarios when you finish: ${keys.join(', ')}; models: ${models.join(', ')}.`,
      '', 'Summarize your changes. Do not read or copy the sandbox’s Claude credentials.');
  } else {
    lines.push('', ...verifyLines({ evaluation, run, runNumber, keys, models, dashboardUrl }));
  }
  return `${lines.join('\n')}\n`;
};

// The brief for one of a sampling run's What-to-fix cards.
export const samplingFixPromptMarkdown = ({ item, evaluation = null, run = null, runNumber = null, agentName = null, dashboardUrl = '' } = {}) => {
  if (!item) return '';
  const lines = [`# ${fixPromptTitle(item)}`, '', ...contextLines({ evaluation, run, runNumber, agentName, dashboardUrl }), ''];
  lines.push('## What went wrong', '');
  lines.push(`${item.label || words(item.kind)}${item.scope ? ` · ${item.scope}` : ''}.`);
  if (item.text) lines.push('', trim(item.text));
  if (Array.isArray(item.chips) && item.chips.length) {
    lines.push('', `${item.chipsLabel ? item.chipsLabel[0].toUpperCase() + item.chipsLabel.slice(1) : 'Items'}: ${item.chips.slice(0, MAX_LIST).map(code).join(', ')}${item.chips.length > MAX_LIST ? ` and ${item.chips.length - MAX_LIST} more` : ''}.`);
  }
  if (Array.isArray(item.details) && item.details.length) {
    lines.push('');
    item.details.slice(0, MAX_LIST).forEach((detail) => lines.push(`- ${trim(detail)}`));
    if (item.details.length > MAX_LIST) lines.push(`- and ${item.details.length - MAX_LIST} more`);
  }
  const criteria = (evaluation?.criteria || []).filter((criterion) => (item.chips || []).includes(criterion?.key));
  if (criteria.length) {
    lines.push('', '## Criteria', '');
    criteria.forEach((criterion) => {
      lines.push(`- ${code(criterion.key)} (${criterion.type})${criterion.config && Object.keys(criterion.config).length ? `: ${JSON.stringify(criterion.config)}` : ''}`);
    });
  }
  const base = trimSlash(dashboardUrl);
  lines.push('', '## Where to look', '');
  const agentId = evaluation?.agent?.id;
  lines.push(`- The agent's instructions, model config and tools${base && agentId != null ? `: ${base}/agents/${agentId}/edit` : ''}.`);
  if (item.action?.label) {
    lines.push(`- On the dashboard: **${item.action.label}**${item.action.hint ? ` (${item.action.hint})` : ''}${base && item.action.path ? ` ${base}${item.action.path.startsWith('/') ? '' : '/'}${item.action.path}` : ''}.`);
  }
  const models = uniq(item.kind === 'missing' ? item.chips || [] : modelLabels({}, run));
  lines.push('', ...verifyLines({ evaluation, run, runNumber, keys: [], models, dashboardUrl }));
  return `${lines.join('\n')}\n`;
};
