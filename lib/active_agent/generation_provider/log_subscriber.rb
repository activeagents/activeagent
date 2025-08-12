# frozen_string_literal: true

require "active_support/log_subscriber"

module ActiveAgent
  module GenerationProvider
    # = Generation Provider \\LogSubscriber
    #
    # Implements the ActiveSupport::LogSubscriber for logging notifications when
    # generation providers make API calls and handle responses.
    class LogSubscriber < ActiveSupport::LogSubscriber
      # A generation request was made
      def generate(event)
        info do
          provider = event.payload[:provider]
          model = event.payload[:model]
          
          if exception = event.payload[:exception_object]
            "Failed generation with #{provider} model=#{model} error_class=#{exception.class} error_message=#{exception.message.inspect}"
          else
            "Generated response with #{provider} model=#{model} (#{event.duration.round(1)}ms)"
          end
        end

        debug { event.payload[:prompt] } if event.payload[:prompt]
      end
      subscribe_log_level :generate, :debug

      # Streaming chunk received
      def stream_chunk(event)
        debug do
          provider = event.payload[:provider]
          chunk_size = event.payload[:chunk_size]
          "#{provider}: received stream chunk (#{chunk_size} bytes)"
        end
      end
      subscribe_log_level :stream_chunk, :debug

      # Tool/function call executed
      def tool_call(event)
        info do
          tool_name = event.payload[:tool_name]
          tool_id = event.payload[:tool_id]
          
          if exception = event.payload[:exception_object]
            "Failed tool call #{tool_name} id=#{tool_id} error=#{exception.class}"
          else
            "Executed tool call #{tool_name} id=#{tool_id} (#{event.duration.round(1)}ms)"
          end
        end
      end
      subscribe_log_level :tool_call, :debug

      # Retry attempt
      def retry(event)
        warn do
          provider = event.payload[:provider]
          attempt = event.payload[:attempt]
          max_attempts = event.payload[:max_attempts]
          error_class = event.payload[:error_class]
          
          "#{provider}: Retry attempt #{attempt}/#{max_attempts} after #{error_class}"
        end
      end
      subscribe_log_level :retry, :warn

      # Error occurred
      def error(event)
        error do
          provider = event.payload[:provider]
          error_class = event.payload[:error_class]
          error_message = event.payload[:error_message]
          
          "#{provider}: Error #{error_class} - #{error_message}"
        end
      end
      subscribe_log_level :error, :error

      # Use the logger configured for ActiveAgent::Base if available
      def logger
        if defined?(ActiveAgent::Base) && ActiveAgent::Base.respond_to?(:logger)
          ActiveAgent::Base.logger
        else
          super
        end
      end
    end
  end
end

# Attach to active_agent.generation_provider namespace
ActiveAgent::GenerationProvider::LogSubscriber.attach_to :"active_agent.generation_provider"