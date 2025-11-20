# frozen_string_literal: true

require "active_support/log_subscriber"

module ActiveAgent
  module Providers
    # Logs provider operations via ActiveSupport::Notifications events.
    #
    # Subscribes to instrumented provider events and formats them consistently.
    # Customize by subclassing and attaching your subscriber, or adjust log levels.
    #
    # @example Custom log formatting
    #   class MyLogSubscriber < ActiveAgent::Providers::LogSubscriber
    #     def prompt(event)
    #       info "🚀 #{event.payload[:provider_module]}: #{event.duration}ms"
    #     end
    #   end
    #
    #   ActiveAgent::Providers::LogSubscriber.detach_from :active_agent
    #   MyLogSubscriber.attach_to :active_agent
    class LogSubscriber < ActiveSupport::LogSubscriber
      # self.namespace = "active_agent" # Rails 8.1

      # Logs completed prompt with model, message count, token usage, and duration.
      #
      # @param event [ActiveSupport::Notifications::Event]
      # @return [void]
      def prompt(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        model           = event.payload[:model]
        message_count   = event.payload[:message_count]
        stream          = event.payload[:stream]
        usage           = event.payload[:usage]
        finish_reason   = event.payload[:finish_reason]
        duration        = event.duration.round(1)

        debug do
          parts = [ "[#{trace_id}]", "[ActiveAgent]", "[#{provider_module}]" ]
          parts << "Prompt completed:"
          parts << "model=#{model}" if model
          parts << "messages=#{message_count}"
          parts << "stream=#{stream}"

          if usage
            tokens = "tokens=#{usage[:input_tokens]}/#{usage[:output_tokens]}"
            tokens += " (cached: #{usage[:cached_tokens]})" if usage[:cached_tokens]&.positive?
            tokens += " (reasoning: #{usage[:reasoning_tokens]})" if usage[:reasoning_tokens]&.positive?
            parts << tokens
          end

          parts << "finish=#{finish_reason}" if finish_reason
          parts << "#{duration}ms"

          parts.join(" ")
        end
      end
      # event_log_level :prompt, :debug # Rails 8.1

      # Logs completed embedding with model, input size, and token usage.
      #
      # @param event [ActiveSupport::Notifications::Event]
      # @return [void]
      def embed(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        model           = event.payload[:model]
        input_size      = event.payload[:input_size]
        embedding_count = event.payload[:embedding_count]
        usage           = event.payload[:usage]
        duration        = event.duration.round(1)

        debug do
          parts = [ "[#{trace_id}]", "[ActiveAgent]", "[#{provider_module}]" ]
          parts << "Embed completed:"
          parts << "model=#{model}" if model
          parts << "inputs=#{input_size}" if input_size
          parts << "embeddings=#{embedding_count}" if embedding_count
          parts << "tokens=#{usage[:input_tokens]}" if usage
          parts << "#{duration}ms"

          parts.join(" ")
        end
      end
      # event_log_level :embed, :debug # Rails 8.1

      # @param event [ActiveSupport::Notifications::Event]
      # @return [void]
      def stream_open(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Opening stream"
        end
      end
      # event_log_level :stream_open, :debug # Rails 8.1

      # @param event [ActiveSupport::Notifications::Event]
      # @return [void]
      def stream_close(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Closing stream"
        end
      end
      # event_log_level :stream_close, :debug # Rails 8.1

      # @param event [ActiveSupport::Notifications::Event]
      # @return [void]
      def tool_call(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        tool_name       = event.payload[:tool_name]
        duration        = event.duration.round(1)

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Tool call: #{tool_name} (#{duration}ms)"
        end
      end
      # event_log_level :tool_call, :debug # Rails 8.1

      # @param event [ActiveSupport::Notifications::Event]
      # @return [void]
      def stream_chunk(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        chunk_type      = event.payload[:chunk_type]

        debug do
          if chunk_type
            "[#{trace_id}] [ActiveAgent] [#{provider_module}] Stream chunk: #{chunk_type}"
          else
            "[#{trace_id}] [ActiveAgent] [#{provider_module}] Stream chunk"
          end
        end
      end
      # event_log_level :stream_chunk, :debug # Rails 8.1

      # Logs connection failures with service URI and error details.
      #
      # @param event [ActiveSupport::Notifications::Event]
      # @return [void]
      def connection_error(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        uri_base        = event.payload[:uri_base]
        exception       = event.payload[:exception]
        message         = event.payload[:message]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Unable to connect to #{uri_base}. Please ensure the service is running. Error: #{exception} - #{message}"
        end
      end
      # event_log_level :connection_error, :debug # Rails 8.1

      private

      # @return [Logger]
      def logger
        ActiveAgent::Base.logger
      end
    end
  end
end

# region log_subscriber_attach
# Subscribe to both top-level (.active_agent) and provider-level (.provider.active_agent) events
ActiveAgent::Providers::LogSubscriber.attach_to :active_agent
ActiveAgent::Providers::LogSubscriber.attach_to :"provider.active_agent"
# endregion log_subscriber_attach

# Rails 8.1
# ActiveSupport.event_reporter.subscribe(
#   ActiveAgent::LogSubscriber.new, &ActiveAgent::LogSubscriber.subscription_filter
# )
