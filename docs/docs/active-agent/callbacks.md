# Callbacks

Callbacks can be registered to execute on specific events during the prompt and response cycle. This allows you to perform actions such as logging, modifying prompts, or triggering additional processes based on the agent's activity.

## Action Callbacks
Action callbacks are triggered when an action is invoked within an agent. This allows you to customize the behavior of actions, such as modifying the action's parameters or logging the action's execution. Great for retrieval augmented generation (RAG) workflows.

```ruby
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai

  before_action :set_context
  
  private
  def set_context
    # Logic to set the context for the action, e.g., setting a user ID or session data
    @context = Context.find(params[:context_id])
    prompt_context.messages = @context.messages
  end
end
```

## Generation Callbacks
Generation callbacks are executed during the generation process of an agent. This allows you to modify the prompt, handle responses, or perform additional processing based on the generated content.

```ruby
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai

  after_generation :process_response

  private
  def process_response 
    generation_provider.response
  end
end
```

## On Stream Callbacks
On stream callbacks are triggered during the streaming of responses from an agent. This allows you to handle real-time updates, such as displaying partial responses in a user interface or logging the progress of the response generation. 

Below is a verbose example to demonstrate how to handle streaming responses and broadcast updates to a chat interface. The shows the runtime instance of the Agent's [`generation_provider`](/docs/framework/generation-provider) and its [`response`](/docs/framework/generation-provider#response) object. This example assumes you have a `Chat` model with associated messages, and you want to update the chat in real-time as the agent generates a response.

<<< @/../test/dummy/app/agents/streaming_agent.rb{ruby:line-numbers} [streaming_agent.rb]
