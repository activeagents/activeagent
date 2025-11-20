# frozen_string_literal: true

module ActiveAgent
  module Providers
    # Builds instrumentation event payloads for ActiveSupport::Notifications.
    #
    # Extracts request parameters and response metadata for monitoring, debugging,
    # and APM integration (New Relic, DataDog, etc.).
    #
    # == Event Payloads
    #
    # Top-Level Events (overall request lifecycle):
    #
    # prompt.active_agent::
    #   Initial: `{ model:, temperature:, max_tokens:, message_count:, has_tools:, stream: }`
    #   Final: `{ usage: { input_tokens:, output_tokens:, total_tokens: }, finish_reason:, response_model:, response_id: }`
    #   Note: Usage is cumulative across all API calls in multi-turn conversations
    #
    # embed.active_agent::
    #   Initial: `{ model:, input_size:, encoding_format:, dimensions: }`
    #   Final: `{ usage: { input_tokens:, total_tokens: }, embedding_count:, response_model:, response_id: }`
    #
    # Provider-Level Events (per API call):
    #
    # prompt.provider.active_agent::
    #   Initial: `{ model:, temperature:, max_tokens:, message_count:, has_tools:, stream: }`
    #   Final: `{ usage: { input_tokens:, output_tokens:, total_tokens: }, finish_reason:, response_model:, response_id: }`
    #   Note: Usage is per individual API call
    #
    # embed.provider.active_agent::
    #   Initial: `{ model:, input_size:, encoding_format:, dimensions: }`
    #   Final: `{ usage: { input_tokens:, total_tokens: }, embedding_count:, response_model:, response_id: }`
    module Instrumentation
      extend ActiveSupport::Concern

      # Builds and merges payload data for prompt instrumentation events.
      #
      # Populates both request parameters and response metadata for top-level and
      # provider-level events. Usage data (tokens) is CRITICAL for APM cost tracking
      # and performance monitoring.
      #
      # @param payload [Hash] instrumentation payload to merge into
      # @param request [Request] request object with parameters
      # @param response [Common::PromptResponse] completed response with normalized data
      # @return [void]
      def instrumentation_prompt_payload(payload, request, response)
        # message_count: prefer the request/input messages (pre-call), fall back to
        # response messages only if the request doesn't expose messages. New Relic
        # expects parameters[:messages] to be the request messages and computes
        # total message counts by adding response choices to that count.
        message_count = safe_access(request, :messages)&.size
        message_count = safe_access(response, :messages)&.size if message_count.nil?

        payload.merge!(trace_id: trace_id, message_count: message_count || 0, stream: !!safe_access(request, :stream))

        # Common parameters: prefer response-normalized values, then request
        payload[:model]       = safe_access(response, :model) || safe_access(request, :model)
        payload[:temperature] = safe_access(request, :temperature)
        payload[:max_tokens]  = safe_access(request, :max_tokens)
        payload[:top_p]       = safe_access(request, :top_p)

        # Tools / instructions
        if (tools_val = safe_access(request, :tools))
          payload[:has_tools]  = tools_val.respond_to?(:present?) ? tools_val.present? : !!tools_val
          payload[:tool_count] = tools_val&.size || 0
        end

        if (instr_val = safe_access(request, :instructions))
          payload[:has_instructions] = instr_val.respond_to?(:present?) ? instr_val.present? : !!instr_val
        end

        # Usage (normalized)
        if response.usage
          usage = response.usage
          payload[:usage] = {
            input_tokens:  usage.input_tokens,
            output_tokens: usage.output_tokens,
            total_tokens:  usage.total_tokens
          }

          payload[:usage][:cached_tokens]         = usage.cached_tokens         if usage.cached_tokens
          payload[:usage][:cache_creation_tokens] = usage.cache_creation_tokens if usage.cache_creation_tokens
          payload[:usage][:reasoning_tokens]      = usage.reasoning_tokens      if usage.reasoning_tokens
          payload[:usage][:audio_tokens]          = usage.audio_tokens          if usage.audio_tokens
        end

        # Response metadata
        payload[:finish_reason]  = safe_access(response, :finish_reason) || response.finish_reason
        payload[:response_model] = safe_access(response, :model)         || response.model
        payload[:response_id]    = safe_access(response, :id)            || response.id

        # Build messages list: prefer request messages; if unavailable use prior
        # response messages (all but the final generated message).
        if (req_msgs = safe_access(request, :messages)).is_a?(Array)
          payload[:messages] = req_msgs.map { |m| extract_message_hash(m, false) }
        else
          prior = safe_access(response, :messages)
          prior = prior[0...-1] if prior.is_a?(Array) && prior.size > 1
          if prior.is_a?(Array) && prior.any?
            payload[:messages] = prior.map { |m| extract_message_hash(m, false) }
          end
        end

        # Build a parameters hash that mirrors what New Relic's OpenAI
        # instrumentation expects. This makes it easy for APM adapters to
        # map our provider payload to their LLM event constructors.
        parameters = {}
        parameters[:model]       = payload[:model]       if payload[:model]
        parameters[:max_tokens]  = payload[:max_tokens]  if payload[:max_tokens]
        parameters[:temperature] = payload[:temperature] if payload[:temperature]
        parameters[:top_p]       = payload[:top_p]       if payload[:top_p]
        parameters[:stream]      = payload[:stream]
        parameters[:messages]    = payload[:messages]    if payload[:messages]

        # Include tools/instructions where available — New Relic ignores unknown keys,
        # but having them here makes the parameter shape closer to OpenAI's.
        parameters[:tools]        = begin request.tools        rescue nil end if begin request.tools        rescue nil end
        parameters[:instructions] = begin request.instructions rescue nil end if begin request.instructions rescue nil end

        payload[:parameters] = parameters

        # Attach raw response (provider-specific) so downstream APM integrations
        # can inspect the provider response if needed. Use the normalized raw_response
        # available on the Common::Response when possible.
        begin
          payload[:response_raw] = response.raw_response if response.respond_to?(:raw_response) && response.raw_response
        rescue StandardError
          # ignore
        end
      end

      private

      # Safely attempt to call a method or lookup a key on an object. We avoid
      # probing with `respond_to?` to prevent ActiveModel attribute casting side
      # effects; instead we attempt the call and rescue failures.
      def safe_access(obj, name)
        return nil if obj.nil?

        begin
          return obj.public_send(name)
        rescue StandardError
        end

        begin
          return obj[name]
        rescue StandardError
        end

        begin
          return obj[name.to_s]
        rescue StandardError
        end

        nil
      end

      # NOTE: message access is handled via `safe_access(obj, :messages)` to
      # avoid duplicating guarded lookup logic.

      # Extract a simple hash from a provider message object or hash-like value.
      def extract_message_hash(msg, is_response = false)
        role = begin
          if msg.respond_to?(:[])
            begin msg[:role] rescue (begin msg["role"] rescue nil end) end
          elsif msg.respond_to?(:role)
            msg.role
          elsif msg.respond_to?(:type)
            msg.type
          end
        rescue StandardError
          begin msg.role rescue msg.type rescue nil end
        end

        content = begin
          if msg.respond_to?(:[])
            begin msg[:content] rescue (begin msg["content"] rescue nil end) end
          elsif msg.respond_to?(:content)
            msg.content
          elsif msg.respond_to?(:text)
            msg.text
          elsif msg.respond_to?(:to_h)
            begin msg.to_h[:content] rescue (begin msg.to_h["content"] rescue nil end) end
          elsif msg.respond_to?(:to_s)
            msg.to_s
          end
        rescue StandardError
          begin msg.to_s rescue nil end
        end

        { role: role, content: content, is_response: is_response }
      end

      # Builds and merges payload data for embed instrumentation events.
      #
      # Embeddings typically only report input tokens (no output tokens).
      #
      # @param payload [Hash] instrumentation payload to merge into
      # @param request [Request] request object with parameters
      # @param response [Common::EmbedResponse] completed response with normalized data
      # @return [void]
      def instrumentation_embed_payload(payload, request, response)
        # Add request parameters
        payload[:trace_id] = trace_id
        payload[:model] = request.model if request.respond_to?(:model)

        # Add input size if available
        if request.respond_to?(:input)
          begin
            input = request.input
            if input.is_a?(String)
              payload[:input_size] = 1
            elsif input.is_a?(Array)
              payload[:input_size] = input.size
            end
          rescue # OpenAI throws errors this for some reason when you try to look at the input.
            payload[:input_size] = request[:input].size
          end
        end

        # Expose embedding input content similarly to message content.
        # Use guarded access to avoid provider-specific errors.
        begin
          if (emb_input = safe_access(request, :input))
            # Keep the raw input (string or array) in the payload so APM adapters
            # can inspect it. This matches how we include message content.
            payload[:input] = emb_input
          end
        rescue StandardError
          # ignore
        end

        # Add encoding format if available (OpenAI)
        payload[:encoding_format] = request.encoding_format if request.respond_to?(:encoding_format)

        # Add dimensions if available (OpenAI)
        payload[:dimensions] = request.dimensions if request.respond_to?(:dimensions)

        # Add response data
        payload[:embedding_count] = response.data&.size || 0

        # Add usage data if available (CRITICAL for APM integration)
        # Embeddings typically only have input tokens
        if response.usage
          payload[:usage] = {
            input_tokens: response.usage.input_tokens,
            total_tokens: response.usage.total_tokens
          }
        end

        # Add response metadata directly from response object
        payload[:response_model] = response.model
        payload[:response_id]    = response.id

        # Build a parameters hash for embeddings to match New Relic's shape.
        emb_params = {}
        emb_params[:model] = payload[:model] if payload[:model]
        emb_params[:input] = payload[:input] if payload.key?(:input)
        payload[:parameters] = emb_params unless emb_params.empty?
      end
    end
  end
end
