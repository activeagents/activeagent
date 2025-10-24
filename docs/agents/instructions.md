# Agent Instructions

Instructions are system-level messages that guide how agents behave and respond. They define the agent's personality, capabilities, constraints, and how it should use available tools. Think of instructions as the agent's "operating manual" that shapes every interaction.

## Why Instructions Matter

Well-crafted instructions help agents:
- Understand their role and capabilities
- Know when and how to use available tools
- Maintain consistent behavior across interactions
- Handle edge cases and error scenarios appropriately
- Provide responses in the desired tone and format

## Setting Instructions

ActiveAgent provides five flexible ways to define instructions, from simple strings to dynamic ERB templates.

### 1. Default Instructions Template

The simplest approach: create an `instructions.md.erb` (or `instructions.text.erb`) file in your agent's view directory. ActiveAgent automatically loads it when you call `prompt` without explicit instructions.

::: code-group
<<< @/../test/docs/agents/instructions_examples_test.rb#default_template {ruby:line-numbers} [agent.rb]

<<< @/../test/dummy/app/views/docs/agents/instructions/default_template/agent/instructions.md.erb{erb:line-numbers} [instructions.md.erb]
:::

**Strict Loading:** Pass `instructions: true` to enforce strict template loading. This will raise an error if the template file cannot be found, useful for catching missing instruction files in production.

```ruby
# Raises error if instructions.md.erb is missing
generate_with instructions: true
```

**When to use:** Most production agents. Keeps instructions organized, version-controlled, and easy to iterate.

### 2. Inline String Instructions

Pass a string directly to `generate_with` for simple, static instructions:

<<< @/../test/docs/agents/instructions_examples_test.rb#inline_string {ruby:line-numbers} [agent.rb]

**When to use:** Quick prototypes, simple agents with minimal instructions, or when instructions fit in one clear sentence.

### 3. Custom Instructions Template

Reference a specific template by name, optionally passing local variables. You can set this globally in `generate_with` or override per-action in the `prompt` call:

::: code-group
<<< @/../test/docs/agents/instructions_examples_test.rb#custom_template {ruby:line-numbers} [agent.rb]

<<< @/../test/dummy/app/views/docs/agents/instructions/custom_template/agent/custom_instructions.md.erb{erb:line-numbers} [custom_instructions.text.erb]
:::

**When to use:**
- Multiple agents sharing instruction templates
- Different instruction sets for different actions
- Instructions needing dynamic data from instance variables or locals

### 4. Method Reference (Symbol)

Reference a method that returns instruction text. This enables dynamic instructions based on agent state or parameters:

<<< @/../test/docs/agents/instructions_examples_test.rb#dynamic_method {ruby:line-numbers} [agent.rb]

**When to use:** Instructions that vary based on:
- User roles or permissions
- Agent state or configuration
- Request context or parameters
- Time of day, locale, or other runtime factors

### 5. Array of Instructions

Pass multiple instruction strings that become separate system messages if supported by the provider, otherwise they are joined together:

<<< @/../test/docs/agents/instructions_examples_test.rb#multi_array {ruby:line-numbers} [agent.rb]

**When to use:**
- Breaking complex instructions into logical sections
- Emphasizing multiple distinct requirements
- Testing which instruction ordering works best

**Note:** Providers like Anthropic support multiple system messages, while others like OpenAI will join them into a single system message. The framework handles this automatically.

## Format Support

Instructions templates support multiple formats:

### Text Format (.text.erb)
Plain text instructions - most commonly supported:

```erb
You are a helpful assistant.
Available tools: search, analyze, report.
```

### Markdown Format (.md.erb)
Use markdown for structured instructions with formatting:

```erb
# Technical Support Agent

## Role
You provide **technical support** for software issues.

## Guidelines
- Always verify the problem before suggesting solutions
- Ask clarifying questions when needed
- Be patient and encouraging
```

**Note:** The format you choose affects how providers receive the instructions. Test with your specific provider to ensure formatting is preserved or stripped appropriately.

## Instruction Precedence

When instructions are defined in multiple places, they override in this order (highest to lowest priority):

1. **Per-action in `prompt()` call** - `prompt(instructions: "Override")`
2. **In `generate_with` configuration** - `generate_with :openai, instructions: "Global"`
3. **Default template** - `instructions.md.erb` in views directory

<<< @/../test/docs/agents/instructions_examples_test.rb#precedence {ruby:line-numbers} [agent.rb]

## Writing Effective Instructions

### Be Clear and Specific

**Bad:**
```
You're helpful.
```

**Good:**
```
You are a customer support agent for Acme Corp. Your goal is to resolve
customer issues quickly and professionally. Always verify the customer's
account before making changes.
```

### Define Tool Usage Clearly

When agents have tools available, explain when and how to use them:

