require_relative "message"

module ActiveAgent
  module ActionPrompt
    class Resolver
      attr_accessor :request
      attr_reader :context, :stream_callback, :tool_callback, :message_stack

      def initialize(context:, request: nil, stream_callback: nil, tool_callback: nil)
        @context         = context
        @request         = request
        @stream_callback = stream_callback
        @tool_callback   = tool_callback
        @message_stack   = []
      end
    end
  end
end
