# frozen_string_literal: true

require_relative "_base_provider"

require_gem!(:ruby_llm, __FILE__) unless defined?(::RubyLLM)

require_relative "ruby_llm/_types"
require_relative "ruby_llm/tool_proxy"

module ActiveAgent
  module Providers
    # Provider for RubyLLM's unified API, supporting 15+ LLM providers
    # (OpenAI, Anthropic, Gemini, Bedrock, Azure, Ollama, etc.).
    #
    # Uses RubyLLM's provider-level API (provider.complete()) rather than
    # the high-level Chat object to avoid conflicts with ActiveAgent's own
    # conversation management and tool execution loop.
    #
    # @see BaseProvider
    class RubyLLMProvider < BaseProvider
      # @return [RubyLLM::EmbeddingRequestType] embedding request type
      def self.embed_request_type
        RubyLLM::EmbeddingRequestType.new
      end

      protected

      # Clears tool_choice between turns to prevent infinite tool-calling loops.
      def prepare_prompt_request
        prepare_prompt_request_tools
        super
      end

      # Executes a prompt request via RubyLLM's provider-level API.
      #
      # Resolves the appropriate provider from the model ID, converts
      # ActiveAgent messages/tools to RubyLLM format, and calls
      # provider.complete().
      #
      # @param parameters [Hash] serialized request parameters
      # @return [Hash, nil] normalized API response hash, or nil for streaming
      def api_prompt_execute(parameters)
        @resolved_model_id = parameters[:model] || options.model
        resolve_ruby_llm_provider!(@resolved_model_id)

        # Convert messages to RubyLLM format
        messages = build_ruby_llm_messages(parameters)

        # Convert tools to RubyLLM format
        tools = build_ruby_llm_tools(parameters[:tools])

        # Build kwargs for provider.complete (tools, temperature, model are required)
        kwargs = {
          model: @ruby_llm_model,
          tools: tools || {},
          temperature: parameters[:temperature]
        }
        kwargs[:schema] = parameters[:response_format] if parameters[:response_format]

        # Pass extra params (max_tokens, etc.) via RubyLLM's params: deep-merge
        max_tokens = parameters[:max_tokens] || options.max_tokens
        if max_tokens
          kwargs[:params] = { max_tokens: max_tokens }
        end

        if parameters[:stream]
          stream_proc = parameters[:stream]

          # For streaming, pass a block that forwards chunks
          @ruby_llm_provider.complete(messages, **kwargs) do |chunk|
            stream_proc.call(chunk)
          end

          nil
        else
          response = @ruby_llm_provider.complete(messages, **kwargs)
          normalize_ruby_llm_response(response, @resolved_model_id)
        end
      end

      # Executes an embedding request via RubyLLM.
      #
      # @param parameters [Hash] serialized embedding request parameters
      # @return [Hash] normalized embedding response with symbol keys
      def api_embed_execute(parameters)
        model_id = parameters[:model] || options.model
        resolve_ruby_llm_provider!(model_id)

        input = parameters[:input]
        inputs = input.is_a?(Array) ? input : [ input ]

        data = inputs.map.with_index do |text, index|
          embedding = @ruby_llm_provider.embed(text, model: model_id, dimensions: parameters[:dimensions])

          {
            object: "embedding",
            index: index,
            embedding: embedding.vectors
          }
        end

        {
          object: :list,
          data: data,
          model: model_id
        }
      end

      # Processes streaming chunks from RubyLLM.
      #
      # Handles RubyLLM::Chunk objects, building up the message in message_stack.
      #
      # @param chunk [RubyLLM::Chunk] streaming chunk
      # @return [void]
      def process_stream_chunk(chunk)
        instrument("stream_chunk.active_agent")

        broadcast_stream_open

        if message_stack.empty? || !message_stack.last.is_a?(Hash) || message_stack.last[:role] != "assistant"
          message_stack.push({ role: "assistant", content: "" })
        end

        message = message_stack.last

        # Append content delta
        if chunk.content
          message[:content] ||= ""
          message[:content] += chunk.content
          broadcast_stream_update(message, chunk.content)
        end

        # Handle tool calls in chunk
        if chunk.tool_calls&.any?
          message[:tool_calls] ||= []
          chunk.tool_calls.each do |_id, tool_call|
            existing = message[:tool_calls].find { |tc| tc[:id] == tool_call.id }
            if existing
              existing[:function][:arguments] += tool_call.arguments.to_s if tool_call.arguments
            else
              message[:tool_calls] << {
                id: tool_call.id,
                type: "function",
                function: {
                  name: tool_call.name,
                  arguments: tool_call.arguments.to_s
                }
              }
            end
          end
        end

        # Stream completion is handled by the base provider after
        # api_prompt_execute returns nil. No action needed here.
      end

      # Extracts messages from the completed API response.
      #
      # @param api_response [Hash, nil] normalized response hash
      # @return [Array<Hash>, nil]
      def process_prompt_finished_extract_messages(api_response)
        return nil unless api_response
        [ api_response ]
      end

      # Extracts tool/function calls from the last message in the stack.
      #
      # Converts RubyLLM's tool_calls format to ActiveAgent's expected format
      # with parsed JSON arguments.
      #
      # @return [Array<Hash>, nil] tool calls or nil
      def process_prompt_finished_extract_function_calls
        last_message = message_stack.last
        return nil unless last_message.is_a?(Hash)

        tool_calls = last_message[:tool_calls]
        return nil unless tool_calls&.any?

        tool_calls.map do |tc|
          args = tc.dig(:function, :arguments)
          parsed_args = if args.is_a?(String) && args.present?
            JSON.parse(args, symbolize_names: true)
          elsif args.is_a?(Hash)
            args.deep_symbolize_keys
          else
            {}
          end

          {
            id: tc[:id],
            name: tc.dig(:function, :name),
            input: parsed_args
          }
        end
      end

      # Extracts function names from tool_calls in assistant messages on the stack.
      #
      # @return [Array<String>]
      def extract_used_function_names
        message_stack
          .select { |msg| msg[:role] == "assistant" && msg[:tool_calls] }
          .flat_map { |msg| msg[:tool_calls] }
          .map { |tc| tc.dig(:function, :name) }
          .compact
      end

      # Returns true if tool_choice forces any tool to be used.
      #
      # Handles both string ("required") and hash ({name: "..."}) formats.
      #
      # @return [Boolean]
      def tool_choice_forces_required?
        request.tool_choice == "required"
      end

      # Returns [true, name] if tool_choice forces a specific tool.
      #
      # @return [Array<Boolean, String|nil>]
      def tool_choice_forces_specific?
        if request.tool_choice.is_a?(Hash)
          [ true, request.tool_choice[:name] ]
        else
          [ false, nil ]
        end
      end

      # Executes tool calls and pushes results to message_stack.
      #
      # @param tool_calls [Array<Hash>] with :id, :name, :input keys
      # @return [void]
      def process_function_calls(tool_calls)
        tool_calls.each do |tool_call|
          content = instrument("tool_call.active_agent", tool_name: tool_call[:name]) do
            tools_function.call(tool_call[:name], **tool_call[:input])
          end

          message_stack.push({
            role: "tool",
            tool_call_id: tool_call[:id],
            content: content.to_json
          })
        end
      end

      # api_prompt_execute always returns a normalized Hash or nil (streaming),
      # so no additional normalization is needed for instrumentation.
      # Inherits default api_response_normalize from BaseProvider.

      private

      # Resolves and caches the RubyLLM provider for the given model.
      #
      # Reuses the cached provider if the model hasn't changed (e.g., during
      # multi-turn tool calling loops).
      #
      # @param model_id [String] model identifier
      # @return [void]
      def resolve_ruby_llm_provider!(model_id)
        return if @ruby_llm_provider && @cached_model_id == model_id

        @cached_model_id = model_id
        @ruby_llm_model, @ruby_llm_provider = ::RubyLLM::Models.resolve(model_id, config: ::RubyLLM.config)
      end

      # Converts ActiveAgent messages to RubyLLM message format.
      #
      # Prepends system instructions as the first message if present.
      #
      # @param parameters [Hash] request parameters
      # @return [Array<Hash>] RubyLLM-formatted messages
      def build_ruby_llm_messages(parameters)
        messages = []

        # Add system instructions
        if parameters[:instructions].present?
          messages << ::RubyLLM::Message.new(
            role: :system,
            content: parameters[:instructions]
          )
        end

        # Convert each message
        (parameters[:messages] || []).each do |msg|
          ruby_llm_msg = if msg[:tool_call_id]
            ::RubyLLM::Message.new(
              role: :tool,
              content: msg[:content].to_s,
              tool_call_id: msg[:tool_call_id]
            )
          else
            attrs = {
              role: msg[:role].to_sym,
              content: extract_content_text(msg[:content])
            }
            attrs[:tool_calls] = convert_tool_calls_for_ruby_llm(msg[:tool_calls]) if msg[:tool_calls]
            ::RubyLLM::Message.new(**attrs)
          end

          messages << ruby_llm_msg
        end

        messages
      end

      # Extracts plain text from various content formats.
      #
      # @param content [String, Array, Object] message content
      # @return [String]
      def extract_content_text(content)
        case content
        when String
          content
        when Array
          content.select { |block| block.is_a?(Hash) && block[:type] == "text" }
                 .map { |block| block[:text] }
                 .join("\n")
        else
          content.to_s
        end
      end

      # Converts ActiveAgent tool_calls to RubyLLM's ToolCall format.
      #
      # @param tool_calls [Array<Hash>] ActiveAgent format tool calls
      # @return [Hash] RubyLLM format { id => ToolCall }
      def convert_tool_calls_for_ruby_llm(tool_calls)
        return nil unless tool_calls

        tool_calls.each_with_object({}) do |tc, hash|
          id = tc[:id]
          call = ::RubyLLM::ToolCall.new(
            id: id,
            name: tc.dig(:function, :name) || tc[:name],
            arguments: tc.dig(:function, :arguments) || tc[:input]&.to_json || "{}"
          )
          hash[id] = call
        end
      end

      # Converts ActiveAgent tool definitions to RubyLLM ToolProxy objects.
      #
      # @param tools [Array<Hash>, nil] ActiveAgent tool definitions
      # @return [Hash, nil] { "name" => ToolProxy }
      def build_ruby_llm_tools(tools)
        return nil unless tools&.any?

        tools.each_with_object({}) do |tool, hash|
          func = tool[:function] || tool
          proxy = RubyLLM::ToolProxy.new(
            name: func[:name],
            description: func[:description] || "",
            parameters: func[:parameters] || {}
          )
          hash[proxy.name] = proxy
        end
      end

      # Converts a RubyLLM::Message response to a normalized hash.
      #
      # @param response [RubyLLM::Message] the response message
      # @param model_id [String, nil] the model used
      # @return [Hash] normalized response hash
      def normalize_ruby_llm_response(response, model_id)
        hash = {
          role: "assistant",
          content: response.content.to_s
        }

        # Handle tool calls
        if response.tool_calls&.any?
          hash[:tool_calls] = response.tool_calls.map do |id, tc|
            {
              id: id,
              type: "function",
              function: {
                name: tc.name,
                arguments: tc.arguments.is_a?(String) ? tc.arguments : tc.arguments.to_json
              }
            }
          end
        end

        # Add stop_reason if available
        if response.respond_to?(:stop_reason) && response.stop_reason
          hash[:stop_reason] = response.stop_reason
        elsif response.tool_calls&.any?
          hash[:stop_reason] = "tool_use"
        else
          hash[:stop_reason] = "end_turn"
        end

        # Add usage info if available
        if response.respond_to?(:input_tokens) && response.input_tokens
          hash[:usage] = {
            input_tokens: response.input_tokens,
            output_tokens: response.output_tokens
          }
        end

        hash[:model] = model_id if model_id

        hash
      end
    end
  end
end
