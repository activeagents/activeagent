# ActiveAgent

ActiveAgent is a Rails framework for creating and managing AI agents. It provides a structured way to interact with AI services through agents that can generate text, images, speech-to-text, and text-to-speech. It includes modules for defining prompts, actions, and rendering generative UI, as well as scaling with asynchronous jobs and streaming.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'activeagent'
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
  generate_with :openai, model: 'gpt-4o-mini', temperature: 0.5

  def search
    @items = Item.search(params[:query])
  end
end
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

Bug reports and pull requests are welcome on GitHub at https://github.com/activeagents/activeagent.

```
bundle exec standard --fix # for linting
bundle exec rake test # for testing
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
