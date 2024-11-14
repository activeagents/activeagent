# ActiveAgent

ActiveAgent is a Rails framework for creating and managing AI agents. It provides a structured way to interact with AI services through agents that can generate text, images, speech-to-text, and text-to-speech. It includes modules for defining prompts, actions, and rendering generative UI, as well as scaling with asynchronous jobs and streaming.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'active_agent'
```

And then execute:

```sh
bundle install
```
## Getting Started

## Usage

### Generating an Agent
```
rails generate agent inventory search
```

This will generate the following files:
```
app/agents/application_agent.rb
app/agents/inventory_agent.rb
app/views/inventory_agent/search.text.erb
app/views/inventory_agent/search.json.jbuilder
```

### Define Agents

Agents are the core of ActiveAgent. An agent takes prompts and can perform actions to generate content. Agents are defined by a simple Ruby class that inherits from `ActiveAgent::Base` and are located in the `app/agents` directory.

```ruby
# 

inventory_agent.rb


class InventoryAgent < ActiveAgent::Base
  generate_with :openai, model: 'gpt-4o-mini', temperature: 0.5, instructions: :inventory_operations

  def search
    @items = Item.search(params[:query])
  end

  def inventory_operations
    @organization = Organization.find(params[:account_id])
    prompt
  end
end
```

### Interact with AI Services

ActiveAgent allows you to interact with various AI services to generate text, images, speech-to-text, and text-to-speech.

```ruby
class SupportAgent < ActiveAgent::Base
  generate_with :openai, model: 'gpt-4o-mini', instructions: :instructions

  def perform(content, context)
    @content = content
    @context = context
  end

  def generate_message
    provider_instance.generate(self)
  end

  private

  def after_generate
    broadcast_message
  end

  def broadcast_message
    broadcast_append_later_to(
      broadcast_stream,
      target: broadcast_target,
      partial: 'support_agent/message',
      locals: { message: @message }
    )
  end

  def broadcast_stream
    "#{dom_id(@chat)}_messages"
  end
end
```

### Render Generative UI

ActiveAgent uses Action Prompt both for rendering `instructions` prompt views as well as rendering action views. Prompts are Action Views that provide instructions for the agent to generate content.

```erb
<!-- 

instructions.text.erb

 -->
INSTRUCTIONS: You are an inventory manager for <%= @organization.name %>. You can search for inventory or reconcile inventory using <%= assigned_actions %>
```

### Scale with Asynchronous Jobs and Streaming

ActiveAgent supports asynchronous job processing and streaming for scalable AI interactions.

#### Asynchronous Jobs

Use the `generate_later` method to enqueue a job for later processing.

```ruby
InventoryAgent.with(query: query).search.generate_later
```

#### Streaming

Use the `stream_with` method to handle streaming responses.

```ruby
class InventoryAgent < ActiveAgent::Base
  generate_with :openai, model: 'gpt-4o-mini', stream: :broadcast_results

  private

  def broadcast_results
    proc do |chunk, _bytesize|
      @message.content = @message.content + chunk
      broadcast_append_to(
        "#{dom_id(chat)}_messages",
        partial: "messages/message",
        locals: { message: @message, scroll_to: true },
        target: "#{dom_id(chat)}_messages"
      )
    end
  end
end
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/yourusername/active_agent.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
```
