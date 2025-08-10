require "test_helper"

class StreamingAgentTest < ActiveSupport::TestCase
  test "it renders a prompt with a message" do
    assert_equal "Test Streaming", StreamingAgent.with(message: "Test Streaming").prompt_context.message.content
  end

  test "it uses the correct model and instructions" do
    prompt = StreamingAgent.with(message: "Test").prompt_context
    assert_equal "gpt-4.1-nano", prompt.options[:model]
    system_message = prompt.messages.find { |m| m.role == :system }
    assert_equal "You're a chat agent. Your job is to help users with their questions.", system_message.content
  end

  test "it broadcasts the expected number of times for streamed chunks" do
    # Mock ActionCable.server.broadcast
    broadcast_calls = []
    ActionCable.server.singleton_class.class_eval do
      alias_method :orig_broadcast, :broadcast
      define_method(:broadcast) do |*args|
        broadcast_calls << args
      end
    end

    VCR.use_cassette("streaming_agent_stream_response") do
      # region streaming_agent_stream_response
      StreamingAgent.with(message: "Stream this message").prompt_context.generate_now
      # endregion streaming_agent_stream_response
    end

    assert_equal 84, broadcast_calls.size
  ensure
    # Restore original broadcast method
    ActionCable.server.singleton_class.class_eval do
      alias_method :broadcast, :orig_broadcast
      remove_method :orig_broadcast
    end
  end
end
