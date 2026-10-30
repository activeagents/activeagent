# Evaluations

`ActiveAgent::Evals` is the evaluation core the dashboard's
[scenario evaluations](/framework/dashboard#scenario-evaluations) run on. It
ships inside the `activeagent` gem so any Rails app on ActiveAgent — and, with
one `require`, any app that calls models another way — can replay a list of
tasks across models, score the answers, and be told which tasks its agent
cannot do yet and why.

```ruby
require "active_agent/evals"   # loads on its own, without the rest of the framework
```

The module never talks to a model itself: you hand it one callable that runs
your agent, and optionally one that asks a judge model for a completion.

## What it does

1. **Scenarios** — a pasted list of user messages (`ScenarioParser`) or a YAML
   suite with groups (`Suite`). Each scenario can name the tools a passing
   answer should call and content it must or must not contain.
2. **Models** — candidate models to compare (`ModelSpec`), from
   `provider/model` or a bare name whose provider is inferred.
3. **Replay** — your callable runs the agent for each scenario × model and
   returns a `Replay`: answer, tool calls (with errors), timing, tokens, cost.
4. **Scoring** — rule criteria (`response_present`, `min_length`,
   `max_latency_ms`, `token_budget`, `contains`, `not_contains`, `llm_judge`)
   plus the scenario's expectations (`Scorer`).
5. **Diagnosis** — each shortfall gets exactly one fault and a recommendation
   (`Diagnosis`); a `Judge` can refine it with the tool to add or the
   instruction to change.
6. **Report** — per-model pass rate, mean score, latency, tokens, cost and
   fault counts; criterion statistics; faults grouped across scenarios into
   the fix each calls for; a verdict; Markdown, JSON or a self-contained
   HTML page (`Report`).

## Minimal example

```ruby
require "active_agent/evals"

scenarios = ActiveAgent::Evals::ScenarioParser.scenarios(<<~TEXT)
  # Orders
  Where is my order 4821? | tools: lookup_order
  Cancel my subscription | not_contains: I cannot
TEXT

models = ActiveAgent::Evals::ModelSpec.parse_all(%w[claude-sonnet-5 ollama/qwen3:8b], default_provider: "openai")
# The agent's system prompt, for the diagnosis and the judge — with
# ActiveAgent, the instructions template.
instructions = Rails.root.join("app/views/agents/support/instructions.md").read

report = ActiveAgent::Evals::Runner.new(
  scenarios: scenarios,
  models: models,
  available_tools: { "lookup_order" => "Find an order by number" },
  instructions: instructions,
  replay: ->(scenario, spec) { SupportAgent.evaluate(scenario.prompt, model: spec.model, provider: spec.provider) }
).call

puts report.to_markdown
File.write("eval-report.html", report.to_html)
```

The report renders three ways: `to_markdown` for terminals and PR comments,
`to_json` for machines, and `to_html(theme: nil)` — a self-contained page
(inline styles, no external assets) on the dashboard's design system that you
can archive next to a CI run or hand to a teammate, the way a test suite
publishes its report. It carries the same reading the dashboard's suite card
does, in the same order: stat tiles, a panel per model with the judge's pick
and the verdict, the scenario × model matrix, a disclosure per scenario
holding every answer, and then the what-to-fix cards. `theme:` is its only
argument — `"light"` or `"dark"` pins the palette, nil follows the viewer's
system preference. It is the same page the dashboard serves at
`/api/evaluations/:id/runs/:run_id/report`. Its one inline script backs its
*Copy as Markdown* buttons (with a fallback where the Clipboard API is
refused); nothing is loaded from outside the file.

The Markdown has the same content as the page, in GitHub-flavored Markdown,
because GitHub strips the page's styles when it is pasted into a pull
request: the model table and the run's cost, the best model with the
verdict's rationale, the comparison, the scenario × model matrix, every
answer — one `<details>` block per scenario holding its prompt, expectations,
a table of each model's status, score, tool calls, fault and cost, and each
answer quoted — and **What to fix**, one heading per fix item with its
scenarios and models, the recommendation, the judge's quoted instruction
change, the tools and server involved, and where the fix lives. Table cells
escape `|` and fold line breaks. The pieces people paste one at a time are
public on their own and read exactly as they do in the whole report:

```ruby
report.verdict_markdown                         # verdict, model table, comparison
report.fix_items_markdown                       # What to fix
report.fix_items_markdown(model: "gpt-5-mini")  # What to fix for one model
report.fix_item_markdown(report.fix_items.first)
report.scenario_markdown("order_lookup")        # one scenario, every model's result
```

`SupportAgent.evaluate` is whatever runs your agent and returns an
`ActiveAgent::Evals::Replay` (or a hash with the same keys). With ActiveAgent
that is a `prompt(...).generate_now` under `generate_with spec.provider,
model: spec.model`; with RubyLLM it is a chat with the model overridden; the
module does not care.

## Adding a judge

```ruby
judge = ActiveAgent::Evals::Judge.new(label: "claude-opus-5") do |instructions:, prompt:|
  JudgeAgent.prompt(message: prompt, instructions: instructions).generate_now.message.content
end

ActiveAgent::Evals::Runner.new(scenarios:, models:, replay:, judge: judge, instructions: instructions).call
```

With a judge, every answer also gets a `task_completion` score (unless the
criteria already include an `llm_judge`), scenarios failing on
`missing_capability`, `expected_tool_not_called`, `ungrounded_answer`,
`missing_content` or `low_quality` get a judge-written recommendation with a suggested tool where
one is missing (`refine_faults:` and `judge_limit:`, 25 calls per run by
default, adjust that on `Runner.new`), and the verdict carries the judge's
rationale. A judge that raises or answers unusably is skipped for that call,
so an evaluation never fails because the judge did.

A scorable `task_completion` grade must independently meet the run's
`threshold` (0.7 by default). Successful tool and content checks cannot turn
a failing task-completion grade into a pass. `score` and `avg_score` remain
the aggregate across scored criteria; `avg_task_completion` in each model's
summary reports the judge's task-completion mean separately. Invalid judge
scores are unscorable, and unusable recommendation fields are discarded.

Hosts can correlate the replay and its judge calls with one trace context by
passing `around_evaluation:` to `Runner.new`. The callable receives the
scenario and model spec, yields the evaluation, and returns its result:

```ruby
around_evaluation = ->(scenario, spec, &evaluate) do
  TraceContext.with(scenario_key: scenario.key, model: spec.label) { evaluate.call }
end
```

The wrapper covers replay, scoring and recommendations. `on_result` runs
after the wrapper finishes; wrapper errors propagate. Direct
`Runner#evaluate` calls bypass the wrapper so a host doing its own scheduling
can establish context itself.

### Correlating traces with results

`Correlation` is that wrapper, written once against a telemetry backend
instead of per host. It mints a `run_id` per run and a `result_id` per
evaluation, puts both on every trace opened inside them as `eval.`-prefixed
attributes, and records the trace ids back onto the result:
`replay.metadata["trace_id"]` for the replay and `["judge_trace_ids"]` for the
judge calls that graded it. A judge call made outside an evaluation — the
run-level verdict — lands on the run metadata instead, which is the hash the
Report carries, so the verdict is reachable from the report rather than
attributed to the last result evaluated.

```ruby
correlation = ActiveAgent::Evals::Correlation.new(
  agent_name: "SupportAgent",
  judge_name: "SupportAgentJudge",
  tracer: ->(name, action:, attributes:, on_trace:, &block) {
    MyTelemetry.with_agent(name, action: action, attributes: attributes,
                           on_trace: on_trace, synchronous: true, &block)
  }
)

report = correlation.with_run("suite" => "support") do |metadata|
  Runner.new(
    scenarios: scenarios, models: models, metadata: metadata,
    around_evaluation: correlation,
    replay: ->(scenario, spec) { correlation.replay { agent.run(scenario.prompt) } },
    judge: Judge.new(label: "judge-model") { |instructions:, prompt:|
      correlation.judge("score") { chat.with_instructions(instructions).ask(prompt).content }
    }
  ).call
end
```

Pass the yielded metadata to `Runner.new(metadata:)`: it is the caller's own
hash, mutated in place, so a run reopened around a later verdict accumulates
onto the metadata the Report already carries.

The tracer is injected, so the evaluation module takes on no telemetry
dependency and still loads on its own. Without one, the correlation mints ids
and merges metadata while the blocks run untraced, which keeps a suite
runnable where no telemetry is configured. `trace_keys:` chooses which
correlation keys become attributes — the default is `run_id`, `result_id`,
`suite`, `scenario_key`, `model_label`, `model` and `provider`, and anything
else in the run metadata stays on the report but off the traces.

### RubyLLM hosts

An app that drives RubyLLM conversations — `RubyLLM.chat`, `acts_as_chat`
records — needs two more pieces to run a suite: a judge that asks a RubyLLM
chat, and a `Replay` built from the messages a conversation produced.
`ActiveAgent::Evals::RubyLLM` is both, loaded by its own require so
`require "active_agent/evals"` never pulls in the `ruby_llm` gem. Both
RubyLLM 1.x (1.16 and later) and 2.x work.

```ruby
require "active_agent/evals/ruby_llm"   # requires ruby_llm itself
```

**`judge`** builds a `Judge` whose completions come from
`context.chat(model:, provider:, assume_model_exists:)`, then
`with_instructions(instructions).ask(prompt).content`. `context` is anything
answering to `chat` — `RubyLLM` itself, or a `RubyLLM.context` built with the
host's own keys (the dashboard's `ActionAgent::ProviderKey.apply_to` writes an
owner's keys onto that config block). With a `correlation:`, every call is
traced through `Correlation#judge` under the kind it serves (`score`,
`recommend`, `verdict`), so the judge trace lands on the result it graded.

- `temperature:` is applied with `with_temperature`, and `configure:` is
  called with each chat before it is asked, for any other `with_*` setting.
- Any other keyword goes to `chat` itself, so it must be one
  `RubyLLM::Chat.new` takes — `protocol:` on RubyLLM 2.x. Anything else raises
  `ArgumentError` when the judge is built, not on every call.
- `on_usage:` is called after each answered call with
  `{ "kind", "model", "input_tokens", "output_tokens", "cost" }`, for a host
  that meters what its judge spends. An error it raises is logged, never
  allowed to cost the grade.

**`replay`** turns an ordered list of messages — `acts_as_chat` records of
either RubyLLM generation, `RubyLLM::Message` values, an Array or a relation —
into a `Replay`. Records are read through their own `to_llm`, so the replay
sees what RubyLLM itself would send the model, whichever schema the table has.

- **Tool calls** come in the order the model made them. A call is errored
  when the result answering it reports an error at its top level: JSON whose
  `"error"` is a non-empty string, object or array, or `true`; an MCP result
  with `"isError": true`; or the inspected `{ error: "..." }` RubyLLM 1.x
  stores when a tool returns an error Hash with a String error. Text that
  merely mentions an error — a log line, source code — is a successful
  result. The error is the call's `detail`, JSON-encoded unless it is a
  string and cut to 1,200 bytes.
- **Tokens** are summed over the assistant messages. `input_tokens` is the
  whole prompt: RubyLLM counts cache reads and writes apart from its `input`,
  and the replay adds them back.
- **Cost** is the sum of RubyLLM's own price for each assistant message, and
  is left nil when any of them is unpriced rather than reporting part of it.
- **The answer** is the last assistant message after the last user message.
  A conversation that stopped before answering has no answer, and the
  replay's `error` says where it stopped: at a tool call or its result (a
  tool awaiting approval, a run cut short), or on the user's own message (a
  run that failed after the prompt was saved). On RubyLLM 1.x a tool that
  ends the turn with `halt` also leaves its result last; for such scenarios
  pass the content `ask` returned as `answer:`.

