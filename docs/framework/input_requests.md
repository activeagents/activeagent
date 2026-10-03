---
title: Asking the User
description: Pause a generation when a tool needs the user's input, and resume it with the answer — confirmations, free text, choices and secrets.
---
# {{ $frontmatter.title }}

Some tools should not run on the model's word alone. A refund wants a person to approve it; a deploy wants a token the model must never see. A tool can stop the generation, ask the user, and continue once the answer arrives — in the same request or hours later, in another process.

## How it works

1. A tool returns an `ActiveAgent::InputRequest` instead of a result.
2. The provider runs the turn's other tool calls as usual, keeps their results, and ends the generation **paused**. Nothing is sent back to the model.
3. The paused response carries the questions (`input_requests`) and a JSON-safe `checkpoint`.
4. Your app shows the questions, collects answers, and calls `resume_now(checkpoint:, answers:)` on the same agent action.
5. A new generation runs the action again to rebuild its tools and instructions. The conversation is restored from the checkpoint, and each paused tool call runs again — this time with its answer available. All of the turn's results go to the model together, in the order the model asked for them, and the tool loop carries on.

## Asking from a tool

Return a request from any tool method. It is a value, not an exception — never raise it.

```ruby
class SupportAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-sonnet-4-5"

  def handle(ticket_id:)
    prompt(message: "Resolve support ticket #{ticket_id}", tools: SUPPORT_TOOLS)
  end

  def issue_refund(order_id:, amount:)
    return ActiveAgent::InputRequest.confirm("Refund $#{amount} on order #{order_id}?") unless input_answer

    Refund.create!(order_id:, amount:)
    { refunded: amount }
  end
end
```

`input_answer` is the answer for the tool call being run. It is `nil` the first time the tool runs and holds the user's answer when the call runs again on resume. Code outside an agent method can read the same value with `ActiveAgent::InputRequest.answer_for(ActiveAgent::InputRequest.current_tool_call_id)`.

### Kinds of request

| Constructor | Kind | The answer |
|---|---|---|
| `InputRequest.confirm(prompt)` | `:confirm` | `true` approves and runs the tool; `false` declines |
| `InputRequest.text(prompt)` | `:text` | Any text, read by the tool |
| `InputRequest.choice(prompt, options: [...])` | `:choice` | One of `options` (a value, or the `value` of a `{ value:, label: }` hash) |
| `InputRequest.secret(prompt)` | `:secret` | A value the tool uses and the model never sees |

Every constructor also takes `schema:` (a JSON Schema for the answer) and `metadata:` (anything you want to keep with the request). The provider fills in `tool_call_id`, `tool_name` and `arguments`, the arguments the model called the tool with.

Answering `false` declines a request of any kind: the tool does not run again, and the model reads `{"error":"declined by user"}` as its result.

A tool that runs again may return another request — for example a follow-up question after a text answer. The generation then pauses again with a new checkpoint.

## Handling a paused response

```ruby
response = SupportAgent.handle(ticket_id: 42).generate_now

if response.awaiting_input?
  response.input_requests.each do |request|
    request.kind          # => :confirm
    request.prompt        # => "Refund $40 on order 7?"
    request.tool_call_id  # => "toolu_01..."
    request.tool_name     # => "issue_refund"
    request.arguments     # => { "order_id" => 7, "amount" => 40 }
  end

  PendingQuestion.create!(ticket_id: 42, checkpoint: response.checkpoint,
                          requests: response.input_requests.map(&:to_h))
end
```

`response.message` is the assistant turn that made the tool calls, not an answer. `InputRequest#to_h` and `InputRequest.from_h` round-trip a request through JSON.

## Resuming

Call `resume_now` on the generation that paused, or, from another request or job, on one built the same way — same agent, action, arguments and params. Pass the checkpoint with one answer per paused tool call id:

```ruby
question = PendingQuestion.find(params[:id])

response = SupportAgent.handle(ticket_id: question.ticket_id).resume_now(
  checkpoint: question.checkpoint,
  answers: { question.requests.first["tool_call_id"] => params[:approved] == "1" }
)
```

The result is an ordinary response — or a paused one, if a tool asked again.

