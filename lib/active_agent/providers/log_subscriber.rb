# frozen_string_literal: true

require "active_support/log_subscriber"

module ActiveAgent
  module Providers
    # Log subscriber for ActiveAgent provider operations.
    #
    # This subscriber listens to ActiveSupport::Notifications events published
    # during provider operations and logs them in a consistent, configurable format.
    #
    # Events are automatically instrumented in the providers and can be customized
    # or disabled through log level configuration.
    #
    # @example Custom log formatting
    #   class MyLogSubscriber < ActiveAgent::LogSubscriber
    #     def prompt_start(event)
    #       info "🚀 Starting prompt: #{event.payload[:provider]}"
    #     end
    #   end
    #
    #   ActiveAgent::LogSubscriber.detach_from :active_agent_provider
    #   MyLogSubscriber.attach_to :active_agent_provider
    class LogSubscriber < ActiveSupport::LogSubscriber
      # self.namespace = "active_agent" # Rails 8.1

      # Logs the start of a prompt request
      #
      # @param event [ActiveSupport::Notifications::Event]
      def prompt_start(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Starting prompt request"
        end
      end
      # event_log_level :prompt_start, :debug # Rails 8.1

      # Logs the start of an embedding request
      #
      # @param event [ActiveSupport::Notifications::Event]
      def embed_start(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Starting embed request"
        end
      end
      # event_log_level :embed_start, :debug # Rails 8.1

      # Logs request preparation details
      #
      # @param event [ActiveSupport::Notifications::Event]
      def request_prepared(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        message_count  = event.payload[:message_count]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Prepared request with #{message_count} message(s)"
        end
      end
      # event_log_level :request_prepared, :debug # Rails 8.1

      # Logs API call execution
      #
      # @param event [ActiveSupport::Notifications::Event]
      def api_call(event)
        return unless logger.debug?

        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        streaming       = event.payload[:streaming]
        duration        = event.duration.round(1)

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] API call completed in #{duration}ms (streaming: #{streaming})"
        end
      end
      # event_log_level :api_call, :debug # Rails 8.1

      # Logs embed API call execution
      #
      # @param event [ActiveSupport::Notifications::Event]
      def embed_call(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        duration        = event.duration.round(1)

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Embed API call completed in #{duration}ms"
        end
      end
      # event_log_level :embed_call, :debug # Rails 8.1

      # Logs stream opening
      #
      # @param event [ActiveSupport::Notifications::Event]
      def stream_open(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Opening stream"
        end
      end
      # event_log_level :stream_open, :debug # Rails 8.1

      # Logs stream closing
      #
      # @param event [ActiveSupport::Notifications::Event]
      def stream_close(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Closing stream"
        end
      end
      # event_log_level :stream_close, :debug # Rails 8.1

      # Logs message extraction from API response
      #
      # @param event [ActiveSupport::Notifications::Event]
      def messages_extracted(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        message_count   = event.payload[:message_count]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Extracted #{message_count} message(s) from API response"
        end
      end
      # event_log_level :messages_extracted, :debug # Rails 8.1

      # Logs tool/function call processing
      #
      # @param event [ActiveSupport::Notifications::Event]
      def tool_calls_processing(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        tool_count      = event.payload[:tool_count]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Processing #{tool_count} tool call(s)"
        end
      end
      # event_log_level :tool_calls_processing, :debug # Rails 8.1

      # Logs multi-turn conversation continuation
      #
      # @param event [ActiveSupport::Notifications::Event]
      def multi_turn_continue(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Continuing multi-turn conversation after tool execution"
        end
      end
      # event_log_level :multi_turn_continue, :debug # Rails 8.1

      # Logs prompt completion
      #
      # @param event [ActiveSupport::Notifications::Event]
      def prompt_complete(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        message_count   = event.payload[:message_count]
        duration        = event.duration.round(1)

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Prompt completed with #{message_count} message(s) in stack (total: #{duration}ms)"
        end
      end
      # event_log_level :prompt_complete, :debug # Rails 8.1

      # Logs retry attempts
      #
      # @param event [ActiveSupport::Notifications::Event]
      def retry_attempt(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        attempt         = event.payload[:attempt]
        max_retries     = event.payload[:max_retries]
        exception       = event.payload[:exception]
        backoff_time    = event.payload[:backoff_time]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}:Retries] Attempt #{attempt}/#{max_retries} failed with #{exception}, retrying in #{backoff_time}s"
        end
      end
      # event_log_level :retry_attempt, :debug # Rails 8.1

      # Logs when max retries are exceeded
      #
      # @param event [ActiveSupport::Notifications::Event]
      def retry_exhausted(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        max_retries     = event.payload[:max_retries]
        exception       = event.payload[:exception]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}:Retries] Max retries (#{max_retries}) exceeded for #{exception}"
        end
      end
      # event_log_level :retry_exhausted, :debug # Rails 8.1

      # Logs tool execution
      #
      # @param event [ActiveSupport::Notifications::Event]
      def tool_execution(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        tool_name       = event.payload[:tool_name]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Executing tool: #{tool_name}"
        end
      end
      # event_log_level :tool_execution, :debug # Rails 8.1

      # Logs tool choice removal
      #
      # @param event [ActiveSupport::Notifications::Event]
      def tool_choice_removed(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Removing tool_choice constraint after tool execution"
        end
      end
      # event_log_level :tool_choice_removed, :debug # Rails 8.1

      # Logs API request
      #
      # @param event [ActiveSupport::Notifications::Event]
      def api_request(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        model           = event.payload[:model]
        streaming       = event.payload[:streaming]


        debug do
          if streaming.nil?
            "[#{trace_id}] [ActiveAgent] [#{provider_module}] Executing request to #{model}"
          else
            mode = streaming ? "streaming" : "non-streaming"
            "[#{trace_id}] [ActiveAgent] [#{provider_module}] Executing #{mode} request to #{model}"
          end
        end
      end
      # event_log_level :api_request, :debug # Rails 8.1

      # Logs stream chunk processing
      #
      # @param event [ActiveSupport::Notifications::Event]
      def stream_chunk_processing(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        chunk_type      = event.payload[:chunk_type]

        debug do
          if chunk_type
            "[#{trace_id}] [ActiveAgent] [#{provider_module}] Processing stream chunk: #{chunk_type}"
          else
            "[#{trace_id}] [ActiveAgent] [#{provider_module}] Processing stream chunk"
          end
        end
      end
      # event_log_level :stream_chunk_processing, :debug # Rails 8.1

      # Logs stream finished
      #
      # @param event [ActiveSupport::Notifications::Event]
      def stream_finished(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        finish_reason   = event.payload[:finish_reason]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Stream finished with reason: #{finish_reason}"
        end
      end
      # event_log_level :stream_finished, :debug # Rails 8.1

      # Logs API routing decisions
      #
      # @param event [ActiveSupport::Notifications::Event]
      def api_routing(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]
        api_type        = event.payload[:api_type]
        api_version     = event.payload[:api_version]
        has_audio       = event.payload[:has_audio]

        debug do
          if has_audio
            "[#{trace_id}] [ActiveAgent] [#{provider_module}] Routing to #{api_type.to_s.capitalize} API (api_version: #{api_version}, audio: #{has_audio})"
          else
            "[#{trace_id}] [ActiveAgent] [#{provider_module}] Routing to #{api_type.to_s.capitalize} API (api_version: #{api_version})"
          end
        end
      end
      # event_log_level :api_routing, :debug # Rails 8.1

      # Logs embeddings requests
      #
      # @param event [ActiveSupport::Notifications::Event]
      def embeddings_request(event)
        trace_id        = event.payload[:trace_id]
        provider_module = event.payload[:provider_module]

        debug do
          "[#{trace_id}] [ActiveAgent] [#{provider_module}] Executing embeddings request"
        end
      end
      # event_log_level :embeddings_request, :debug # Rails 8.1

      # Logs connection errors
      #
      # @param event [ActiveSupport::Notifications::Event]
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

      # Use the logger configured for ActiveAgent::Base
      #
      # @return [Logger]
      def logger
        ActiveAgent::Base.logger
      end
    end
  end
end

# region log_subscriber_attach
ActiveAgent::Providers::LogSubscriber.attach_to :"provider.active_agent"
# endregion log_subscriber_attach

# Rails 8.1
# ActiveSupport.event_reporter.subscribe(
#   ActiveAgent::LogSubscriber.new, &ActiveAgent::LogSubscriber.subscription_filter
# )
