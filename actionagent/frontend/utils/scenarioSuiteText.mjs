// The suite editor's text form of a scenario suite: one line per scenario,
// `# Group` lines between groups, and the options ActiveAgent's
// ScenarioParser reads back. ActionAgent::Exploration.suite_editor_line
// writes the same line; both are checked against
// test/fixtures/suite-editor-lines.json.

const EXPECTATION_FIELDS = ['tools', 'contains', 'not_contains'];

// The line Save writes for one scenario:
// `prompt | tools: a, b | contains: x | not_contains: y | notes: n | key: k`,
// leaving out the options the scenario has no value for, except its key.
export function scenarioLine(scenario) {
  const expectations = scenario.expectations || {};
  const options = [];
  EXPECTATION_FIELDS.forEach((field) => {
    if (expectations[field]?.length) options.push(`${field}: ${expectations[field].join(', ')}`);
  });
  if (scenario.notes) options.push(`notes: ${scenario.notes}`);
  options.push(`key: ${scenario.key}`);
  return `${scenario.prompt} | ${options.join(' | ')}`;
}

// The suite as the editor shows it, a `# Group` line before each run of
// scenarios in one group.
export function scenariosToText(scenarios) {
  const lines = [];
  let group = null;
  scenarios.forEach((scenario) => {
    if ((scenario.group || '') !== (group || '')) {
      group = scenario.group;
      if (group) lines.push(`# ${group}`);
    }
    lines.push(scenarioLine(scenario));
  });
  return lines.join('\n');
}
