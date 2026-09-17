import assert from 'node:assert/strict';
import test from 'node:test';

import { traceContext } from '../utils/traceContext.mjs';

// The context meter divides one real number — the provider's prompt_tokens —
// among segments it can only approximate. These pin where each segment's size
// comes from, and that the division always adds back up to what was reported.

const trace = ({ attributes = {}, input = 1000, output = 100, spans = [] } = {}) => ({
  model: 'gpt-5.5',
  spans: [
    {
      span_id: 'llm',
      tokens: { input, output, thinking: 0, cached: 0 },
      attributes,
    },
    ...spans,
  ],
});

const segment = (context, key) => context.segments.find((s) => s.key === key).tokens;

test('returns null for a trace whose spans report no tokens', () => {
  assert.equal(traceContext({ spans: [{ span_id: 'a', tokens: {} }] }), null);
  assert.equal(traceContext(null), null);
});

test('prefers a recorded *.tokens size over estimating from the stored preview', () => {
  // The preview is clipped at storage, so estimating from it understates the
  // schema; the recorded count is taken before the clip.
  const context = traceContext(
    trace({
      attributes: {
        'prompt.input.tools': '[{"name":"a"}]',
        'prompt.input.tools.tokens': 900,
        'prompt.input.instructions': 'x'.repeat(400),
      },
    })
  );

  // 900 recorded + 100 estimated instructions = 1000, exactly prompt_tokens.
  assert.equal(segment(context, 'tool_schemas'), 900);
  assert.equal(segment(context, 'instructions'), 100);
  assert.equal(segment(context, 'messages'), 0);
});

test('estimates from content for a trace recorded without the token counts', () => {
  const context = traceContext(
    trace({ attributes: { 'prompt.input.instructions': 'x'.repeat(400) }, input: 1000 })
  );

  // Nothing else is attributable, so the estimate scales to fill the total.
  assert.equal(segment(context, 'instructions'), 1000);
  assert.equal(segment(context, 'messages'), 0);
});

test('reads the RubyLLM adapter attribute names too', () => {
  const context = traceContext(
    trace({ attributes: { 'llm.instructions': 'x'.repeat(400), 'llm.tools': 'y'.repeat(400) } })
  );

  assert.equal(segment(context, 'instructions'), 500);
  assert.equal(segment(context, 'tool_schemas'), 500);
});

test('scales an under-estimate up so the shortfall is not charged to messages', () => {
  // char/4 under-counts dense JSON schemas: the segments estimate 200 tokens
  // where the provider billed 1000. Subtracting instead of scaling would leave
  // 800 in "Messages" for a trace that sent no messages at all.
  const context = traceContext(
    trace({ attributes: { 'prompt.input.tools.tokens': 200 }, input: 1000 })
  );

  assert.equal(segment(context, 'tool_schemas'), 1000);
  assert.equal(segment(context, 'messages'), 0);
});

test('scales an over-estimate down so no segment exceeds the reported input', () => {
  const context = traceContext(
    trace({ attributes: { 'prompt.input.tools.tokens': 4000 }, input: 1000 })
  );

  assert.equal(segment(context, 'tool_schemas'), 1000);
  assert.equal(segment(context, 'messages'), 0);
});

test('attributes MCP schemas separately from the toolbox schemas', () => {
  const context = traceContext(
    trace({
      attributes: {
        'prompt.input.tools.tokens': 300,
        'prompt.input.mcp_tools.tokens': 700,
      },
    })
  );

  assert.equal(segment(context, 'tool_schemas'), 300);
  assert.equal(segment(context, 'mcp_schemas'), 700);
});

test('the input segments always sum to the reported prompt tokens', () => {
  // Three segments that scale to thirds would each round to 333 and lose a
  // token; messages carries the remainder so the bar still fills.
  const context = traceContext(
    trace({
      attributes: {
        'prompt.input.tools.tokens': 100,
        'prompt.input.mcp_tools.tokens': 100,
        'prompt.input.instructions.tokens': 100,
      },
      input: 1000,
    })
  );

  const input = context.segments
    .filter((s) => s.key !== 'output')
    .reduce((sum, s) => sum + s.tokens, 0);

  assert.equal(input, 1000);
});

test('counts tool results from either telemetry shape, capped at the input total', () => {
  const context = traceContext(
    trace({
      input: 1000,
      spans: [
        { span_id: 't1', attributes: { 'tool.output.result': 'r'.repeat(400) } },
        { span_id: 't2', attributes: { 'tool.arguments': 'a'.repeat(400) } },
      ],
    })
  );

  assert.equal(segment(context, 'tool_results'), 1000);
});

test('marks itself estimated only when a segment was sized here', () => {
  assert.equal(traceContext(trace({ attributes: { 'prompt.input.tools.tokens': 100 } })).estimated, true);
  assert.equal(traceContext(trace()).estimated, false);
});

test('holds the peak generation against the model window', () => {
  const context = traceContext({
    model: 'claude-sonnet-5',
    spans: [
      { span_id: 'small', tokens: { input: 10, output: 5 } },
      { span_id: 'big', tokens: { input: 900, output: 100, cached: 40, thinking: 20 } },
    ],
  });

  assert.equal(context.used, 1000);
  assert.equal(context.limit, 200000);
  assert.equal(context.cached, 40);
  assert.equal(context.thinking, 20);
  assert.equal(segment(context, 'output'), 100);
});