`answer:`, `error:` and `cost:` override what the messages say;
`duration_ms:` and `metadata:` pass through.

Put together with a correlation, and with the replays and judge calls reported
through the `activeagents-telemetry-ruby_llm` adapter (0.3.0 or later, whose
`with_agent` takes `attributes:`, `on_trace:` and `synchronous:`; 0.3.1 or
later on RubyLLM 2.x, for token counts):

```ruby
require "active_agent/evals/ruby_llm"

context = RubyLLM.context { |config| ActionAgent::ProviderKey.apply_to(config, owner: account) }

correlation = ActiveAgent::Evals::Correlation.new(
  agent_name: "SupportChat",
  tracer: ->(name, action:, attributes:, on_trace:, &block) {
    ActiveAgents::Telemetry::RubyLLM.with_agent(name, action: action, attributes: attributes,
                                                on_trace: on_trace, synchronous: true, &block)
  }
)

judge = ActiveAgent::Evals::RubyLLM.judge(
  label: "claude-opus-5", model: "claude-opus-5", provider: :anthropic,
  context: context, correlation: correlation, temperature: 0
)

report = correlation.with_run("suite" => "support") do |metadata|
  ActiveAgent::Evals::Runner.new(
    scenarios: scenarios, models: models, metadata: metadata, judge: judge,
    around_evaluation: correlation,
    replay: ->(scenario, spec) {
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      chat = correlation.replay { SupportChat.run(scenario.prompt, model: spec.model, context: context) }
      ActiveAgent::Evals::RubyLLM.replay(
        chat.messages.order(:id),
        duration_ms: Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - started,
        metadata: { "chat_id" => chat.id }
      )
    }
  ).call.tap(&:verdict)
end
```

