// Context pressure: what the biggest generation in a trace held against the
// model's window.
//
// Kept apart from the components that render it so it can be tested directly.

// Context-window sizes by model family. The provider reports real token
// counts; the window is the constraint we hold them against.
export const contextWindowFor = (model) => {
  const name = (model || '').toLowerCase();
  if (name.includes('claude')) return 200000;
  if (name.includes('gemini')) return 1000000;
  if (name.includes('llama')) return 131072;
  if (name.includes('gpt-4o') || name.includes('gpt-4-turbo') || name.includes('gpt-4.1')) return 128000;
  if (name.includes('gpt-5')) return 400000;
  return 128000;
};

// ~4 chars/token, for estimating segment sizes from recorded content.
export const estimateTokens = (value) => {
  if (value == null) return 0;
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return Math.round(text.length / 4);
};

// Context pressure: what the biggest generation in this trace held against the
// model's window. The input and output totals are the provider's own counts;
// how the input divides across the segments is apportioned, from a recorded
// `*.tokens` size where the span carries one and a ~4 chars/token estimate of
// the stored preview otherwise.
export const traceContext = (trace) => {
  const spans = trace?.spans || [];
  let peak = null;
  for (const span of spans) {
    const tokens = span.tokens || {};
    const total = (tokens.input || 0) + (tokens.output || 0);
    if (total > 0 && (!peak || total > peak.total)) {
      peak = {
        input: tokens.input || 0,
        output: tokens.output || 0,
        thinking: tokens.thinking || 0,
        cached: tokens.cached || 0,
        total,
      };
    }
  }
  if (!peak) return null;

  const attr = (key) => {
    for (const span of spans) {
      const value = (span.attributes || {})[key];
      if (value) return value;
    }
    return null;
  };
  // Both telemetry shapes: ActiveAgent SDK (prompt.input.*, tool.input/
  // output.*) and the RubyLLM adapter (llm.instructions/tools,
  // tool.arguments/result).
  // A recorded *.tokens attribute is the real size, measured before the
  // content attribute was truncated for storage. Estimating from the stored
  // preview instead understates whatever the clip dropped — and for tool
  // schemas the preview is a lossy roster, not the schema the model was sent.
  // Fall back to estimating only for traces recorded before those counts
  // existed, or from adapters that do not emit them.
  const sized = (tokenKey, ...contentKeys) => {
    const recorded = Number(attr(tokenKey));
    if (Number.isFinite(recorded) && recorded > 0) return recorded;
    for (const key of contentKeys) {
      const value = attr(key);
      if (value) return estimateTokens(value);
    }
    return 0;
  };

  const instructions = sized('prompt.input.instructions.tokens', 'prompt.input.instructions', 'llm.instructions');
  const toolSchemas = sized('prompt.input.tools.tokens', 'prompt.input.tools', 'llm.tools');
  const mcpSchemas = sized('prompt.input.mcp_tools.tokens', 'prompt.input.mcp_tools');
  let toolResults = 0;
  for (const span of spans) {
    const attrs = span.attributes || {};
    const result = attrs['tool.output.result'] || attrs['tool.result'];
    const args = attrs['tool.input.args'] || attrs['tool.arguments'];
    if (result) toolResults += estimateTokens(result);
    if (args) toolResults += estimateTokens(args);
  }
  toolResults = Math.min(toolResults, peak.input);

  // The segments are ~4 chars/token approximations of individual pieces, while
  // `peak.input` is the provider's own prompt_tokens for all of them together.
  // Charging the difference to "Messages" — subtracting the segments from the
  // total — makes that one segment absorb the whole approximation error, so a
  // trace with dense JSON tool schemas reads as a large message history that
  // was never sent. Scaling the segments to fit the real total spreads the
  // error over the pieces it came from instead.
  //
  // The segments still cannot exceed the total, so the remainder is floored at
  // zero, and it is the segment that carries whatever the others did not claim.
  const estimatedInput = instructions + toolSchemas + mcpSchemas + toolResults;
  const scale = estimatedInput > 0 && peak.input > 0 ? peak.input / estimatedInput : 1;
  const scaled = (value) => Math.round(value * scale);

  const inputSegments = {
    instructions: scaled(instructions),
    toolSchemas: scaled(toolSchemas),
    mcpSchemas: scaled(mcpSchemas),
    toolResults: scaled(toolResults),
  };
  const attributed = inputSegments.instructions + inputSegments.toolSchemas +
    inputSegments.mcpSchemas + inputSegments.toolResults;
  // Whatever prompt_tokens holds beyond the parts we can attribute is the
  // message transcript plus the provider's own framing overhead.
  const messages = Math.max(peak.input - attributed, 0);

  return {
    used: peak.total,
    limit: contextWindowFor(trace.model),
    cached: peak.cached,
    thinking: peak.thinking,
    // The provider reports the input and output totals; how the input divides
    // across the segments below is apportioned from them, so the meter labels
    // itself estimated whenever any segment was sized here.
    estimated: estimatedInput > 0,
    segments: [
      { key: 'messages', label: 'Messages', tokens: messages },
      { key: 'tool_results', label: 'Tool results', tokens: inputSegments.toolResults },
      { key: 'instructions', label: 'Instructions', tokens: inputSegments.instructions },
      { key: 'tool_schemas', label: 'Tool schemas', tokens: inputSegments.toolSchemas },
      { key: 'mcp_schemas', label: 'MCP tool schemas', tokens: inputSegments.mcpSchemas },
      { key: 'output', label: 'Generated output', tokens: peak.output },
    ],
  };
};
