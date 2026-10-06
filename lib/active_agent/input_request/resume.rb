# frozen_string_literal: true

module ActiveAgent
  class InputRequest
    # A paused generation's checkpoint together with the user's answers,
    # checked against each other before anything runs.
    #
    # Checkpoint keys, as {Providers::InputRequests#checkpoint} writes them:
    #   - `version`            the checkpoint format, {VERSION}
    #   - `service`, `provider` the provider service and API that paused, e.g.
    #                          `"OpenAI"` and `"OpenAI::Chat"`
    #   - `model`              the model of the paused request
    #   - `action_name`        the agent action the generation ran
    #   - `tool_turns`         tool round-trips used, counted against `max_tool_turns`
    #   - `tool_choice_cleared` whether a forced `tool_choice` was already
    #                          cleared because the model used the tool
    #   - `messages`           the provider-native conversation through the
    #                          assistant turn that made the tool calls, without
    #                          the messages the provider derives from instructions
    #   - `completed_results`  each finished call's result in JSON form, by tool call id
    #   - `input_requests`     one {InputRequest#to_h} per paused call
    #
    # @api private
    class Resume
      VERSION = 1

      # @return [Array<InputRequest>] one per paused tool call
      attr_reader :input_requests

      # @param checkpoint [Hash] string or symbol keys
      # @param answers [Hash] an answer per paused tool call id
      # @raise [ResumeError] when the checkpoint is malformed, or the answers
      #   leave a paused call unanswered, name a call that is not paused, or
      #   do not fit their request's kind
      def initialize(checkpoint:, answers:)
        @checkpoint = checkpoint.to_h.deep_symbolize_keys
        @answers    = answers.to_h.transform_keys(&:to_s)

        raise ResumeError, "Unsupported checkpoint version #{@checkpoint[:version].inspect}" unless @checkpoint[:version] == VERSION
        raise ResumeError, "The checkpoint has no assistant tool-call turn to resume from" unless tool_call_turn.is_a?(Hash) && tool_call_turn[:role].to_s == "assistant"

        @input_requests = Array(@checkpoint[:input_requests]).map { InputRequest.from_h(_1) }
        @completed      = @checkpoint[:completed_results].to_h.transform_keys(&:to_s)

        assert_answers!
      end

      # @return [String, nil]
      def service = @checkpoint[:service]

      # @return [String, nil]
      def provider = @checkpoint[:provider]

      # @return [String, nil]
      def model = @checkpoint[:model]

      # @return [String, nil]
      def action_name = @checkpoint[:action_name]

      # @return [Integer]
      def tool_turns = @checkpoint[:tool_turns].to_i

      # @return [Boolean]
      def tool_choice_cleared? = @checkpoint[:tool_choice_cleared] == true

      # Returns the conversation before the turn that made the tool calls.
      #
      # @return [Array<Hash>]
      def messages = Array(@checkpoint[:messages])[0...-1]

      # Returns the assistant turn that made the tool calls.
      #
      # @return [Hash]
      def tool_call_turn = Array(@checkpoint[:messages]).last

      # @param id [String]
      # @return [Boolean]
      def completed?(id) = @completed.key?(id.to_s)

      # @param id [String]
      # @return [Object] the call's result, in JSON form
      def completed_result(id) = @completed.fetch(id.to_s)

      # @param id [String]
      # @return [Boolean]
      def declined?(id) = pending?(id) && @answers[id.to_s] == false

      # @param id [String]
      # @return [Object, nil] the answer for a paused call; nil for any other call
      def answer(id) = pending?(id) ? @answers[id.to_s] : nil

      # Returns the answers given to `:secret` requests, which must not reach
      # the model, telemetry or errors.
      #
      # @return [Array<String>]
      def secret_answers
        input_requests.select(&:secret?).filter_map do |request|
          value = answer(request.tool_call_id)
          value.to_s unless value == false
        end
      end

      # @param action_name [String, Symbol, nil] the action the agent ran again
      # @raise [ResumeError] when it is not the action that paused
      def assert_action!(action_name)
        return if self.action_name.to_s == action_name.to_s

        raise ResumeError, "This checkpoint was taken in #{self.action_name.inspect}; it cannot resume #{action_name.to_s.inspect}"
      end

      # @raise [ResumeError] when the provider or model differ from the pause's,
      #   since the checkpoint's messages are in that provider's native format
      def assert_provider!(service:, provider:, model:)
        return if [ self.service, self.provider ] == [ service, provider ] && (self.model.blank? || self.model == model.to_s)

        raise ResumeError, "This checkpoint was taken on #{self.provider} (#{self.model}); " \
                           "it cannot resume on #{provider} (#{model})"
      end

      # @param ids [Array<String>] the ids of the calls in the tool-call turn
      # @raise [ResumeError] unless every call is either completed or paused
      def assert_tool_calls!(ids)
        ids     = ids.map(&:to_s)
        unknown = ids.reject { completed?(_1) || pending?(_1) }
        lost    = pending_ids - ids
        return if unknown.empty? && lost.empty?

        raise ResumeError, "The checkpoint's tool calls do not match its results and input requests " \
                           "(unaccounted: #{unknown.join(", ").presence || "none"}; missing: #{lost.join(", ").presence || "none"})"
      end

      private

      def pending_ids = input_requests.map(&:tool_call_id)

      def pending?(id) = pending_ids.include?(id.to_s)

      def assert_answers!
        unknown = @answers.keys - pending_ids
        raise ResumeError, "No input request is waiting on #{unknown.join(", ")}" if unknown.any?

        missing = pending_ids.select { @answers[_1].nil? }
        raise ResumeError, "Missing answers for #{missing.join(", ")}" if missing.any?

        input_requests.each { assert_answer_fits!(_1, @answers[_1.tool_call_id]) }
      end

      def assert_answer_fits!(request, answer)
        return if answer == false

        case request.kind
        when :confirm
          raise ResumeError, "Answer #{request.tool_call_id} with true to approve or false to decline" unless answer == true
        when :choice
          allowed = request.choice_values.map(&:to_s)
          raise ResumeError, "#{answer.inspect} is not one of the options for #{request.tool_call_id}" unless allowed.include?(answer.to_s)
        end
      end
    end
  end
end
