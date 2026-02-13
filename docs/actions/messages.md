---
title: Messages
description: Build conversation context with messages containing roles (user, assistant, system, tool) and content (text, images, documents) in native or unified format.
---
# {{ $frontmatter.title }}

Messages build the conversation context for agent interactions. Each message has a role (user, assistant, system, or tool) and content (text, images, or documents). ActiveAgent supports both native provider formats and a unified common format that works across all providers.

## Message Roles

Understanding roles helps you structure conversations correctly:

- **User** - Input from the user to the agent (text, images, documents)
- **Assistant** - Responses from the agent, including tool call requests
- **System** - Instructions that guide agent behavior (set via `instructions` option)
- **Developer** - OpenAI's alternative to system role; treated identically to system messages in common format (dropped and replaced by instructions)
- **Tool** - Results from tool executions (handled automatically)

Most of the time you'll send user messages and inspect assistant/tool responses.

## Sending Messages

### Single Message

The simplest way to send a message:

<<< @/../test/docs/actions/messages_examples_test.rb#single_message_agent {ruby:line-numbers}

Use the `message:` keyword for clarity:

<<< @/../test/docs/actions/messages_examples_test.rb#message_keyword_agent {ruby:line-numbers}

### Multiple Messages

Send multiple strings as separate user messages in a single prompt:

::: code-group
<<< @/../test/docs/actions/messages_examples_test.rb#multiple_messages_agent {ruby:line-numbers} [inline]
<<< @/../test/docs/actions/messages_examples_test.rb#multiple_messages_agent {ruby:line-numbers} [array]
:::

### Messages with Roles

Set explicit roles using hashes. The default role is `:user`:

<<< @/../test/docs/actions/messages_examples_test.rb#messages_with_roles_agent {ruby:line-numbers}

**Note:** Use the `instructions` option for system messages. Both `system` and `developer` role messages are dropped in common format and replaced by instructions. [Learn about instructions →](/agents/instructions)

## Images and Documents

ActiveAgent provides a unified interface for multimodal inputs. Pass HTTP URLs or Base64 data URIs - the framework converts them to the provider's native format.

**ActiveStorage Support:** Direct attachment support for ActiveStorage files is coming soon.

### Images

<<< @/../test/docs/actions/messages_examples_test.rb#image_agent {ruby:line-numbers}

### Documents

Same interface for PDFs and other documents:

<<< @/../test/docs/actions/messages_examples_test.rb#document_agent {ruby:line-numbers}

**Supported formats:**
- Images: JPEG, PNG, GIF, WebP
- Documents: PDF (provider-dependent)

## Inspecting Responses

After generation, access messages from the response:

<<< @/../test/docs/actions/messages_examples_test.rb#inspect_messages {ruby:line-numbers}

### Grouping by Role

Filter messages to find specific types:

<<< @/../test/docs/actions/messages_examples_test.rb#grouping_by_role {ruby:line-numbers}

### System Messages

System messages come from the `instructions` option:

::: code-group
<<< @/../test/docs/actions/messages_examples_test.rb#system_messages_agent {ruby:line-numbers} [agent.rb]
<<< @/../test/docs/actions/messages_examples_test.rb#inspect_system_message {ruby:line-numbers} [inspect.rb]
:::

### Assistant Messages

Assistant messages contain the agent's responses. Provide conversation history by including previous assistant messages:

<<< @/../test/docs/actions/messages_examples_test.rb#assistant_history_agent {ruby:line-numbers}

### Tool Messages

Tool messages contain results from tool executions. ActiveAgent handles tool calls and their results automatically. [Learn about tools →](/actions/tools)

```ruby
# Tool messages contain execution results
tool_messages.first.content
# => "https://cataas.com/cat/5e9..."
```

## Common vs Native Format

ActiveAgent provides two ways to work with messages:

### Common Format (Recommended)

Use the unified `prompt()` interface. ActiveAgent normalizes messages across providers:

<<< @/../test/docs/actions/messages_examples_test.rb#common_format_agent {ruby:line-numbers}

**Benefits:**
- Switch providers without changing code
- Consistent API across all providers
- Automatic format conversion

### Native Format

For provider-specific features, use native message structures:

<<< @/../test/docs/actions/messages_examples_test.rb#native_format_agent {ruby:line-numbers}

Both formats work with all providers, but common format is simpler and more portable.

## Related Documentation

- [Agents →](/agents) - Understanding the agent lifecycle
- [Actions →](/actions) - Overview of agent capabilities
- [Tools →](/actions/tools) - Defining and using agent tools
- [Instructions →](/agents/instructions) - Setting system messages and guiding agent behavior
- [Generation →](/agents/generation) - How messages flow through the generation process
- [Structured Output →](/actions/structured_output) - Formatting agent responses
- [Callbacks →](/agents/callbacks) - Hook into message processing
- [Streaming →](/agents/streaming) - Real-time message updates
- [Testing →](/framework/testing) - Test message handling patterns
