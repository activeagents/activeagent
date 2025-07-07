class StreamingAgent < ApplicationAgent
  layout "agent"
  generate_with :openai,
    model: "gpt-4.1-nano",
    instructions: "You're a chat agent. Your job is to help users with their questions.",
    stream: true

  on_stream :broadcast_message

  private

  def broadcast_message
    response = generation_provider.response

    # Broadcast the message to the specified channel
    # Or pass the content to a Message model and use
    # Active Record callbacks to handle the broadcasting
    ActionCable.server.broadcast(
      "#{response.message.generation_id}_messages",
      partial: "streaming_agent/message",
      locals: {message: response.message.content, scroll_to: true}
    )
  end
end
