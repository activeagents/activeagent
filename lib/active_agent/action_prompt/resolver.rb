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

      def streaming_message
        # If we don't have any messages yet, or the last message is complete because it's a tool
        # call response, start a new blank message for the stack.
        if @stream_messages.empty? || @stream_messages.last.raw_actions.present?
          @stream_messages << blank_message
        end

        @stream_messages.last
      end

      private

      def blank_message
        ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)
      end
    end
  end
end
