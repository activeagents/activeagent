class StreamingAgent < ApplicationAgent
  layout "agent"
  generate_with :openai,
    model: "gpt-4.1-nano",
    instructions: "You're a chat agent. Your job is to help users with their questions.",
    stream: true

  on_stream do
    # Only broadcast if we have a message with generation_id and content
    if @_stream_message&.generation_id && @_stream_message&.content&.present?
      broadcast_message(@_stream_message)
    end
  end

  private

  def broadcast_message(message)
    # Broadcast the message to the specified channel
    ActionCable.server.broadcast(
      "#{message.generation_id}_messages",
      partial: "streaming_agent/message",
      locals: { message: message.content, scroll_to: true }
    )
  end
end