`tap(&:verdict)` asks for the verdict while the run is still open. The
verdict is computed on first use, and a judge call made after `with_run` has
returned is traced without the run's `eval.run_id`, its trace id never
reaching `report.metadata["judge_trace_ids"]`.

Two things about the adapter to know:

- **Trace ids are recorded only for traces the adapter accepted for
  delivery.** A trace dropped by `sample_rate` or a disabled configuration
  never reaches `on_trace`, so its result carries no `trace_id`.
- **Keep your own `with_agent` scope out of code a replay runs** on adapter
  releases up to 0.3.1. There a nested `with_agent` — such as a "name your
  traffic" scope around `chat.ask` — replaces the evaluation's scope for the
  turns inside it: their traces lose the `eval.*` attributes, delivery goes
  back to the background thread, and the result never receives its
  `trace_id`. Check the adapter's changelog for nested-scope support before
  relying on it.

To run such a suite from the mounted dashboard rather than a script, return
it from a host adapter — see
[Running a host application's agent from the mounted dashboard](#running-a-host-application-s-agent-from-the-mounted-dashboard).

### Jev as a judge

A "System One" model generates no text. A request carries a `state` (the
text to judge) and named questions — a Score over described levels, a
Choice over options, a yes/no — and the answer is one structured decision
per question with a calibrated probability behind it. Two of the three
calls a judge serves end in exactly such a decision, so
`ActiveAgent::Evals::Jev` builds a `Judge` that sends those to one and
leaves the language tasks to an ordinary judge. Two servers speak the
protocol: Jev, TypeSafe AI's hosted model (closed weights, an API key,
billed on input tokens only), and [OpenJevX](https://github.com/muthuishere/openjevx),
an Apache-2.0 re-implementation of about 0.4B parameters that answers on a
laptop CPU in tens of milliseconds and runs as a container beside your own
services. The judge is loaded by its own require and talks to either with
the standard library's `Net::HTTP`, so it adds no gem.

```ruby
require "active_agent/evals/jev"

text_judge = ActiveAgent::Evals::Judge.new(label: "claude-haiku-4-5") do |instructions:, prompt:|
  JudgeAgent.prompt(message: prompt, instructions: instructions).generate_now.message.content
end

# Hosted Jev, the key from TYPESAFE_API_KEY:
judge = ActiveAgent::Evals::Jev.judge(
  label: "jev-latest",                  # how reports name the judge
  api_key: ENV["TYPESAFE_API_KEY"],     # the default
  model: "jev-latest",                  # the hosted default; also jev-1.13, jev-preview
  base_url: "https://api.typesafe.ai",  # the default
  text_judge: text_judge,               # optional
  on_usage: ->(usage) { meter(usage) }  # optional
)

# OpenJevX on this machine, no key and no model name:
judge = ActiveAgent::Evals::Jev.judge(
  label: "openjevx",
  base_url: ActiveAgent::Evals::Jev::OPENJEVX_BASE_URL,  # http://127.0.0.1:21118
  text_judge: text_judge
)

ActiveAgent::Evals::Runner.new(scenarios:, models:, replay:, judge: judge, instructions: instructions).call
```

- **`:score`** (`score_task` and `score_criterion`) is one Score question
  over the gem's own scoring prompt — the criterion or the task, the user's
  message and the answer, without the closing request for JSON that a
  language model needs. The question's criteria are five described levels,
  from "fails completely" to "fully satisfies"; the model answers the
  expected level, which is normalised to 0..1 by the last one and returned
  as the `{"score": 0.8}` the gem's parser already reads and clamps.
- **`:verdict`**'s winner is one Choice whose options are the compared
  models' labels, each described by its results line (pass rate, mean score,
  latency, cost, faults). The rationale is written by `text_judge`, asked
  the same instructions and prompt; without one it is a sentence naming the
  probability ("Chosen by Jev with probability 0.81."). A choice that is not
  one of the labels is discarded, and the report falls back to its pass-rate
  verdict.
- **`:recommend`** is a language task and goes to `text_judge` whole; without
  one it is nil, which the runner treats as no recommendation.
- `on_usage:` is called after each answered call with
  `{ "kind", "model", "input_tokens", "output_tokens", "cost" }`. Output
  tokens are always 0 and the cost nil, since nothing is generated and the
  price per input token is not yet known; input tokens are nil when the
  server reports none, as OpenJevX does not. An error it raises is logged,
  never allowed to cost the grade.

