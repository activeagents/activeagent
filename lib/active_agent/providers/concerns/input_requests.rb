# frozen_string_literal: true

require "active_agent/input_request"

module ActiveAgent
  module Providers
    # Pauses a generation when a tool returns an {ActiveAgent::InputRequest},
    # and resumes it from the checkpoint with the user's answers.
    #
    # A provider takes part by running a turn's tool calls through
    # {#dispatch_tool_calls} and building its result messages from what that
    # returns. Under a provider whose tool loop calls `call_tool_function`
    # directly, a tool that returns an InputRequest, or a tool that needs
    # approval, raises {ActiveAgent::InputRequest::UnsupportedProviderError}.
    #
    # A tool needs approval when the `requires_approval:` prompt option names
    # it, or when it is served by a client-side MCP server whose declaration's
    # `require_approval` covers it (see {MCPBridge#requires_approval?}). Its
    # call then pauses with a `:confirm` request before the tool runs, and runs
    # only once the user approves it.
    module InputRequests
      extend ActiveSupport::Concern

      # The metadata of a request the approval gate makes, as opposed to one
      # a tool returned.
      APPROVAL_METADATA = { "approval" => true }.freeze

      included do
        # The agent action the generation runs, recorded in a checkpoint.
        attr_internal :generation_action_name

        # The tool names the `requires_approval:` prompt option lists.
        attr_internal :tool_approvals

        # The checkpoint and answers being resumed from, until the paused
        # turn's results have been dispatched.
        attr_internal :input_request_resume

        # The completed results and input requests of a turn that paused.
        attr_internal :paused_tool_turn

        # Whether a pause publishes `input_requested.active_agent`.
        attr_internal :announce_input_requests
      end

      # @return [Boolean] whether the last tool turn left calls waiting on the user
      def awaiting_input? = paused_tool_turn.present?

      protected

      # Continues a paused generation from where it stopped: the assistant turn
      # that made the tool calls goes back on the message stack, the calls are
      # dispatched with their answers, and the tool loop carries on.
      #
      # @return [Common::PromptResponse]
      # @raise [ActiveAgent::InputRequest::ResumeError] before any tool runs,
      #   when the checkpoint was taken on another provider or model, or its
      #   tool calls do not match its results and requests
      def resume_prompt
        resume = input_request_resume
        resume.assert_provider!(service: service_name, provider: tag_name, model: request.model)

        clear_tool_choice if resume.tool_choice_cleared?
        message_stack.push(*resume.tool_call_turn)
        tool_calls = Array(process_prompt_finished_extract_function_calls)
        resume.assert_tool_calls!(tool_calls.map { tool_call_reference(_1).first })

        self.tool_turns = resume.tool_turns
        process_function_calls(tool_calls)
        return paused_prompt_response if awaiting_input?

        resolve_prompt
      end

      # Runs a turn's tool calls, each through the block, and returns their
      # results in call order.
      #
      # Returns nil when a call paused: its tool returned an InputRequest, or
      # it needs approval and has none yet, in which case the tool does not
      # run. The other calls still run, and their results are kept for the
      # checkpoint rather than sent: the turn's results go to the model
      # together, once every call has one.
      #
      # On resume:
      #   - a call completed before the pause reuses its result in JSON form
      #   - a declined call gets {ActiveAgent::InputRequest::DECLINED_RESULT}
      #     without running
      #   - a call to a client-side MCP tool its server no longer offers gets
      #     an `{ error: }` result without running
      #   - a call that waited for approval runs once approved, with no answer
      #     in execution state: the approval answers the gate, not the tool
      #   - any other paused call runs again with its answer readable through
      #     {ActiveAgent::InputRequest.answer_for}
      #
      # @param calls [Array<Hash>] provider-native tool calls
      # @yieldparam call [Hash] one call to run
      # @yieldreturn [Object] the tool's result
      # @return [Array<Object>, nil]
      def dispatch_tool_calls(calls, &block)
        resume = input_request_resume
        paused = []
        gated  = []

        results = calls.map do |call|
          id, name = tool_call_reference(call)
          result   = dispatch_tool_call(call, id, name, resume, gated, &block)
          next result unless result.is_a?(ActiveAgent::InputRequest)

          result = result.for_tool_call(id:, name:, arguments: tool_call_arguments(call))
          paused << [ id, name, result ]
          result
        end

        self.input_request_resume = nil
        return results if paused.empty?

        requests = paused.map(&:last)
        self.paused_tool_turn = {
          results:             completed_results(calls, results, requests),
          input_requests:      requests,
          approval_tool_calls: gated,
          approved_tool_calls: paused.filter_map { |id, _, _| id if resume && (resume.approval_given?(id) || resume.approved?(id)) },
          mcp_tool_calls:      paused.filter_map { |id, name, _| id if mcp_owns_tool?(name) }
        }
        nil
      end

      # Returns the id and tool name of a provider-native tool call. Providers
      # whose calls carry them elsewhere override this.
      #
      # @param call [Hash]
      # @return [Array(String, String)]
      def tool_call_reference(call)
        [ call[:id].to_s, call[:name].to_s ]
      end

      # Returns the arguments of a provider-native tool call, as the model
      # sent them. Providers whose calls carry them elsewhere override this.
      #
      # @param call [Hash]
      # @return [Hash, nil]
      def tool_call_arguments(call)
        call[:input]
      end

      # @param json [String, nil] arguments a model sent as a JSON string
      # @return [Hash, String, nil] the parsed arguments, or `json` itself
      #   when it is not valid JSON
      def parse_tool_call_arguments(json)
        return json unless json.is_a?(String)
        return {} if json.blank?

        JSON.parse(json)
      rescue JSON::ParserError
        json
      end

      # Whether a call to the tool must be approved before the tool runs.
      #
      # @param name [String, Symbol]
      # @return [Boolean]
      def approval_required?(name)
        Array(tool_approvals).include?(name.to_s) || (mcp_owns_tool?(name) && mcp_bridge.requires_approval?(name))
      end

      # @param name [String, Symbol] the tool about to run
      # @raise [ActiveAgent::InputRequest::UnsupportedProviderError] when the
      #   tool needs approval and the call was not dispatched through
      #   {#dispatch_tool_calls}, which is where the approval is asked for
      def assert_approval_gate_reached!(name)
        return if @_dispatching_tool_call || !approval_required?(name)

        raise ActiveAgent::InputRequest::UnsupportedProviderError,
              "#{tag_name} ran #{name}, which needs approval, outside dispatch_tool_calls, so nobody was asked to approve it."
      end

      # Runs a tool call made outside {#dispatch_tool_calls} with no tool call
      # in execution state. Such a call can neither pause nor be answered, and
      # it must not read the answer of an enclosing call that started this
      # generation.
      #
      # @return [Object] the block's result
      def isolate_undispatched_tool_call(&block)
        return yield if @_dispatching_tool_call

        ActiveAgent::InputRequest.dispatching(nil, &block)
      end

      # @param result [Object] what a tool returned
      # @raise [ActiveAgent::InputRequest::UnsupportedProviderError] when the
      #   result is an InputRequest and the call was not dispatched through
      #   {#dispatch_tool_calls}
      def assert_input_request_supported!(result)
        return unless result.is_a?(ActiveAgent::InputRequest) && !@_dispatching_tool_call

        raise ActiveAgent::InputRequest::UnsupportedProviderError,
              "#{tag_name} cannot pause a generation for user input: its tool loop does not run calls through " \
              "dispatch_tool_calls, and a tool returned an ActiveAgent::InputRequest."
      end

      # Builds the response for a generation that is waiting on the user, and
      # announces it with `input_requested.active_agent` unless
      # `announce_input_requests` is false.
      #
      # @param api_response [Hash, nil] the response that made the tool calls
      # @return [Common::PromptResponse]
      def paused_prompt_response(api_response = nil)
        broadcast_stream_close

        input_requests = paused_tool_turn[:input_requests]
        instrument("input_requested.active_agent", input_requests:) if announce_input_requests

        build_prompt_response(api_response, input_requests:, checkpoint:)
      end

      # Returns a JSON-safe hash {ActiveAgent::Generation#resume_now} continues
      # from; see {ActiveAgent::InputRequest::Resume} for its keys.
      #
      # @return [Hash{String => Object}]
      def checkpoint
        {
          version:             ActiveAgent::InputRequest::Resume::VERSION,
          service:             service_name,
          provider:            tag_name,
          model:               request.model&.to_s,
          action_name:         generation_action_name,
          tool_turns:,
          tool_choice_cleared: tool_choice_cleared == true,
          messages:            checkpoint_messages,
          tool_call_turn_size: serialized_messages(message_stack).size,
          completed_results:   paused_tool_turn[:results],
          input_requests:      paused_tool_turn[:input_requests].map(&:to_h),
          approval_tool_calls: paused_tool_turn[:approval_tool_calls],
          approved_tool_calls: paused_tool_turn[:approved_tool_calls],
          mcp_tool_calls:      paused_tool_turn[:mcp_tool_calls]
        }.as_json
      end

      # Returns `messages` in the provider's serialized form.
      #
      # @param messages [Array, nil]
      # @param instructions [String, Array, nil]
      # @return [Array<Hash>]
      def serialized_messages(messages, instructions: nil)
        parameters = { messages:, instructions: }.compact
        return [] if parameters.empty?

        prompt_request_type.serialize(prompt_request_type.cast(parameters))[:messages] || []
      end

      private

      # Runs one call of a turn, or answers it without running the tool.
      #
      # Whether a paused call waited for approval is read from the checkpoint,
      # so a resume whose `requires_approval:` differs still treats the answer
      # as an approval and never hands it to the tool.
      #
      # @param gated [Array<String>] collects the ids of calls the approval
      #   gate pauses
      # @return [Object] the tool's result, or an InputRequest when the call
      #   pauses
      def dispatch_tool_call(call, id, name, resume, gated)
        if resume&.completed?(id)
          resume.completed_result(id)
        elsif resume&.declined?(id)
          ActiveAgent::InputRequest::DECLINED_RESULT
        elsif resume&.mcp_tool_call?(id) && !mcp_owns_tool?(name)
          { error: "#{name} is no longer offered by its MCP server" }
        elsif resume&.approval_given?(id)
          dispatching_tool_call(id, answer: nil) { yield call }
        elsif resume&.approved?(id) || !approval_required?(name)
          dispatching_tool_call(id, answer: resume&.answer(id)) { yield call }
        else
          gated << id
          ActiveAgent::InputRequest.confirm("Allow #{name} to run?", metadata: APPROVAL_METADATA)
        end
      end

      # Returns the conversation through the assistant tool-call turn, in the
      # provider's serialized form, without the messages the provider derives
      # from instructions (OpenAI Chat's developer message): a resumed
      # generation renders its instructions again. The caller's messages are
      # cast without instructions, and every later message follows them.
      #
      # @return [Array<Hash>]
      def checkpoint_messages
        conversation         = serialized_messages([ *request.messages, *message_stack ])
        with_instructions    = serialized_messages(context[:messages], instructions: context[:instructions])
        without_instructions = serialized_messages(context[:messages])

        without_instructions + conversation.drop(with_instructions.size)
      end

      # @return [Hash{String => Object}] each finished call's result in JSON
      #   form, by call id
      # @raise [ArgumentError] when the calls lack unique ids, which a
      #   checkpoint needs to match results and answers to calls
      def completed_results(calls, results, requests)
        ids = calls.map { tool_call_reference(_1).first }
        if ids.any?(&:blank?) || ids.uniq.size != ids.size
          raise ArgumentError, "#{tag_name} returned tool calls without unique ids, so the generation cannot pause for input"
        end

        paused = requests.map(&:tool_call_id)
        ids.zip(results).reject { |id, _| paused.include?(id) }.to_h { |id, result| [ id, result.as_json ] }
      end

      # @return [Object] the block's result
      def dispatching_tool_call(id, answer:)
        previous, @_dispatching_tool_call = @_dispatching_tool_call, true

        ActiveAgent::InputRequest.dispatching(id, answer:) { yield }
      ensure
        @_dispatching_tool_call = previous
      end
    end
  end
end
