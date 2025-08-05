# Callbacks

Callbacks can be registered to execute on specific events during the prompt and response cycle. This allows you to perform actions such as logging, modifying prompts, or triggering additional processes based on the agent's activity.

## Action Callbacks
Action callbacks are triggered when an action is invoked within an agent. This allows you to customize the behavior of actions, such as modifying the action's parameters or logging the action's execution. Great for retrieval augmented generation (RAG) workflows.

<<< @/../test/agents/callback_agent_test.rb#callback_agent_before_action {ruby:line-numbers}

## Generation Callbacks
Generation callbacks are executed during the generation process of an agent. This allows you to modify the prompt, handle responses, or perform additional processing based on the generated content.

<<< @/../test/agents/callback_agent_test.rb#callback_agent_after_generation {ruby:line-numbers}

## On Stream Callbacks
On stream callbacks are triggered during the streaming of responses from an agent. This allows you to handle real-time updates, such as displaying partial responses in a user interface or logging the progress of the response generation. 

### Streaming Implementation

The streaming agent demonstrates real-time response handling:

<<< @/../test/dummy/app/agents/streaming_agent.rb{ruby:line-numbers}

### Testing Streaming

The streaming functionality broadcasts each chunk as it arrives:

<<< @/../test/agents/streaming_agent_test.rb#streaming_agent_stream_response {ruby:line-numbers}

In this test, the agent broadcasts 30 chunks during the streaming response.
