# Callbacks

Callbacks can be registered to execute on specific events during the prompt and response cycle. This allows you to perform actions such as logging, modifying prompts, or triggering additional processes based on the agent's activity.

## Action Callbacks

Action callbacks are triggered when an action is invoked within an agent. This allows you to customize the behavior of actions, such as modifying the action's parameters or logging the action's execution. Great for retrieval augmented generation (RAG) workflows.

### Before Action Example

The `TravelAgent` uses a `before_action` callback to set up user context:

<<< @/../test/dummy/app/agents/travel_agent.rb#1-10{ruby:line-numbers}

The `set_user` method runs before any action, ensuring the user context is available:

```ruby
private

def set_user
  @user = params[:user] || MockUser.new(name: "Guest")
end
```

### Conditional Before Action

The `DataExtractionAgent` uses conditional callbacks for specific actions:

<<< @/../test/dummy/app/agents/data_extraction_agent.rb#1-11{ruby:line-numbers}

The `before_action` only runs for the `parse_content` action, setting up multimodal content when needed.

## Generation Callbacks

Generation callbacks are executed during the generation process of an agent. This allows you to modify the prompt, handle responses, or perform additional processing based on the generated content.

### Before and After Generation

```ruby
class LoggingAgent < ApplicationAgent
  before_generation :log_start
  after_generation :log_completion

  def chat
    prompt(message: params[:message])
  end

  private

  def log_start
    Rails.logger.info "Starting generation for #{action_name}"
  end

  def log_completion
    Rails.logger.info "Completed generation for #{action_name}"
  end
end
```

### Testing Generation Callbacks

<<< @/../test/features/callbacks_test.rb#33-49{ruby:line-numbers}

## Around Generation Callbacks

Around generation callbacks wrap the entire generation process, allowing you to perform setup and teardown operations. This is useful for timing, caching, logging, or any operation that needs to wrap the generation process.

### Basic Around Generation

<<< @/../test/features/callbacks_test.rb#67-85{ruby:line-numbers}

### Conditional Callbacks

You can apply callbacks conditionally using `:if` and `:unless` options:

<<< @/../test/features/callbacks_test.rb#216-245{ruby:line-numbers}

This pattern is useful for:
- **Performance monitoring**: Track generation times for specific actions. [For long-running tasks, consider queued generation →](/agents/queued-generation)
- **Caching**: Cache LLM responses for expensive operations
- **Rate limiting**: Implement custom rate limiting logic
- **Debugging**: Log detailed information about specific generations

## On Stream Callbacks
On stream callbacks are triggered during the streaming of responses from an agent. This allows you to handle real-time updates, such as displaying partial responses in a user interface or logging the progress of the response generation.
