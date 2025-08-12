# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module StreamProcessing
      extend ActiveSupport::Concern

      included do
        attr_accessor :stream_buffer, :stream_context
      end

      def provider_stream
        agent_stream = prompt.options[:stream]
        message = initialize_stream_message

        @response = ActiveAgent::GenerationProvider::Response.new(prompt:, message:)

        proc do |chunk|
          process_stream_chunk(chunk, message, agent_stream)
        end
      end

      protected

      def initialize_stream_message
        ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)
      end

      def process_stream_chunk(chunk, message, agent_stream)
        # Default implementation - must be overridden in provider
        raise NotImplementedError, "Providers must implement process_stream_chunk"
      end

      def handle_stream_delta(delta, message, agent_stream)
        # Common delta handling logic
        new_content = extract_content_from_delta(delta)
        if new_content && !new_content.blank?
          message.content += new_content
          agent_stream&.call(message, new_content, false, prompt.action_name)
        end
      end

      def extract_content_from_delta(delta)
        # Default extraction - override if needed
        delta if delta.is_a?(String)
      end

      def handle_tool_stream_chunk(chunk, message, agent_stream)
        # Handle tool calls in streaming
        # Override in provider for specific implementation
      end

      def finalize_stream(message, agent_stream)
        agent_stream&.call(message, nil, true, prompt.action_name)
      end
    end
  end
end