`resume_now` raises `ActiveAgent::InputRequest::ResumeError` before any tool runs or any request is sent when:

- a paused call has no answer, or an answer names a call that is not waiting;
- a `:confirm` answer is not `true` or `false`, or a `:choice` answer is not one of the options;
- the checkpoint was taken by a different action, provider or model. The checkpoint holds the conversation in the provider's own message format, so it only resumes where it was taken.

To resume in a background job instead, see [Resuming later](#resuming-later).

Calls that finished before the pause are not run again; their results come from the checkpoint. The tool-turn count carries over, so `max_tool_turns` covers the whole generation, pauses included. A forced `tool_choice` stays forced only until the model has used the tool, as it would without the pause: the action sets it again on resume, and it is cleared again when the paused turn or any turn before it used the tool.

## Requiring approval

A tool does not have to ask for approval itself. List it in `requires_approval:` and every call to it waits for the user before the tool runs:

```ruby
class SupportAgent < ApplicationAgent
  generate_with :openai, model: "gpt-5-mini"

  def handle(ticket_id:)
    prompt(message: "Resolve support ticket #{ticket_id}", tools: SUPPORT_TOOLS,
           requires_approval: [ :issue_refund, :close_account ])
  end
end
```

The call pauses with a `:confirm` request whose `prompt` is `"Allow issue_refund to run?"`, whose `tool_name` and `arguments` say what would run, and whose `metadata` is `{ "approval" => true }`, so your app can tell it from a question the tool asked. Nothing runs until you resume:

- `true` runs the tool once, with no answer in `input_answer`. The approval answers the gate, not the tool, so a tool that asks its own question still asks it, and is not asked to be approved again. The checkpoint records which calls wait for approval, so an answer is read as an approval even when the resumed action lists different tools.
- `false` declines: the tool never runs, and the model reads `{"error":"declined by user"}`.

`requires_approval:` is read by ActiveAgent and never sent to the provider. It names tools of any kind: agent methods, [delegations](/actions/delegation), and tools served by [MCP servers](/actions/mcps#approving-tool-calls). An MCP declaration can also ask for approval itself with `require_approval:`.

## Secrets

A `:secret` request collects a value the tool needs but the model must not see, such as a deploy token:

```ruby
class DeployAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini", api_version: :chat

  def ship(service:)
    prompt(message: "Deploy #{service} to staging", tools: DEPLOY_TOOLS)
  end

  def deploy(service:, environment:)
    token = input_answer
    return ActiveAgent::InputRequest.secret("Paste a deploy token for #{environment}") unless token

    Deployer.new(token:).deploy(service, environment)
    { deployed: service, environment: }
  end
end
```

For the rest of the resumed generation, the secret answer is replaced with `[FILTERED]` in every tool result before it reaches the model, in the arguments and results recorded on telemetry tool spans, and in the messages of any error a tool raises and of that error's causes. The value itself lives in execution state only while its tool call runs.

A tool's error is raised again as a copy with the secret replaced. When the copy still reports the secret, because the error class builds its message from its own state, an `ActiveAgent::InputRequest::ScrubbedError` named after the original class is raised instead. A cause that holds the secret is replaced by a `ScrubbedError` in the same way, and the causes behind it are dropped.

Secrets are matched as text. A number in a tool result is compared in its written form and becomes the string `"[FILTERED]"` when it matches. Every occurrence is replaced, so a short answer, such as a four-digit PIN, also replaces the same digits inside unrelated ids and amounts for the rest of the generation. Ask for secrets long enough not to collide.

The answer still passes through your app on its way to `resume_now`. Keep it out of logs, job arguments and request parameters you record, and never store it with the checkpoint. For the same reason, `resume_later` refuses secret answers.

## Resuming later

`resume_later` takes the same checkpoint and answers as `resume_now`, plus job options, and resumes in `ActiveAgent::GenerationJob`:

```ruby
SupportAgent.with(ticket:).as(current_user).handle(ticket_id: ticket.id)
  .resume_later(checkpoint: question.checkpoint, answers: { request_id => true }, queue: :agents)
```

The job runs the action again from its arguments, params and actor, as `generate_later` does, and calls `resume_now`. `resume_later` checks the answers before it enqueues anything and raises `ActiveAgent::InputRequest::ResumeError` for an incomplete answer, an answer that does not fit, or any answer to a `:secret` request: job arguments are stored by the queue backend. Resume a generation that waits on a secret inside your own job, reading the answer from where your app keeps it.

The checkpoint becomes a job argument too, so `GenerationJob` does not log its arguments.

Like `generate_later`, `resume_later` needs a generation whose agent has not run yet: call it on a new one built the same way, not on the generation that paused. An agent that sets its own `generation_job` receives the checkpoint and answers in a `resume:` keyword argument, which a subclass of `ActiveAgent::GenerationJob` already handles.

## Storing checkpoints

`response.checkpoint` is a plain hash with string keys that survives a JSON round trip. It holds:

| Key | Contents |
|---|---|
| `version` | The checkpoint format |
| `service`, `provider`, `model` | Where the generation paused |
| `action_name` | The agent action that paused |
| `tool_turns` | Tool round-trips used so far |
| `tool_choice_cleared` | Whether a forced `tool_choice` was already cleared |
| `messages` | The conversation through the assistant turn that made the tool calls, in the provider's format, without the messages derived from instructions |
| `tool_call_turn_size` | How many of the last `messages` make up that turn: 1, or more on OpenAI Responses, which sends reasoning and each function call as items of their own |
| `completed_results` | The results of the calls that finished, by tool call id |
| `input_requests` | One request per paused call |
| `approval_tool_calls` | Paused calls that wait for approval before their tool runs |
| `approved_tool_calls` | Paused calls that were already approved, and paused again on the tool's own question |
| `mcp_tool_calls` | Paused calls to tools that a client-side MCP server serves |

It contains the conversation, so store it the way you store conversations — encrypted at rest if they are sensitive — and resume only from a checkpoint your app stored itself, never from one a client sends you.

## Callbacks and notifications

`on_input_request` runs when a generation pauses, before the paused response is returned. A callback that takes an argument receives the paused response:

```ruby
class SupportAgent < ApplicationAgent
  on_input_request :notify_reviewer

  private

  def notify_reviewer(response)
    ReviewMailer.pending(response.input_requests.map(&:prompt)).deliver_later
  end
end
```

`only:` and `except:` name the generation's action, not the tool that paused it. `resuming?` is true inside callbacks and tools while a paused generation continues.

Each pause also publishes `input_requested.active_agent`, with the requests in `payload[:input_requests]`, and telemetry marks the generation's root span with `agent.awaiting_input`. A delegated agent's pause is the exception; see [Limitations](#limitations).

## Limitations

- Pausing works in every built-in tool loop, streamed or not: Anthropic, OpenAI Chat Completions, OpenAI Responses and RubyLLM, and the providers that share them (Bedrock, and the Chat Completions-compatible providers such as Azure, OpenRouter and Ollama). On OpenAI Responses, a reasoning model's reasoning items are kept in the checkpoint and sent back with the function calls they led to.
- A custom provider takes part by running its tool calls through `dispatch_tool_calls`. Under one that calls `call_tool_function` itself, a tool that returns a request, or a tool that needs approval, raises `ActiveAgent::InputRequest::UnsupportedProviderError` instead of running.
- Tools served by an MCP server cannot return a request, but their calls can require approval.
- A pause ends the generation, so [client-side MCP connections](/actions/mcps#pauses-and-client-side-servers) close. A `command:` server is started again on resume and loses any state it held. A paused call to a tool the server no longer offers gets an `{ "error": ... }` result instead of running.
- A [delegated agent](/actions/delegation) cannot pause: nothing holds its checkpoint once the delegated call returns. Its questions go back to the calling model as `{ "error": "input_required", "questions": [...] }`, or, under the `on_exceeded: :raise` budget policy, raise `ActiveAgent::Delegation::InputRequiredError`. The pause is neither published as `input_requested.active_agent` nor passed to the delegated agent's `on_input_request` callbacks. The other tool calls of the turn that paused have already run, and run again if the calling model retries the delegation.
