---
title: SolidAgent Examples
description: A worked example per concern — persistent conversations, memory hand-offs, tool streaming and caching, reasoning, run tracking and manifests.
---
# {{ $frontmatter.title }}

Six worked examples, one per concern. Each lives in the
[`examples/` directory](https://github.com/activeagents/solid_agent/tree/main/examples)
of the solid_agent repository as files laid out in Rails paths, with a
`usage.rb` console walkthrough alongside — so what you read here you can
also drop into an app.

All of them assume the tables and models are installed:

```bash
bundle add solid_agent
rails generate solid_agent:install
rails db:migrate
```

::: tip Try one without spending tokens
Point the agent at the [mock provider](/providers/mock) —
`generate_with :mock, model: "mock-gpt-4o-mini"`. Persistence, memory, runs
and the tool cache all behave identically; only the model response changes.
:::

## Persistent conversation

**[`examples/persistent_conversation`](https://github.com/activeagents/solid_agent/tree/main/examples/persistent_conversation)** ·
[`HasContext`](/solid_agent/context)

A support agent whose conversation survives the request. Each turn loads
the stored thread, appends the new question, and lets the persistence
callbacks write both halves back.

```ruby
class SupportAgent < ApplicationAgent
  include SolidAgent::HasContext

  generate_with :openai, model: "gpt-4o-mini"

  has_context :conversation, contextual: :user

  def answer
    load_conversation(contextable: params[:user])

    prompt messages: conversation_messages + [
      { role: "user", content: params[:message] }
    ]
  end
end
```

```ruby
SupportAgent.with(user: user, message: "My invoice is wrong").answer.generate_now
SupportAgent.with(user: user, message: "It's the VAT line").answer.generate_now
```

The second call knew about the first because it read the table. The
controller that goes with it renders history straight out of the database
— no session state, nothing to warm up after a deploy:

```ruby
class SupportConversationsController < ApplicationController
  def show
    @conversation = AgentContext.for_agent("SupportAgent").for_action("answer")
      .find_by!(contextable: current_user)
    @messages = @conversation.messages.chronological
  end

  def create
    response = SupportAgent.with(user: current_user, message: params.require(:message))
      .answer.generate_now

    render json: { reply: response.message.content }
  end
end
```

## Memory hand-off

**[`examples/memory_handoff`](https://github.com/activeagents/solid_agent/tree/main/examples/memory_handoff)** ·
[`HasMemory`](/solid_agent/memory)

Two agent classes, one subject. The researcher saves what it learns; the
writer picks it up later — possibly in another request, job or deploy.

```ruby
class ResearcherAgent < ApplicationAgent
  include SolidAgent::HasMemory

  has_memory

  def research
    prompt(
      message: "Research #{params[:project].name} and save what a writer would need to know.",
      tools: memory_tool_definitions
    )
  end

  def memory_subject = params[:project]
end
```

```ruby
ResearcherAgent.with(project: project).research.generate_now
WriterAgent.with(project: project).draft.generate_now

AgentMemory.for(project).recall(limit: 5).map { |e| [ e.source_agent, e.content ] }
# => [["ResearcherAgent", "Ships on the 14th; pricing unchanged"], ...]
```

The writer can also skip the recall round trip entirely by putting the
notes in its instructions:

```ruby
def draft_with_primed_memory
  prompt(
    instructions: [ "You are a product writer.", memory&.to_prompt ].compact.join("\n\n"),
    message: "Draft the launch post for #{params[:project].name}.",
    tools: memory_tool_definitions
  )
end
```

## Tools, live status and caching

**[`examples/tool_streaming`](https://github.com/activeagents/solid_agent/tree/main/examples/tool_streaming)** ·
[`HasTools`, `StreamsToolUpdates`, `ToolCache`](/solid_agent/tools)

One agent with a template-loaded tool, an inline one, live status
broadcasting, and a cache around the expensive call.

```ruby
class BrowserAgent < ApplicationAgent
  include SolidAgent::HasTools
  include SolidAgent::StreamsToolUpdates

  has_tools :fetch_url                        # from a JSON view template

  tool :summarize_page do                     # or inline
    description "Summarize text that was already fetched"
    parameter :text, type: :string, required: true
    parameter :sentences, type: :integer, default: 3
  end

  tool_description :fetch_url, ->(args) { "Fetching #{args[:url]}..." }

  def browse
    prompt tools: tools
  end

  def fetch_url(url:)
    SolidAgent::ToolCache.fetch(tool: "fetch_url", args: { url: url }, ttl: 5.minutes) do
      response = Net::HTTP.get_response(URI(url))

      response.is_a?(Net::HTTPSuccess) ? { body: response.body } : { error: "HTTP #{response.code}" }
    end
  end
end
```

Status broadcasts only when the caller passes a `stream_id`, so the same
agent is silent from a job:

```ruby
BrowserAgent.with(
  stream_id: "tool_status:#{current_user.id}:#{SecureRandom.uuid}",
  message: "Summarize https://rubyonrails.org"
).browse.generate_now
```

## Reasoning

**[`examples/reasoning`](https://github.com/activeagents/solid_agent/tree/main/examples/reasoning)** ·
[`HasReasons`, `Reasonable`](/solid_agent/reasoning)

Extended thinking captured off the response and persisted onto the
generation row, so it's still there after the request ends.

```ruby
class AnalysisAgent < ApplicationAgent
  include SolidAgent::HasContext
  include SolidAgent::HasReasons

  generate_with :anthropic, model: "claude-sonnet-5"

  around_generation :capture_generation_reasoning   # before has_context: outer wrapper

  has_context contextual: :document
  has_reasons persist: true, budget_tokens: 10_000

  def analyze
    prompt message: params[:question], **reasoning_prompt_options
  end

  private

  def capture_generation_reasoning
    response = yield
    capture_reasoning(response)
    response
  end
end
```

```ruby
generation = AgentGeneration.recent.first
generation.reasoning_content
generation.reasoning_tokens
```

## Run tracking

**[`examples/run_tracking`](https://github.com/activeagents/solid_agent/tree/main/examples/run_tracking)** ·
[`AgentRun`, `RunFingerprint`, `ModelPricing`](/solid_agent/runs)

The shape most background agent work takes: a controller creates the run so
the client has an id to poll, a job executes it, a service drives the
lifecycle and appends progress events.

```ruby
class DocumentAnalysisRun
  def initialize(run)
    @run = run
  end

  def call
    @run.record_instructions(ReportAgent::INSTRUCTIONS)
    @run.start!
    @run.append_event(kind: "llm", label: "analyze", eid: "gen-1", status: "started")

    response = ReportAgent.with(
      document: @run.runnable, question: @run.input_prompt, trace_id: @run.trace_id
    ).analyze.generate_now

    @run.append_event(kind: "llm", label: "analyze", eid: "gen-1", status: "done")
    @run.complete!(
      output: response.message.content,
      input_tokens: response.usage&.input_tokens,
      output_tokens: response.usage&.output_tokens
    )
  rescue StandardError => e
    @run.fail!(e)
    raise
  end
end
```

Polling reads whatever has landed so far:

```ruby
def show
  run = AgentRun.find(params[:id])

  render json: { status: run.status, events: run.events, output: run.output }
end
```

And because every run carries a fingerprint of the instructions it ran
under, "did the new prompt help?" is a group-by:

```ruby
AgentRun.for_agent("ReportAgent").where(status: "complete")
  .group(:instructions_digest).average(:duration_ms)
  .transform_keys { |d| SolidAgent::RunFingerprint.codename(d) }
# => { "calm-heron" => 2400.0, "misty-atoll" => 1810.0 }
```

## Manifests

**[`examples/manifests`](https://github.com/activeagents/solid_agent/tree/main/examples/manifests)** ·
[`AgentManifest`](/solid_agent/manifests)

An agent defined in a file — model, tools, schemas and instructions —
validated in CI and built into a class at runtime.

```ruby
path = "config/agents/changelog_writer.agent.md"

SolidAgent::AgentManifest.validate(path)  # => [] in CI
manifest = SolidAgent::AgentManifest.parse(path)

klass = SolidAgent::AgentManifest.load_agent(path, class_name: "ChangelogWriterAgent")
klass._manifest_model         # => "claude-sonnet-4-20250514"
klass._manifest_instructions  # the Markdown body

SolidAgent::AgentManifest.convert(path, :crewai, "tmp/agents.yaml")
```

## Larger examples

Two full applications built on SolidAgent:

- [Fizzy](https://github.com/tonsoffun/fizzy) — Kanban tracking with writing, research and file analysis agents
- [Writebook](https://github.com/tonsoffun/writebook) — collaborative writing with an integrated writing assistant
