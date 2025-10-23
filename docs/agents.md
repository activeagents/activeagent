---
title: Agents
model:
  - title: Context (Model)
    link: /actions/prompts
    icon: 📝
    details: Prompt Context is the core data model that contains the runtime context, messages, variables, and configuration for the prompt.
view:
  - title: Prompt (View)
    link: /framework/action-prompt
    icon: 🖼️
    details: Action View templates are responsible for rendering the prompts to agents and UI to users.
controller:
  - title: Agents (Controller)
    link: /framework/agents
    icon: <img src="/activeagent.png" />
    details: Agents are Controllers with a common Generation API with enhanced memory and tooling.

---
# Agents

Agents are Controllers that orchestrate AI interactions using the ActiveAgent framework. They handle the generation request-response cycle, manage context through callbacks, coordinate with AI providers, and support both synchronous and asynchronous generation.

## Core Concepts

Agents extend `ActiveAgent::Base` and inherit familiar Rails patterns:
- **Actions** - Public methods that define agent behaviors
- **Views** - Optional ERB templates that render prompt instructions and messages
- **Callbacks** - Lifecycle hooks (`before_action`, `after_generation`, etc.)
- **Streaming** - Real-time response updates via `on_stream`
- **Notifications** - ActiveSupport::Notifications for instrumentation and monitoring

### The Generation Cycle

The request-response cycle mirrors Rails controllers:

1. **Action called** - You call an agent action method with parameters
2. **Context prepared** - Instance variables and callbacks set up the context
3. **Interface invoked** - Action calls `prompt()` or `embed()` to build context
4. **View rendered** - Optional ERB templates renders into instructions and/or message content
5. **Provider processes** - AI provider executes the request
6. **Response returned** - Structured data or content returned to caller

## Defining Agents

Create agent classes by inheriting from `ActiveAgent::Base` and configuring the provider:

::: code-group
<<< @/../test/dummy/app/agents/translation_agent.rb{ruby:line-numbers} [translation_agent.rb]
<<< @/../test/dummy/app/views/translation_agent/translate.json.jbuilder{ruby:line-numbers} [translate.json.jbuilder]
<<< @/../test/dummy/app/views/translation_agent/translate.text.erb{erb:line-numbers} [translate.text.erb]
:::

### Actions as Public Methods

Define actions as public instance methods. Each action represents a specific agent behavior:

```ruby
class SupportAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini"

  # Action method - can be called as a tool or invoked directly
  def help
    prompt message: params[:question]
  end

  # Another action method
  def summarize
    prompt message: params[:content], temperature: 0.3
  end
end
```

### The `prompt()` Interface

The `prompt()` method is the core interface for building generation context. Call it within action methods to configure messages and options:

```ruby
def my_action
  # Add messages to the context
  prompt "User message", temperature: 0.8

  # Or use keyword arguments
  prompt message: "Hello", instructions: "Be helpful"

  # Multiple messages
  prompt messages: ["First message", "Second message"]

  # With images or documents
  prompt image: "path/to/image.jpg", message: "Describe this"
end
```

**Key points:**
- `prompt()` builds context but doesn't execute generation
- Can be called multiple times in an action to build up context
- Accepts strings, hashes, and keyword options
- View templates are rendered automatically if they exist

### The `embed()` Interface

The `embed()` method configures embedding generation:

```ruby
def embed_text
  # Embed direct input
  embed "Text to embed"

  # Or with options
  embed input: "Text to embed", model: "text-embedding-3-large"

  # Multiple inputs
  embed input: ["Text 1", "Text 2"]
end
```

### Views Are Optional

Views are **optional**. You can pass content directly via `prompt()` or `embed()` parameters, or use ERB templates for complex formatting:

**Without views (inline):**
```ruby
def greet
  prompt message: "Hello!", instructions: "Be friendly"
end
```

**With views (templates):**
```ruby
def greet
  # Renders app/views/my_agent/greet.text.erb automatically
  prompt
end
```

```erb
<!-- app/views/my_agent/greet.text.erb -->
Hello <%= params[:name] %>!
```

## Invoking Agents

Agents can be invoked in several ways, each returning a `Generation` object that controls execution:

### Class Method Invocation

Call action methods directly on the agent class:

```ruby
# Returns a Generation object
generation = SupportAgent.help

# Execute synchronously
response = generation.generate_now
response.message.content  # => "..."

# Execute asynchronously
SupportAgent.help.generate_later(queue: :agents)
```

### Parameterized Invocation

Use `with()` to pass parameters that are available in templates and action methods via `params`:

