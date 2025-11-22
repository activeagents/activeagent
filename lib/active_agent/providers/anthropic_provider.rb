# lib/active_agent/providers/anthropic_provider.rb

require_relative "_base_provider"

require_gem!(:anthropic, __FILE__)

require_relative "anthropic/_types"
require_relative "anthropic/transforms"

module ActiveAgent
  module Providers
    # Handles communication with Anthropic's Claude models.
    #
    # Supports message creation, streaming responses, tool calling, and Claude-specific
    # features like thinking mode and content blocks. Manages tool choice cleanup to
    # prevent endless looping when tools have been used in conversation history.
    #
    # @see BaseProvider
    class AnthropicProvider < BaseProvider
      # Lead-in message for JSON response format emulation
      JSON_RESPONSE_FORMAT_LEAD_IN = "Here is the JSON requested:\n{"

      attr_internal :json_format_retry_count

      def initialize(kwargs = {})
        super

        self.json_format_retry_count = kwargs[:max_retries] || ::Anthropic::Client::DEFAULT_MAX_RETRIES
      end

      # @todo Add support for Anthropic::BedrockClient and Anthropic::VertexClient
      # @return [Anthropic::Client]
      def client
        ::Anthropic::Client.new(**options.serialize)
      end

      protected

      # Removes forced tool choice after first use to prevent endless looping.
      #
      # Clears tool_choice when the specified tool has already been called in the
      # conversation, preventing the model from being forced to call it repeatedly.
      #
      # @see BaseProvider#prepare_prompt_request
      # @return [Request]
      def prepare_prompt_request
        prepare_prompt_request_tools
        prepare_prompt_request_response_format

        super
      end

      # Extracts function names from Anthropic's tool_use content blocks.
      #
      # @return [Array<String>]
      def extract_used_function_names
        message_stack.pluck(:content).flatten.select { _1[:type] == "tool_use" }.pluck(:name)
      end

      # Checks if tool_choice requires the model to call any tool.
      #
      # @return [Boolean] true if tool_choice type is :any
      def tool_choice_forces_required?
        return false unless request.tool_choice.respond_to?(:type)

        request.tool_choice.type == :any
      end

      # Checks if tool_choice requires a specific tool to be called.
      #
      # @return [Array<Boolean, String|nil>] [true, tool_name] if forcing a specific tool, [false, nil] otherwise
      def tool_choice_forces_specific?
        return [ false, nil ] unless request.tool_choice.respond_to?(:type)
        return [ false, nil ] unless request.tool_choice.type == :tool

        tool_name = request.tool_choice.respond_to?(:name) ? request.tool_choice.name : nil
        [ true, tool_name ]
      end

      # @api private
      def prepare_prompt_request_response_format
        return unless request.response_format&.dig(:type) == "json_object"

        self.message_stack.push({
          role:    "assistant",
          content: JSON_RESPONSE_FORMAT_LEAD_IN
        })
      end

      # Selects between Anthropic's stable and beta message APIs.
      #
      # Uses beta API when explicitly requested via anthropic_beta option or when
      # using MCP servers, which require beta features. Falls back to stable API
      # for standard message creation.
      #
      # @see BaseProvider#api_prompt_executer
      # @return [Anthropic::Messages, Anthropic::Resources::Beta::Messages]
      def api_prompt_executer
        # Use beta API when anthropic_beta option is set or when using MCP servers
        if options.anthropic_beta.present? || request.mcp_servers&.any?
          client.beta.messages
        else
          client.messages
        end
      end

      # @see BaseProvider#api_response_normalize
      # @param api_response [Anthropic::Models::Message]
      # @return [Hash]
      def api_response_normalize(api_response)
        return api_response unless api_response

        Anthropic::Transforms.gem_to_hash(api_response)
      end

      # Processes streaming chunks and builds message incrementally in message_stack.
      #
      # Handles chunk types: message_start, content_block_start, content_block_delta,
      # content_block_stop, message_delta, message_stop. Manages text deltas,
      # tool use inputs, and Claude's thinking/signature blocks.
      #
      # @see BaseProvider#process_stream_chunk
      # @param api_response_chunk [Anthropic::StreamEvent]
      # @return [void]
      def process_stream_chunk(api_response_chunk)
        chunk_type = api_response_chunk[:type]&.to_sym

        instrument("stream_chunk.active_agent", chunk_type:)

        broadcast_stream_open

        case chunk_type
        # Message Created
        when :message_start
          api_message = Anthropic::Transforms.gem_to_hash(api_response_chunk.message)
          self.message_stack.push(api_message)
          broadcast_stream_update(message_stack.last)

        # -> Content Block Create
        when :content_block_start
          api_content = Anthropic::Transforms.gem_to_hash(api_response_chunk.content_block)
          self.message_stack.last[:content].push(api_content)
          broadcast_stream_update(message_stack.last, api_content[:text])

        # -> -> Content Block Append
        when :content_block_delta
          index     = api_response_chunk.index
          content   = self.message_stack.last[:content][index]
          api_delta = api_response_chunk.delta

          case api_delta.type.to_sym
          # -> -> -> Content Text Append
          when :text_delta
            content[:text] += api_delta.text
            broadcast_stream_update(message_stack.last, api_delta.text)

          # -> -> -> Content Function Call Append
          when :input_json_delta
            # No-Op; Wait for Function call to be complete
          when :thinking_delta, :signature_delta
            # TODO: Add with thinking rendering support
          else
            raise "Unexpected delta type: #{api_delta.type}"
          end
        # -> Content Block Completed [Full Block]
        when :content_block_stop
          index       = api_response_chunk.index
          api_content = Anthropic::Transforms.gem_to_hash(api_response_chunk.content_block)
          self.message_stack.last[:content][index] = api_content

        # Message Delta
        when :message_delta
          delta = Anthropic::Transforms.gem_to_hash(api_response_chunk.delta)
          self.message_stack.last.merge!(delta)

        # Message Completed [Full Message]
        when :message_stop
          api_message = Anthropic::Transforms.gem_to_hash(api_response_chunk.message)

          # Handle _json_buf (gem >= 1.14.0)
          api_message[:content]&.each do |content_block|
            content_block.delete(:_json_buf) if content_block[:type] == "tool_use"
          end

          self.message_stack[-1] = api_message

          # Once we are finished, close out and run tooling callbacks (Recursive)
          process_prompt_finished if message_stack.last[:stop_reason]
        when :ping
          # No-Op Keep Awake
        when :overloaded_error
          # TODO: https://docs.claude.com/en/docs/build-with-claude/streaming#error-events
        else
          # No-Op: Looks like internal tracking from gem wrapper
          return if api_response_chunk.respond_to?(:snapshot)
          raise "Unexpected chunk type: #{api_response_chunk.type}"
        end
      end

      # Executes tool calls and appends user message with results to message_stack.
      #
      # @param api_function_calls [Array<Hash>] with :name, :input, and :id keys
      # @return [void]
      def process_function_calls(api_function_calls)
        content = api_function_calls.map do |api_function_call|
          process_tool_call_function(api_function_call)
        end

        api_message = ::Anthropic::Models::MessageParam.new(role: "user", content:)
        message     = Anthropic::Transforms.gem_to_hash(api_message)

        message_stack.push(message)
      end

      # Executes a single tool call via callback.
      #
      # @param api_function_call [Hash] with :name, :input, and :id keys
      # @return [Anthropic::Models::ToolResultBlockParam]
      def process_tool_call_function(api_function_call)
        instrument("tool_call.active_agent", tool_name: api_function_call[:name]) do
          results = tools_function.call(
            api_function_call[:name], **api_function_call[:input]
          )

          ::Anthropic::Models::ToolResultBlockParam.new(
            type:        "tool_result",
            tool_use_id: api_function_call[:id],
            content:     results.to_json,
            is_error:    false
          )
        end
      end

      # Processes completed API response and handles JSON format retries.
      #
      # When response_format is json_object and the response fails JSON validation,
      # recursively retries the request to obtain well-formed JSON.
      #
      # @see BaseProvider#process_prompt_finished
      # @param api_response [Anthropic::Models::Message]
      # @return [Common::PromptResponse, nil]
      def process_prompt_finished(api_response = nil)
        # Convert gem object to hash so that raw_response[:usage] works
        api_response_hash = api_response ? Anthropic::Transforms.gem_to_hash(api_response) : nil

        common_response = super(api_response_hash)

        # If we failed to get the expected well formed JSON Object Response, recursively try again
        if request.response_format&.dig(:type) == "json_object" && common_response.message.parsed_json.nil? && json_format_retry_count > 0
          self.json_format_retry_count -= 1

          resolve_prompt
        else
          common_response
        end
      end

      # Reconstructs JSON responses that were split due to Anthropic format constraints.
      #
      # Anthropic's API doesn't natively support json_object response format, so we
      # simulate it by having the assistant echo a JSON lead-in ("Here is the JSON requested:\n{"),
      # then send the response back for completion. This method detects and reverses
      # that workaround by stripping the lead-in message and prepending "{" to the response.
      #
      # @see BaseProvider#process_prompt_finished_extract_messages
      # @param api_response [Hash] API response with content blocks
      # @return [Array<Hash>, nil]
      def process_prompt_finished_extract_messages(api_response)
        return unless api_response

        # Get the last message (may be either Hash or gem object)
        last_message = request.messages.last
        last_role    = last_message.is_a?(Hash) ? last_message[:role]    : last_message&.role
        last_content = last_message.is_a?(Hash) ? last_message[:content] : last_message&.content

        # Check if the last message in request is the JSON lead-in prompt
        if last_role.to_sym == :assistant && last_content == JSON_RESPONSE_FORMAT_LEAD_IN
          # Remove the lead-in message from the request
          request.messages.pop

          # Prepend "{" to the response's first content text
          if api_response[:content]&.first&.dig(:text)
            api_response[:content][0][:text] = "{#{api_response[:content][0][:text]}"
          end
        end

        [ api_response ]
      end

      # Extracts tool_use blocks from message_stack and parses JSON inputs.
      #
      # Handles JSON buffer parsing for gem versions and string inputs for gem >= 1.14.0.
      #
      # @see BaseProvider#process_prompt_finished_extract_function_calls
      # @return [Array<Hash>] with :name, :input, and :id keys
      def process_prompt_finished_extract_function_calls
        message_stack.pluck(:content).flatten.select { _1 in { type: "tool_use" } }.map do |api_function_call|
          json_buf = api_function_call.delete(:json_buf)
          api_function_call[:input] = JSON.parse(json_buf, symbolize_names: true) if json_buf

          # Handle case where :input is still a JSON string (gem >= 1.14.0)
          if api_function_call[:input].is_a?(String)
            api_function_call[:input] = JSON.parse(api_function_call[:input], symbolize_names: true)
          end

          api_function_call
        end
      end
    end
  end
end
