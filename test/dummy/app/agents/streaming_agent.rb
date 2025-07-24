class StreamingAgent < ApplicationAgent
  layout "agent"
  generate_with :openai,
    model: "gpt-4.1-nano",
    instructions: "You're a chat agent. Your job is to help users with their questions.",
    stream: true

  on_stream :broadcast_message

  private

  def broadcast_message
    return unless @_stream_message&.generation_id && @_stream_message&.content&.present?
    # Broadcast the message to the specified channel
    ActionCable.server.broadcast(
      "#{@_stream_message.generation_id}_messages",
      partial: "streaming_agent/message",
      locals: { message: @_stream_message.content, scroll_to: true }
    )
  end
end
