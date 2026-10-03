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
5. The action runs again to rebuild its tools and instructions, the conversation is restored from the checkpoint, and each paused tool call runs again — this time with its answer available. All of the turn's results go to the model together, in the order the model asked for them, and the tool loop carries on.

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

Every constructor also takes `schema:` (a JSON Schema for the answer) and `metadata:` (anything you want to keep with the request). The provider fills in `tool_call_id` and `tool_name`.

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
  end

  PendingQuestion.create!(ticket_id: 42, checkpoint: response.checkpoint,
                          requests: response.input_requests.map(&:to_h))
end
```

`response.message` is the assistant turn that made the tool calls, not an answer. `InputRequest#to_h` and `InputRequest.from_h` round-trip a request through JSON.

## Resuming

Build the generation the same way as the paused one — same agent, action, arguments and params — and pass the checkpoint with one answer per paused tool call id:

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

Calls that finished before the pause are not run again; their results come from the checkpoint. The tool-turn count carries over, so `max_tool_turns` covers the whole generation, pauses included. A forced `tool_choice` stays forced only until the model has used the tool, as it would without the pause: the action sets it again on resume, and it is cleared again when the paused turn or any turn before it used the tool.

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

For the rest of the resumed generation, the secret answer is replaced with `[FILTERED]` in every tool result before it reaches the model, in the arguments and results recorded on telemetry tool spans, and in the message of any error a tool raises. The value itself lives in execution state only while its tool call runs.

The answer still passes through your app on its way to `resume_now`. Keep it out of logs, job arguments and request parameters you record, and never store it with the checkpoint.

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
| `completed_results` | The results of the calls that finished, by tool call id |
| `input_requests` | One request per paused call |

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

`resuming?` is true inside callbacks and tools while a paused generation continues.

Each pause also publishes `input_requested.active_agent`, with the requests in `payload[:input_requests]`, and telemetry marks the generation's root span with `agent.awaiting_input`.

## Limitations

- Pausing works in the Anthropic and OpenAI Chat Completions tool loops, streamed or not, and in the providers that share them (Bedrock, and the Chat Completions-compatible providers such as Azure, OpenRouter and Ollama). Under OpenAI Responses or RubyLLM, a tool that returns a request raises `ActiveAgent::InputRequest::UnsupportedProviderError`.
- Only agent tool methods can ask. Tools served by an MCP server cannot return a request.
- A pause ends the generation, so client-side MCP connections close. A `command:` server is started again on resume and loses any state it held.
- A [delegated agent](/actions/delegation) cannot pause: nothing holds its checkpoint once the delegated call returns. Its questions go back to the calling model as `{ "error": "input_required", "questions": [...] }`.
- There is no `resume_later` yet; resume inside your own job, reading the answers from where your app stored them.
