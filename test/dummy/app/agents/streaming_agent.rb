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

    message = params[:delta] ? stream_chunk.delta : response.message.content
    # Broadcast the message to the specified channel
    ActionCable.server.broadcast(
      "#{response.message.generation_id}_messages",
      partial: "streaming_agent/message",
      locals: { message:, scroll_to: true }
    )
  end
end
