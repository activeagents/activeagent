# frozen_string_literal: true

require "opentelemetry"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"

module ActionPrompt
  # OpenTelemetry and OpenLLMetry compliant telemetry for ActionPrompt
  # This provides observability for the core prompt engineering and LLM interactions
  module Telemetry
    extend ActiveSupport::Concern
    
    # OpenLLMetry semantic conventions for LLM observability
    module Attributes
      # LLM Request attributes (OpenLLMetry standard)
      LLM_SYSTEM = "gen_ai.system"
      LLM_REQUEST_MODEL = "gen_ai.request.model"
      LLM_REQUEST_TEMPERATURE = "gen_ai.request.temperature"
      LLM_REQUEST_TOP_P = "gen_ai.request.top_p"
      LLM_REQUEST_MAX_TOKENS = "gen_ai.request.max_tokens"
      LLM_REQUEST_STOP_SEQUENCES = "gen_ai.request.stop_sequences"
      LLM_REQUEST_FREQUENCY_PENALTY = "gen_ai.request.frequency_penalty"
      LLM_REQUEST_PRESENCE_PENALTY = "gen_ai.request.presence_penalty"
      
      # LLM Response attributes
      LLM_RESPONSE_ID = "gen_ai.response.id"
      LLM_RESPONSE_MODEL = "gen_ai.response.model"
      LLM_RESPONSE_FINISH_REASONS = "gen_ai.response.finish_reasons"
      
      # Token usage attributes
      LLM_USAGE_INPUT_TOKENS = "gen_ai.usage.input_tokens"
      LLM_USAGE_OUTPUT_TOKENS = "gen_ai.usage.output_tokens"
      
      # Prompt attributes
      LLM_PROMPT_MESSAGES = "gen_ai.prompt"
      LLM_COMPLETION_MESSAGES = "gen_ai.completion"
      
      # ActionPrompt specific
      PROMPT_TEMPLATE_NAME = "action_prompt.template.name"
      PROMPT_TEMPLATE_VERSION = "action_prompt.template.version"
      PROMPT_ACTION_NAME = "action_prompt.action.name"
      PROMPT_MESSAGES_COUNT = "action_prompt.messages.count"
      PROMPT_RENDER_TIME_MS = "action_prompt.render.duration_ms"
    end
    
    # Event names for span events
    module Events
      STREAMING_START = "gen_ai.content.start"
      STREAMING_CHUNK = "gen_ai.content.chunk"
      STREAMING_END = "gen_ai.content.end"
      
      TOOL_CALL_REQUEST = "gen_ai.tool.request"
      TOOL_CALL_RESULT = "gen_ai.tool.result"
      
      RATE_LIMITED = "gen_ai.rate_limited"
      RETRY_ATTEMPT = "gen_ai.retry"
    end
    
    class Configuration
      attr_accessor :enabled, :service_name, :service_version
      attr_accessor :exporter_endpoint, :exporter_headers
      attr_accessor :sample_rate, :batch_size, :export_timeout_millis
      attr_accessor :resource_attributes
      attr_accessor :sanitize_pii, :pii_patterns
      
      def initialize
        # Read from environment with sensible defaults
        @enabled = ENV.fetch("OTEL_SDK_DISABLED", "false") != "true"
        @service_name = ENV.fetch("OTEL_SERVICE_NAME", "action_prompt")
        @service_version = ENV.fetch("OTEL_SERVICE_VERSION", ActionPrompt::VERSION)
        
        @exporter_endpoint = ENV.fetch("OTEL_EXPORTER_OTLP_ENDPOINT", nil)
        @exporter_headers = ENV.fetch("OTEL_EXPORTER_OTLP_HEADERS", "").split(",").map { |h| h.split("=") }.to_h
        
        @sample_rate = ENV.fetch("OTEL_TRACES_SAMPLER_ARG", "1.0").to_f
        @batch_size = ENV.fetch("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", "512").to_i
        @export_timeout_millis = ENV.fetch("OTEL_BSP_EXPORT_TIMEOUT", "30000").to_i
        
        @resource_attributes = {}
        @sanitize_pii = ENV.fetch("ACTION_PROMPT_SANITIZE_PII", "true") == "true"
        @pii_patterns = default_pii_patterns
      end
      
      private
      
      def default_pii_patterns
        [
          /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/, # Email
          /\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/, # Phone
          /\b\d{3}-\d{2}-\d{4}\b/, # SSN
          /\b(?:\d{4}[-\s]?){3}\d{4}\b/ # Credit card
        ]
      end
    end
    
    class << self
      def configuration
        @configuration ||= Configuration.new
      end
      
      def configure
        yield configuration if block_given?
        setup_tracer_provider if configuration.enabled
      end
      
      def tracer
        @tracer ||= OpenTelemetry.tracer_provider.tracer(
          configuration.service_name,
          configuration.service_version
        )
      end
      
      def enabled?
        configuration.enabled && tracer_provider_configured?
      end
      
      def sanitize_content(content)
        return content unless configuration.sanitize_pii
        
        sanitized = content.dup
        configuration.pii_patterns.each do |pattern|
          sanitized.gsub!(pattern, "[REDACTED]")
        end
        sanitized
      end
      
      private
      
      def tracer_provider_configured?
        @tracer_provider_configured ||= false
      end
      
      def setup_tracer_provider
        return if tracer_provider_configured?
        
        OpenTelemetry::SDK.configure do |c|
          # Set service name and version
          c.service_name = configuration.service_name
          c.service_version = configuration.service_version
          
          # Add resource attributes
          c.resource = OpenTelemetry::SDK::Resources::Resource.create(
            {
              "service.name" => configuration.service_name,
              "service.version" => configuration.service_version,
              "telemetry.sdk.name" => "opentelemetry",
              "telemetry.sdk.language" => "ruby",
              "telemetry.sdk.version" => OpenTelemetry::VERSION
            }.merge(configuration.resource_attributes)
          )
          
          # Configure exporter
          if configuration.exporter_endpoint
            exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
              endpoint: configuration.exporter_endpoint,
              headers: configuration.exporter_headers,
              timeout: configuration.export_timeout_millis / 1000.0
            )
            
            processor = OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
              exporter,
              max_queue_size: configuration.batch_size * 4,
              max_export_batch_size: configuration.batch_size,
              schedule_delay: 5000,
              export_timeout: configuration.export_timeout_millis
            )
            
            c.add_span_processor(processor)
          else
            # Use console exporter in development if no endpoint configured
            if Rails.env.development?
              processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
                OpenTelemetry::SDK::Trace::Export::ConsoleSpanExporter.new
              )
              c.add_span_processor(processor)
            end
          end
          
          # Configure sampling
          c.add_span_processor(
            OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
              OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
            )
          ) if Rails.env.test?
        end
        
        @tracer_provider_configured = true
      end
    end
    
    # Instrumentation module to be included in ActionPrompt::Base
    module Instrumentation
      extend ActiveSupport::Concern
      
      included do
        around_action :trace_prompt_action, if: -> { ActionPrompt::Telemetry.enabled? }
      end
      
      private
      
      def trace_prompt_action
        tracer = ActionPrompt::Telemetry.tracer
        
        span_name = "action_prompt.#{action_name}"
        span_attributes = {
          Attributes::PROMPT_ACTION_NAME => action_name,
          Attributes::PROMPT_TEMPLATE_NAME => "#{controller_name}/#{action_name}",
          "code.namespace" => self.class.name,
          "code.function" => action_name
        }
        
        tracer.in_span(span_name, attributes: span_attributes, kind: :internal) do |span|
          begin
            # Track prompt rendering
            render_start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
            
            result = yield
            
            render_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - render_start
            span.set_attribute(Attributes::PROMPT_RENDER_TIME_MS, render_duration)
            
            # Track prompt context if available
            if @prompt
              track_prompt_attributes(span, @prompt)
            end
            
            span.set_status(OpenTelemetry::Trace::Status.ok)
            result
          rescue => e
            span.record_exception(e)
            span.set_status(
              OpenTelemetry::Trace::Status.error(e.message)
            )
            raise
          end
        end
      end
      
      def track_prompt_attributes(span, prompt)
        # Track message count
        span.set_attribute(Attributes::PROMPT_MESSAGES_COUNT, prompt.messages.size)
        
        # Track prompt content (sanitized)
        if prompt.messages.any?
          messages_json = prompt.messages.map do |msg|
            {
              role: msg.role,
              content: ActionPrompt::Telemetry.sanitize_content(msg.content[0..500]) # First 500 chars
            }
          end.to_json
          
          span.set_attribute(Attributes::LLM_PROMPT_MESSAGES, messages_json)
        end
        
        # Track available actions/tools
        if prompt.actions.any?
          span.set_attribute("action_prompt.actions.count", prompt.actions.size)
          span.set_attribute("action_prompt.actions.names", prompt.actions.map(&:name).join(","))
        end
      end
    end
    
    # Generation provider instrumentation
    module GenerationInstrumentation
      extend ActiveSupport::Concern
      
      def generate_with_telemetry(prompt, options = {})
        return generate_without_telemetry(prompt, options) unless ActionPrompt::Telemetry.enabled?
        
        tracer = ActionPrompt::Telemetry.tracer
        
        span_name = "gen_ai.chat"
        span_attributes = build_generation_attributes(options)
        
        tracer.in_span(span_name, attributes: span_attributes, kind: :client) do |span|
          begin
            # Track streaming if enabled
            if options[:stream]
              span.add_event(Events::STREAMING_START)
              
              original_on_chunk = options[:on_message_chunk]
              chunk_count = 0
              
              options[:on_message_chunk] = proc do |chunk|
                chunk_count += 1
                span.add_event(Events::STREAMING_CHUNK, attributes: {
                  "chunk.index" => chunk_count,
                  "chunk.size" => chunk.to_s.bytesize
                })
                original_on_chunk&.call(chunk)
              end
            end
            
            # Perform generation
            response = generate_without_telemetry(prompt, options)
            
            # Track response attributes
            track_response_attributes(span, response)
            
            # Track streaming end
            if options[:stream]
              span.add_event(Events::STREAMING_END, attributes: {
                "total.chunks" => chunk_count
              })
            end
            
            span.set_status(OpenTelemetry::Trace::Status.ok)
            response
          rescue RateLimitError => e
            span.add_event(Events::RATE_LIMITED, attributes: {
              "retry_after" => e.retry_after
            })
            span.record_exception(e)
            span.set_status(OpenTelemetry::Trace::Status.error("Rate limited"))
            raise
          rescue => e
            span.record_exception(e)
            span.set_status(OpenTelemetry::Trace::Status.error(e.message))
            raise
          end
        end
      end
      
      alias_method :generate_without_telemetry, :generate
      alias_method :generate, :generate_with_telemetry
      
      private
      
      def build_generation_attributes(options)
        attrs = {
          Attributes::LLM_SYSTEM => provider_name,
          Attributes::LLM_REQUEST_MODEL => options[:model] || default_model
        }
        
        # Add optional parameters if present
        attrs[Attributes::LLM_REQUEST_TEMPERATURE] = options[:temperature] if options[:temperature]
        attrs[Attributes::LLM_REQUEST_TOP_P] = options[:top_p] if options[:top_p]
        attrs[Attributes::LLM_REQUEST_MAX_TOKENS] = options[:max_tokens] if options[:max_tokens]
        attrs[Attributes::LLM_REQUEST_STOP_SEQUENCES] = options[:stop].join(",") if options[:stop]&.any?
        attrs[Attributes::LLM_REQUEST_FREQUENCY_PENALTY] = options[:frequency_penalty] if options[:frequency_penalty]
        attrs[Attributes::LLM_REQUEST_PRESENCE_PENALTY] = options[:presence_penalty] if options[:presence_penalty]
        
        attrs
      end
      
      def track_response_attributes(span, response)
        return unless response
        
        # Track token usage
        if response.usage
          span.set_attribute(Attributes::LLM_USAGE_INPUT_TOKENS, response.usage["prompt_tokens"] || 0)
          span.set_attribute(Attributes::LLM_USAGE_OUTPUT_TOKENS, response.usage["completion_tokens"] || 0)
        end
        
        # Track response metadata
        span.set_attribute(Attributes::LLM_RESPONSE_ID, response.id) if response.id
        span.set_attribute(Attributes::LLM_RESPONSE_MODEL, response.model) if response.model
        
        # Track finish reason
        if response.choices&.first&.dig("finish_reason")
          span.set_attribute(Attributes::LLM_RESPONSE_FINISH_REASONS, response.choices.first["finish_reason"])
        end
        
        # Track completion content (sanitized)
        if response.choices&.first&.dig("message", "content")
          content = ActionPrompt::Telemetry.sanitize_content(
            response.choices.first.dig("message", "content")[0..500]
          )
          span.set_attribute(Attributes::LLM_COMPLETION_MESSAGES, content)
        end
        
        # Track tool calls if any
        if response.choices&.first&.dig("message", "tool_calls")&.any?
          tool_calls = response.choices.first.dig("message", "tool_calls")
          span.add_event(Events::TOOL_CALL_REQUEST, attributes: {
            "tool.count" => tool_calls.size,
            "tool.names" => tool_calls.map { |tc| tc.dig("function", "name") }.join(",")
          })
        end
      end
    end
  end
end