```ruby
# Pass parameters to actions
generation = WelcomeAgent.with(user_name: "Alice").greet
response = generation.generate_now

# In the action or template, access via params[:user_name]
```

### Direct Prompt/Embed Methods

For quick prototyping without defining actions, use the class methods `prompt()` and `embed()`:

```ruby
# Direct prompt generation
response = MyAgent.prompt(message: "Hello world").generate_now

# Direct embedding
response = MyAgent.embed(input: "Text to embed").embed_now

# With options
response = MyAgent.prompt(
  message: "Analyze this",
  temperature: 0.8,
  model: "gpt-4"
).generate_now
```

**Note:** Direct methods create a `Generation` object just like action methods, but skip the action step.

## Generation Objects

All agent invocations return a `Generation` object that provides:

### Execution Methods

- **`generate_now`** - Execute synchronously and return response
- **`generate_now!`** - Execute with immediate error handling
- **`generate_later(options)`** - Queue for background execution
- **`embed_now`** - Execute embedding synchronously
- **`embed_later(options)`** - Queue embedding for background execution

### Inspection Methods

Access prompt properties before executing:

```ruby
generation = MyAgent.with(query: "test").search

# Inspect before execution
generation.message          # Last message object
generation.messages         # All messages
generation.actions          # Available tools/actions
generation.options          # Configuration (temperature, model, etc.)
generation.prompt_options   # Full context hash
```

## Key Features

- **[Actions](/actions/actions)** - Define public methods that become callable agent behaviors and can be used as tools
- **[Callbacks](/agents/callbacks)** - Lifecycle hooks (`before_action`, `after_action`, `before_generation`, `after_generation`) to manage context and responses
- **[Streaming](/agents/callbacks#on-stream-callbacks)** - Real-time updates with `on_stream` callback for progressive response rendering
- **[Queued Generation](/agents/queued-generation)** - Asynchronous processing with Active Job using `generate_later` and `embed_later`
- **[Structured Output](/agents/structured-output)** - Extract data using JSON schemas for type-safe responses
- **[Instrumentation](/framework/instrumentation)** - Built-in ActiveSupport::Notifications for monitoring and logging

## Complete Example

::: code-group
<<< @/../test/dummy/app/agents/travel_agent.rb {ruby} [travel_agent.rb]

<<< @/../test/dummy/app/views/travel_agent/search.html.erb {erb} [search.html.erb]

<<< @/../test/dummy/app/views/travel_agent/book.text.erb {erb} [book.text.erb]

<<< @/../test/dummy/app/views/travel_agent/confirm.text.erb {erb} [confirm.text.erb]
:::

### Using the Travel Agent

<<< @/../test/agents/travel_agent_test.rb#travel_agent_multi_format{ruby:line-numbers}

::: details Search Response Example
<!-- @include: @/parts/examples/travel-agent-test.rb-test-travel-agent-search-view-renders-HTML-format.md -->
:::

::: details Book Response Example
<!-- @include: @/parts/examples/travel-agent-test.rb-travel_agent_book_text.md -->
:::

::: details Confirm Response Example
<!-- @include: @/parts/examples/travel-agent-test.rb-test-travel-agent-confirm-view-renders-text-format.md -->
:::

## Concepts
### User-Agent interactions
We're not talking about HTTP User Agents here, but rather the interactions between the user and the AI agent. The user interacts with the agent through a series of prompt context messages and actions that are defined in the agent class. These actions can be used to retrieve data, create custom views, handle user input, and manage the flow of data between different components of your application.

Agents are conceptually similar to a user in the sense that they have a persona, behavior, and state. They can perform actions and have objectives, just like a user. The following table illustrates the similarities between the user and the AI agent:
|          |       User |  Agent       |
| :------: | ---------: | :----------- |
| Who      |    Persona | Archetype    |
| Behavior |    Stories | Instructions |
| State    |   Scenario | Context      |
| What     |  Objective | Goal         |
| How      |    Actions | Tools        |

### Agent Oriented Programming (AOP)
Agent Oriented Programming (AOP) is a programming paradigm that focuses on the use of agents as a primary building block of applications. It allows developers to create modular, reusable components that can be easily integrated into existing systems. AOP promotes code reusability, maintainability, and scalability, making it easier to build complex AI-driven applications.
|             |                    OOP |  AOP                           |
| :---------: | ---------------------: | :----------------------------- |
| unit        |                 Object | Agent                          |
| params      |   message, args, block | prompt, context, tools         |
| computation |   method, send, return | perform, generate, response    |
| state       |      instance variables| prompt context                 |
| flow        |           method calls | prompt and response cycles     |
| constraints |            coded logic | written instructions           |