```md
You are a hotel booking assistant helping <%= @user.name %> find and reserve accommodations near their travel destination.

## Available Tools

Use these tools in sequence to complete bookings:

1. **search** - Find hotels matching the user's criteria (location, dates, preferences)
2. **book** - Reserve a specific hotel room for the user
3. **confirm** - Finalize the reservation and provide confirmation details

## Booking Workflow

1. Use `search` to find hotels in the requested location with the user's dates and preferences
2. Present options and help the user choose based on their needs (price, amenities, location)
3. Use `book` to reserve the selected hotel room
4. Use `confirm` to finalize the booking and provide the confirmation number

## Guidelines

- Always verify the destination, check-in/check-out dates, and number of guests before searching
- Present hotel options with key details: price, rating, amenities, distance from destination
- Confirm all booking details with the user before calling `book`
- After booking, clearly communicate the confirmation number and cancellation policy
```


**Key elements:**
- Context about what the agent is helping with
- List of available tools (using `action_schemas`)
- Expected workflow or sequence of tool usage
- Any constraints or requirements

### Use ERB for Dynamic Context

Instructions are ERB templates - leverage that for contextual information:

```erb
You are assisting <%= @user.name %> (<%= @user.email %>).

<% if @user.premium? %>
Premium features are available to this user.
<% end %>

Available actions:
<% controller.action_methods.each do |action| %>
- <%= action %>
<% end %>
```

**Available in instruction templates:**
- `@instance_variables` set in actions or callbacks
- `params[:param_name]` from parameterization
- `controller` for accessing agent methods
- Local variables passed via `locals: { var: value }`

### Structure for Clarity

Break complex instructions into sections:

```erb
## Role
You are a technical documentation assistant specializing in API documentation.

## Capabilities
- Generate code examples in multiple languages
- Explain complex technical concepts clearly
- Suggest best practices and design patterns

## Constraints
- Never expose API keys or secrets in examples
- Always validate that code examples would actually work
- If unsure about something, say so explicitly
```

### Be Concise but Complete

Find the balance between thoroughness and brevity:

**Too vague:**
```
Help users with their questions.
```

**Too verbose:**
```
You are an agent designed to help users by answering their questions. When
users ask questions, you should provide helpful answers. Make sure your
answers are helpful and answer what the user is asking about. Always try
to be as helpful as possible in every situation...
```

**Just right:**
```
You are a product expert for HomeKit devices. Answer questions accurately
using the product documentation. If a question is outside your knowledge,
direct users to human support.
```


## Common Patterns

### Role + Task + Constraints

A proven structure for most agents:

```erb
ROLE: You are [who/what the agent is]

TASK: Your goal is to [primary objective]

CONSTRAINTS:
- [Important limitation 1]
- [Important limitation 2]
- [Important limitation 3]
```

### Tool-First Instructions

For tool-heavy agents, lead with capabilities:

```erb
You have access to these tools:

- [Action Name]: [Description]

Use these tools to help users with [specific task].

WORKFLOW:
1. [Step one]
2. [Step two]
3. [Step three]
```

### Context-Aware Instructions

Adapt instructions based on user or session context:

```erb
Assisting: <%= @user.name %> (<%= @user.tier %> tier)

<% if @user.tier == "enterprise" %>
Full feature set available. Prioritize advanced features.
<% else %>
Basic tier - core features only.
<% end %>

Session context:
- Previous queries: <%= @session.query_count %>
- Conversation started: <%= @session.started_at.strftime("%Y-%m-%d %H:%M") %>
```

### Multi-Agent Systems

When agents call other agents, provide context:

```erb
You are the <%= params[:agent_role] %> agent in a multi-agent system.

Your responsibilities:
<%= params[:responsibilities] %>

When you need help with <%= params[:delegation_trigger] %>,
delegate to the <%= params[:delegate_to] %> agent.
```

## Troubleshooting

### Agent Ignoring Instructions

**Symptoms:** Agent doesn't follow rules or use tools correctly

**Solutions:**
- Simplify instructions - remove ambiguity
- Add concrete examples of correct behavior
- Increase specificity about when to use tools
- Test if provider supports instruction length (some have limits)
- Try different instruction ordering

### Instructions Too Long

**Symptoms:** Provider errors about context length, slow responses

**Solutions:**
- Move detailed information to message content, not instructions
- Use more concise language
- Consider multi-turn conversations instead of massive instructions
- Reference documentation via tools rather than embedding it

### Dynamic Instructions Not Working

**Symptoms:** Instance variables unavailable, methods not found

**Solutions:**
- Ensure variables are set in action or `before_action` callback
- Check that template path matches agent name and is in correct directory
- Verify locals are passed: `{ template: :name, locals: { var: value } }`
- Use `controller.method_name` for agent methods

### Instructions Not Loading

**Symptoms:** No system message in provider request

**Solutions:**
- Verify file location: `app/views/[agent_name]/instructions.[format].erb`
- Check file naming: must be exactly `instructions.text.erb` or `instructions.md.erb`
- Ensure `prompt` is called in action (instructions only load during generation)
- Look for instruction precedence - explicit instructions override templates

## Related Documentation

- [Actions](/actions/actions) - How instructions integrate with agent actions
- [Messages](/actions/messages) - Understanding message roles and context
- [Prompts](/actions/prompts) - Building prompt contexts with instructions
- [Views](/agents) - ERB template rendering for agents
- [Testing](/framework/testing) - Testing agents with different instructions