A request that fails — the endpoint unreachable, a rejection (a 401 or 403
says to check `TYPESAFE_API_KEY`), a body that is not JSON — raises inside
the judge's block and so becomes a nil answer with a warning, as any judge
failure does.

**Running one locally.** `docker compose up -d --build` in OpenJevX's
repository serves the protocol at `http://127.0.0.1:21118` with the model
inside the container; the same model folder also runs in-process in Python
(`openjevx.py` on its [Hugging Face page](https://huggingface.co/muthuishere/openjevx)).
Point `base_url:` at it and omit the key. The opt-in test
`test/evals/jev_openjevx_test.rb` runs the judge against such a server
(`OPENJEVX_URL=http://127.0.0.1:21118 bin/test test/evals/jev_openjevx_test.rb`)
and checks the shape of its judgement — a complete answer grades above a
refusal, a verdict picks a compared model — so an install can verify the
wire format without a vendor key. The heavier open alternatives
(`autotrust/JEV-9B` and up, Qwen3.5 fine-tunes served with vLLM on a GPU)
speak the same request shape and work the same way.

**The wire format** lives in `ActiveAgent::Evals::Jev::Client` alone. It is
the protocol as OpenJevX documents and serves it, which OpenJevX states
matches TypeSafe's `POST /v1/systemone`; TypeSafe's own reference was not
reachable when this was written, so against the hosted endpoint that is the
best evidence rather than a confirmation. Every field of a request or a
response is read in that one class, whose doc comment states the shapes, so
a difference is a one-file fix.

## Faults

| Fault | Meaning |
|---|---|
| `run_error` | The replay raised, or the agent returned nothing |
| `tool_error` | A tool the agent called returned an error |
| `missing_capability` | The agent said no tool covers the task |
| `expected_tool_not_called` | The scenario expects a tool the agent did not call |
| `ungrounded_answer` | The agent had tools, called none, and still stated specifics (a count, an id, a date) nothing supplied |
| `forbidden_content` / `missing_content` | A content expectation failed |
| `low_quality` | The answer scored below the threshold (0.7) |

Assigned in that order, most mechanical cause first. `missing_capability`
and `expected_tool_not_called` are what turn a pasted list of *new* tasks into
a backlog: they say which tasks the current toolset cannot reach and, with a
judge, which tool to add.

## What to fix

`Report#fix_items` is that backlog as data — one item per fault, in the same
order as `recommendations`, plus one per distinct instruction change the judge
proposed. Each names the scenarios and models it speaks for, the fix it calls
for, and the tools involved: the missing tools a scenario expected, the tools
that errored, or the tools the judge suggested adding, under a `tools_label`
that says which.

```ruby
report.fix_items.first
# => { "kind" => "fault", "fault" => "expected_tool_not_called", "count" => 3,
#      "scenario_keys" => [...], "models" => ["gpt-5-mini", "ollama/qwen3:8b"],
#      "recommendation" => "Enable refund_order for the agent…",
#      "quote" => nil, "tools_label" => "missing tools",
#      "tools" => [ { "name" => "refund_order", "note" => nil, "server" => {…} } ],
#      "server" => { "key" => "orders", "name" => "Orders", "status" => "available" },
#      "note" => nil,
#      "action" => { "label" => "Enable Orders for SupportAgent",
#                    "hint" => "MCP Services ->", "path" => "/mcp/orders" } }
```

Optional keywords on `Report.new` fill that in, and the HTML page renders
whatever they supply:

| Keyword | What it adds |
|---|---|
| `tool_resolver:` | A callable `name -> { "key", "name", "status" }` (`"enabled"`, `"available"` or `"unknown"`) naming the server behind a tool, so an item can say a tool exists but is not turned on |
| `agent_name:` | How an item names the agent (`"the agent"` by default) |
| `links:` | Route templates for the actions — `"mcp"` (`"/mcp/%{key}"`), `"tools"`, `"instructions"`. Without them an action still carries its label and hint, with `"path" => nil` |
| `verdict:` / `judge_label:` | A verdict already recorded for these results, so a report rebuilt from stored results shows the pick that run made rather than ranking them again |
| `comparison:` | A comparison already recorded for these results (`Comparison#to_h`), so a rebuilt report renders its intervals rather than resampling them (see [Is the gap real?](#is-the-gap-real)) |

Nothing here needs the dashboard: a CI job that hands `Report.new` a resolver
over its own MCP configuration gets the same cards in its HTML report, and
the same JSON to open issues from.

## Costs

Every surface writes a pass count, a score and a cost the same way
(`ActiveAgent::Evals::Format`, which the dashboard copies in
`evalFormat.mjs`):

| Figure | Reads as |
|---|---|
| A pass/fail fraction | `14/16 · 88%` (`14/16 (88%)` in Markdown); nothing scored is `—` |
| A 0..1 score — mean score, criterion score, task completion, judge confidence | `93%` |
| The pass threshold | `pass ≥ 70%` |
| Money | `$0.0243` when reported; `~$0.0243` when any part was estimated from tokens × model rates; four decimals, six below $0.001, `$0.00` for an explicit zero |

Percentages round half up to whole numbers. Stored values stay 0..1 and USD.
A report that shows a `~` figure carries the legend once, in its footer:
*~ estimated from tokens × model rates*. An estimated figure's tooltip shows
the working (`estimated: 2,328 in × $5.00/M + 423 out × $30.00/M · catalog
rate`, plus `(fallback rate)` for a rate guessed from the model's name).

A `Replay`'s `cost` is what its answer cost; three optional keys in its
`metadata` say more, and the report reads them back
(`Result#cost_source`, `#cost_rate`, `#judge_usage`):

```ruby
ActiveAgent::Evals::Replay.new(
  answer: answer, input_tokens: 2_328, output_tokens: 423, cost: 0.02433,
  metadata: {
    "cost_source" => "estimated",      # reported | estimated | no_usage | unpriced
    "cost_rate" => { "input" => 5.0, "output" => 30.0, "source" => "catalog" },  # $ per million tokens
    "judge_usage" => { "calls" => 1, "input_tokens" => 400, "output_tokens" => 20, "cost" => 0.0015,
                       "model" => "claude-opus-5", "by_kind" => { "score" => 1 }, "source" => "traces" }
  }
)
```

A cost with no `cost_source` is the caller's own figure (`reported`); no
cost at all is `unpriced`. `judge_usage` is what the judge spent on that
one result; calls no result owns — the verdict, authoring criteria — go to
the report as `Report.new(judge_usage: { "calls" => 1, ... })`.

From those, `Report#summary_by_model` adds, per model, the `reported` and
`estimated` counts behind `cost` and `priced`, and `judge_cost` and
`judge_calls`; `Report#scenario_costs` gives each scenario's cost across
the models, the judge's, their `total`, whether any part is `estimated`,
and the same per model label; and `Report#judge_usage` sums every result's
judge calls with the run-level part (`"run"`). The judge's cost is the
evaluation's own overhead and never joins the agent's: it is not part of
the verdict's ranking, nor of the prompt the judge is asked to rule with.
`Report#to_h` carries `judge_usage` only when there is one.

`Report.new(release:)` (or `Runner.new(release:)`) names the release of the
agent the run scored, `{ "digest", "revision", "label" }`, from
`ActiveAgent::Release`; it lands in `to_h["release"]` and as a header chip,
and a dashboard the report is published to pins the run to that version.

## Comparing models

`Report#summary_by_model` gives each model its latency three ways:
`avg_duration_ms`, and `p50_duration_ms` and `p95_duration_ms`, the median
and 95th percentile of its timed replays by nearest rank (the value at rank
ceil(p / 100 × n), the rule the dashboard's Metrics view uses, so the figure
is always one a replay actually took). The mean hides the tail: two models
can share a median while one takes twice as long at P95. The Markdown and
HTML reports show both percentiles beside the mean.

Cost is compared on one denominator however many scenarios each model ran:
the Markdown summary's `Cost / 1,000` is what 1,000 scenario runs cost at
the model's mean cost per priced replay, and the HTML report and the
dashboard show the same mean per scenario. It reads with a `~` when the
mean is estimated or covers only some of the model's replays.

### Is the gap real?

A ranking of pass rates says which model did best on these scenarios, not
whether it would again on others. `ActiveAgent::Evals::Comparison` answers
that with intervals:

```ruby
comparison = ActiveAgent::Evals::Comparison.new(results: report.results, models: report.models)

comparison.models["gpt-5-mini"]
# => { "scenarios" => 42, "pass_rate" => 85.7, "interval" => [73.8, 95.2] }
comparison.pairs.first
# => { "models" => ["gpt-5-mini", "qwen3:8b"], "scenarios" => 42, "difference" => 7.1,
#      "interval" => [0.0, 16.7], "decisive" => false }
comparison.conclusion
# => "The pairwise difference interval includes zero: the ranking is not decisive evidence of superiority."
```

- **The scenario is the unit.** A model's pass rate is the mean over its
  scenarios, and each interval resamples whole scenarios with replacement
  5,000 times (the percentile bootstrap, 95% by default).
- **Pairs are paired.** A pair is compared on the scenarios both models ran,
  each resample drawing the same scenarios for both, so the interval is for
  the difference itself rather than two intervals that happen to overlap.
- **Decisive** means the difference's interval excludes zero. `conclusion`
  names each decisive pair, or says that none is.
- **Few scenarios, wide intervals.** With 42 scenarios a 7-point gap is
  usually noise. Below two scenarios there is no interval at all, and
  `conclusion` says the models share too few to compare.
- **Seeded.** `seed:` (0 by default), `resamples:` and `confidence:` go to
  `Comparison.new`; the same results give the same intervals every time.
- **At 0% or 100%** every resample agrees, so the interval is a point. Read
  it beside the scenario count.

A report that compares models carries the same under `Report#comparison`
and in `to_h["comparison"]`, and its Markdown adds a Comparison section
between the summary and the scenario matrix: each model's pass rate with its
interval, every pair's difference with its interval and whether it is
decisive, the conclusion, and how the intervals were computed. A
single-model report has none. The HTML report plots it under the comparison
table: one row per model, best first, its pass rate a dot inside its
interval on a fixed 0 to 100% axis (so a narrow gap is not magnified), with
the figures written beside it, then the conclusion and how the intervals
were computed. `Report.new(comparison:)` takes a comparison
already recorded for the results, as `verdict:` does, so a report rebuilt
from a stored run renders the intervals that run recorded instead of
resampling them.

## In a dashboard

`Runner.new` takes `on_result:` (each `Result` as it lands) and
`Runner#evaluate(scenario, spec, replay)` scores a replay you already hold, so
a dashboard can run replays in background jobs and persist one row per
scenario × model. `Report#to_h` is JSON-ready. The ActionAgent engine's
`ScenarioEvaluationRunner` is the reference integration: it supplies the
replay (an `AgentRun` with a model override), prices tokens, wraps the owner's
judge credentials, and stores each result as an `EvaluationScenarioResult`.
It records a comparison run's `Report#comparison` with the run, computed
once when the run completes (or, for a published report, from the stored
results), and hands it back as `comparison:` when it rebuilds the report, so
the report page does not resample on every view.

`Runner.new(refine_gate:)` takes a callable asked before each recommendation
call, after `judge_limit`. A caller that scores each scenario in its own
`Runner` (one per background job) shares one run-wide limit through it, since
`judge_limit` counts per instance.

### Running scenarios in parallel

By default the engine replays a run's scenarios in one job, one after
another. Turn on fan-out and each scenario × model becomes its own job:

```ruby
ActionAgent.configure do |config|
  config.scenario_evaluation_fan_out = true
end
```

`EvaluationRunJob` then enqueues one `EvaluationReplayJob` per scenario ×
model and returns with the run still running. Each replay is stored as a
pending result and scored by its own `EvaluationJudgeJob`, so the next replay
does not wait on the judge. The job that scores the last pending result
completes the run, under a lock on it, with the same scores, verdict and
judge usage a sequential run records.

Every job runs on the `:agents` queue, so a run is as parallel as your
workers for that queue: Solid Queue with eight threads on `:agents` runs
eight at a time, and a single worker stays sequential. Provider rate limits
become the ceiling; a dedicated queue or a concurrency limit on `:agents` is
how to stay under them. Each worker thread holds a database connection
while it waits on the provider, so keep the pool at least as large as the
thread count.

The agent's tool roster is discovered once, before the replays, and every
scoring job reads it from the run, so a diagnosis names the same tools
whichever job wrote it. A replay job delivered again does not replay a pair
that already has a stored result. A judge job delivered again does not score
a result twice: the job that claims a pending result holds a 30-minute
scoring lease on it, and a delivery that finds the lease live enqueues itself
again for when it expires. When the queue redelivers the job of a worker
that died mid-judge, the redelivery scores the result once that worker's
lease runs out; a duplicate whose first delivery finishes in time finds the
result scored. A worker that finishes after another reclaimed its lease
cannot overwrite that worker's result. A provider call that outlasts the
lease may still be repeated, so set provider timeouts below that interval.
The lease columns come from migration 030, installed with
`bin/rails generate action_agent:install --skip` and `bin/rails db:migrate`;
until it runs, the judge job claims a result by its timestamp alone, which
turns away a stale duplicate but not one delivered after the claim.

A job that fails with an exception outside the replay stores an errored
result, and a failure while completing the run marks it failed. A
scenario removed from the suite while a run is in flight is left out of that
run's results. What no job can recover from is a job lost outright: a worker
killed without a graceful shutdown drops the job it was running
(`ApplicationJob` does not retry), and the run stays in progress with nothing
queued, as a sequential run's one job would. A run that drives a sandbox's
browser, and one a host adapter replays, stay sequential.

A fanned-out run keys its results by provider and model, so a selection that
lists one model under two labels (`gpt-5-mini` and `openai/gpt-5-mini`) is
refused rather than replayed once and reported under one of them.

## The pieces

| Class | Role |
|---|---|
| `Scenario` | One task: prompt, group, expected tools, content that must / must not appear, notes |
| `ScenarioParser` | Pasted text, JSON, or grouped YAML suites → scenarios. Lines, `# Heading` groups, backticked prompts with notes, `\| tools: a, b \| contains: x` options |
| `Suite` | A YAML suite with groups; later documents override by key, so a deployment can add or reword tasks |
| `ModelSpec` | `provider/model` or a bare name with provider inference (`claude-*` → anthropic, `gpt-*` → openai, `name:tag` → ollama, `vendor/model` → openrouter) |
| `Replay` | What your agent produced: answer, tool calls, timing, tokens, cost, error |
| `Scorer` | Rule criteria (`response_present`, `min_length`, `max_latency_ms`, `token_budget`, `contains`, `not_contains`, `llm_judge`) plus the scenario's expectations |
| `Diagnosis` | One fault per failing result, with an evidence-based recommendation |
| `Judge` | Prompts and parsing for scoring, refining recommendations, and picking a winner; you supply the completion call |
| `Runner` | scenarios × models → `Result`s, calling your `replay` and the judge |
| `Report` | Per-model summary, criterion statistics, recommendations, fix items, verdict; Markdown / JSON / HTML |
| `Comparison` | Pass-rate intervals per model and per pair of models, from resampling whole scenarios, and whether the ranking is decisive |

## Suites

```yaml
suite: support_bot
description: The questions the support team fields every week
groups:
  - key: orders
    name: Orders
    scenarios:
      - key: orders_1
        prompt: Where is my order?
        expect:
          tools: [lookup_order]
      - key: orders_2
        prompt: Cancel my subscription
        expect:
          not_contains: ["I cannot"]
        production_only: true   # needs data a local database does not have
```

```ruby
suite = ActiveAgent::Evals::Suite.load("config/evals/support_bot.yml", "config/evals/acme/support_bot.yml")
suite.scenarios(groups: %w[orders], include_production_only: false)
```

The same grouped document can be pasted into `ScenarioParser` as YAML or
JSON. It retains scenario keys, group keys and display names, expectations,
notes and production-only flags:

```ruby
scenarios = ActiveAgent::Evals::ScenarioParser.scenarios(
  File.read("config/evals/support_bot.yml"),
  include_production_only: false
)
```

The parser includes production-only scenarios by default for compatibility
with `Suite`; the dashboard's create and replace APIs exclude them by
default. Post the YAML/JSON document as `scenarios_text` and set
`include_production_only: true` alongside it to include those questions.
For creation both fields belong in `evaluation`; replacement accepts them
at the top level. Production selection happens during import: the dashboard
stores only the selected scenarios and their group keys, not the original
document, group display names, or environment flags. Re-import the source
document to change that selection. Invalid YAML or a selection containing
no scenarios returns an import error without creating a sampled evaluation.

### Refreshing a suite

`Evaluation#replace_scenarios!` writes a catalog's questions onto a
persisted evaluation. A scenario whose key survives keeps its record, so
results from earlier runs still resolve through it.

What happens to a scenario the new attributes no longer name is the
`on_removed:` option:

```ruby
evaluation.replace_scenarios!(attributes)                        # :destroy (default)
evaluation.replace_scenarios!(attributes, on_removed: :disable)  # keep, enabled: false
```

`:destroy` drops the row. `:disable` keeps it with `enabled: false`, which
takes it out of future runs — the runner selects only enabled scenarios —
while leaving the results that scored it readable. Choose `:disable` for a
suite synced from an evolving catalog, where a question can come back or an
old report still needs its rows.

### Adding to a suite

`Evaluation#merge_scenarios!` treats its input as an addition to the suite,
not the whole of it. A scenario whose key the input does not name is never
touched: it keeps its prompt, its position, its `enabled` flag and its
results.

```ruby
attributes = ActiveAgent::Evals::ScenarioParser.parse(
  pasted_text,
  reserved_keys: evaluation.scenarios.pluck(:key),
  key_prefix: "batch2"
).map { |attrs| attrs.except("position") }

evaluation.merge_scenarios!(attributes, limit: 2_000)
# => { added: ["batch2_orders_1"], updated: ["refund_window"], unchanged: [] }
```

- An existing key gets the given prompt, group, notes and expectations, and
  keeps its position and `enabled` flag unless the attributes set
  `"position"` or `"enabled"`. A group, notes or expectations the attributes
  leave out are cleared.
- A new key is appended after the suite's last position, in input order.
- `limit:` refuses, with `Evaluation::ScenarioLimitExceeded`, a merge that
  would leave the suite holding more scenarios than that. A refused or failed
  merge writes nothing.

The parser numbers `"position"` within its own paste, which is why the example
drops it. `reserved_keys:` makes a scenario with no key take the next
`<group>_<n>` the suite does not hold, ignoring case, so merging the same
keyless paste twice adds it twice under distinct keys rather than overwriting
the first copy. `key_prefix:` puts a namespace in front of every generated
key, and raises `ScenarioParser::ParseError` when it has no letters or digits
a key can use. Keys a paste names are kept as they are, so a named key the
suite holds is updated.

The MCP facade's `scenarios_merge` tool does exactly this for a coding
harness (see the [dashboard guide](/framework/dashboard#writing-a-suite-from-your-harness)).

## Catalogs

A suite describes one agent. A catalog describes every agent a team ships:
its **products**, each with the **sets** of scenarios that product must
answer. The document is YAML that lives in the repository next to the agents
it tests, so the prompts are versioned with the code rather than typed into
a dashboard:

```yaml
catalog: support_desk
name: Support Desk
description: What the support agents are expected to handle
products:
  - key: triage
    name: Triage agent
    agent: TriageAgent            # the agent this product's sets run against
    sets:
      - key: smoke
        name: Smoke
        judge:
          kind: rules
        scenarios:
          - key: refund_request
            prompt: A customer asks for a refund on order 1042.
            expect:
              tools: [lookup_order]
              contains: [refund]
            notes: Looks the order up before answering.
            tags: [billing]
            params:
              locale: en
      - key: production
        name: Production data
        scenarios:
          - key: open_tickets
            prompt: Which open tickets mention a refund?
            production_only: true
  - key: billing
    name: Billing agent
    sets:
      - key: smoke
        scenarios:
          - key: invoice_copy
            prompt: Send me a copy of my last invoice.
            expect:
              tools: [send_invoice]
```

Every product, set and scenario has a `key`; a scenario also needs a
`prompt`. A scenario takes the same `expect`, `notes` and `production_only`
as a suite's, plus free-form `tags` and `params` that the runner carries
through to the results. A set may name a `judge` (`kind`, `model`) and
`criteria`, which become the evaluation's when the set is run. Keys the
format does not define (`owner_team`, `repository`, …) are kept as
`metadata` on the catalog, product, set or scenario they sit on. Scenario
extensions are opaque data: they do not add scoring rules. They remain at
their original keys in YAML and JSON exports, including a literal key named
`metadata`, and are available through `scenario.metadata` in Ruby.

```ruby
catalog = ActiveAgent::Evals::Catalog.load("config/evals/support_desk.yml")
catalog.products.map(&:key)                      # => ["triage", "billing"]
catalog.set(:triage, :smoke).scenarios.size      # => 2
catalog.scenarios(product: :triage, include_production_only: false)

suite = catalog.suite_for(:triage, :smoke)       # a Suite named "support_desk/triage/smoke"
ActiveAgent::Evals::Runner.new(suite.all_scenarios, ...)
```

`Catalog.load` takes several paths and `Catalog.new` several documents:
later ones layer over earlier ones by key, so a team-wide catalog can be
narrowed or extended by a local file the way `Suite.load` layers suites. A
suite document (`suite:` and `groups:`) loads as a catalog of one product
whose sets are its groups, so existing suites need no rewrite.

`Catalog#to_yaml` writes the canonical document (format keys in a fixed order,
empty optional format fields dropped) and `Catalog#digest` is the SHA-256 of that text, so
two copies of a catalog can be compared without diffing them. The mounted
dashboard stores catalogs in its own tables, writes the canonical document
to Active Storage and runs one set at a time as an evaluation of the
product's agent; see
[Scenario catalogs](/framework/dashboard#scenario-catalogs). The
`activeagent` command line imports a catalog into that dashboard, previews
what an import would change, and writes the stored records back out as the
canonical YAML or as JSON (`catalogs import|export`; see
[Command Line](/framework/cli#scenario-catalogs)).

Scenario extension fields retain their values, including `false`, `0`,
`null`, empty collections and nested data. Changing only an extension field
changes the catalog's digest. A later document replaces a scenario by key,
including its extensions; omitting a previously supplied extension removes it.
Object key order does not change that digest, including after a JSON database
column reorders the keys. Array order is preserved and remains significant.

## Running a host application's agent from the mounted dashboard

The engine normally replays scenarios with `ActionAgent::Agent#test_execute`.
A host with its own chat or agent runtime can opt individual evaluations
into an adapter without replacing the engine's catalog, selection, jobs,
result persistence, or report pages:

```ruby
ActionAgent.configure do |config|
  config.scenario_evaluation_adapter_resolver = ->(evaluation) do
    next unless evaluation.config["runtime"] == "host_support"

    ->(evaluation:, owner:, scenarios:, models:, on_result:) do
      HostSupportEvaluation.call(
        evaluation: evaluation, owner: owner, scenarios: scenarios,
        models: models, on_result: on_result
      )
    end
  end
end
```

The resolver receives the persisted evaluation and returns a callable or
`nil` for the engine's default runtime. The callable receives the engine's
resolved owner, already-selected core `Scenario` and `ModelSpec` objects,
and an `on_result` callback. It must return an `ActiveAgent::Evals::Report`
and call `on_result` once for every selected scenario/model result. Missing
or duplicate results fail the run instead of leaving a completed report
with missing rows. Exceptions also mark the run failed and retain results
already written.

The host owns provider execution, tool definitions, and judge
configuration. Use the supplied owner rather than a global current user in
background jobs; honor `evaluation.judge_kind`, `evaluation.judge_model`,
and the evaluation's tenant/role configuration. The adapter path does not
build the engine's judge or execute its agent. It still passes through
dashboard authentication, execution enablement, and quota checks.

**Usage accounting is the engine's.** Each result the adapter reports is
metered as one `:execution` against the supplied owner — the same unit the
default replay path records, one per scenario × model. An adapter should
not call `ActionAgent.record_usage` itself, or every replay is counted
twice.

Models reach the adapter already validated: a spec naming a provider the
agent cannot serve fails the run with `ArgumentError` before the adapter is
called, so an adapter does not need to re-check `models.map(&:provider)`.

An observed agent can run a persisted evaluation only when its resolver
returns an adapter. Direct agent execution remains read-only. A host
catalog importer should register that evaluation without an immediate run,
then use the regular evaluation run endpoint.

Run metadata persists in the reserved `scores["_metadata"]` JSON key.
Per-result replay metadata persists in `diagnosis["_replay_metadata"]`,
is exposed separately as `metadata` in result API responses, and is restored
by `EvaluationRun#to_report`. Each result also records its evaluated scenario
in `diagnosis["_scenario_snapshot"]`; the public diagnosis excludes these
storage keys. Report reconstruction and the result matrix use that snapshot,
so refreshing a catalog cannot rewrite old questions, expectations, or notes.
The run records its judge label in `scores["_judge_label"]` as well. Legacy
results without snapshots remain readable using the current catalog.
This preserves host run/result IDs and response/judge trace IDs without a
schema migration. Existing result and report URLs continue to work:

- `<mount>/api/evaluations/:id/runs/:run_id` returns persisted result JSON.
- `<mount>/api/evaluations/:id/runs/:run_id/report` serves the HTML report;
  `report.md` serves it as Markdown (`?part=verdict|fix_items|scenario`, with
  `model=` or `scenario=`, for one piece), `report.json` as the
  [evaluation report envelope](/evals/publication#exporting-a-stored-run), and
  `?download=1` downloads any of them as `<evaluation>-run-<n>.html|md|json`.
- From a terminal, `activeagent evals report RUN --format json|html|md`
  writes the same three for a run's `run_id`, and `activeagent evals import`
  posts the JSON to another install (see [Command Line](/framework/cli#reports)).
- `<mount>/evaluations/:id/runs/:run_id/report` opens it within the dashboard.
- `<mount>/evaluations/:id` opens an evaluation on its run history, and
  `<mount>/evaluations/:id/runs/:run_id` one of its runs — a page of its own
  for a sampling evaluation, the selected run of a suite's panel otherwise.
- `<mount>/evaluations?evaluation=:id` opens a specific evaluation, including
  one outside the first index page. Add `&run=:run_id` to open its saved report.

Every serialized run carries `number` (its position in the evaluation's
history, oldest first), `run_id` (the handle
`GET <mount>/api/evaluation_reports/:run_id` and `activeagent evals report`
take: a published run's own, a dashboard run's
`dashboard-run-<id>-<created_at>`) and `usage`, which keeps the agent's spend apart from
the judge's: `replays` (or `samples`, for a sampling run), `cost`,
`per_interaction`, tokens and timing on the agent's side — what the
interactions cost to serve — and `judge` (`calls`, tokens, `cost`, `model`,
`by_kind`, `source`, `estimated`, and `run` for the calls no result owns)
for the judge model's own calls, present only when a judge was asked.
Every interaction with tokens is priced (`ActionAgent::EvaluationRunCost`):
`priced` and `unpriced` count the interactions, `reported` and `estimated`
say how the priced ones were priced, `cost_basis` sums that up as
`reported`, `estimated` or `mixed`, and `total` is the agent's cost and the
judge's together. A scenario run's per-model summaries under
`scores._models` carry the same per model: `cost` (the effective one),
`priced`, `reported`, `estimated`, `judge_cost` and `judge_calls`. The index
adds `run_count` and a `previous_run` summary per evaluation.

### Routing a pinned judge

An unpinned judge uses the first configured provider in Anthropic, OpenAI,
OpenRouter, Ollama order. A pinned native name selects its native provider:
`gpt-5-mini` uses OpenAI and `claude-haiku-4-5` uses Anthropic. Adding an
unrelated provider key no longer changes that route.

Use a provider-qualified ID to choose a route explicitly. For example,
`openai/my-deployment` sends `my-deployment` through the owner's OpenAI
endpoint, `ollama/llama3.2` sends `llama3.2` to Ollama, and
`openrouter/anthropic/claude-haiku-4.5` sends `anthropic/claude-haiku-4.5`
through OpenRouter. A vendor ID such as `meta-llama/llama-3.3-70b-instruct`
also selects OpenRouter. The pin wins over the credential resolver's model
default; its endpoint and credentials are preserved. Unrecognized bare
custom names retain the default provider behavior.

A pin that starts with a provider name, such as `anthropic/claude-haiku-4-5`
or `openai/gpt-4o-mini`, selects that provider. Earlier releases sent such a
pin to whichever provider had credentials first, so an install with only an
OpenRouter key reached it through OpenRouter. To keep that route, pin
`openrouter/` followed by OpenRouter's own ID, such as
`openrouter/anthropic/claude-haiku-4.5`.

A missing native or explicitly named route does not silently use another
provider. A run that asks the judge fails with an actionable error when
some other provider is configured; a rules-only run ignores the pin, and with
no credentials at all scoring remains skipped. Automatic conversion
of native IDs to gateway aliases, balance checks, outage failover and
cross-provider request retries are not implemented. Pin the gateway's exact
model ID when you want that route. Host evaluation adapters continue to own
their judge execution.
