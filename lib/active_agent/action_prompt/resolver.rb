require_relative "message"

module ActiveAgent
  module ActionPrompt
    class Resolver
      attr_reader :context, :stream_callback, :stream_messages

      def initialize(context:, stream_callback: nil)
        @context         = context
        @stream_callback = stream_callback
        @stream_messages = []
      end

      # Returns the current streaming message being built, creating a new one if needed.
      #
      # This method manages the streaming message stack by tracking messages as they are
      # being constructed during the streaming response process. It ensures there is always
      # a valid message available to append streamed content to.
      #
      # A new message is created when:
      # - No messages exist in the stream yet (@stream_messages is empty)
      # - The last message is a completed tool message (indicated by the presence of raw_actions)
      #
      # @return [ActiveAgent::ActionPrompt::Message] The current streaming message being built
      def streaming_message
        if @stream_messages.empty? || @stream_messages.last.raw_actions.present?
          @stream_messages << blank_message
        end

        @stream_messages.last
      end

      def streaming_message_find(id)
        @stream_messages.find { it.generation_id == id }
      end

      private

      def blank_message
        ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)
      end
    end
  end
end
