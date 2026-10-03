# frozen_string_literal: true

require "active_agent/input_request"

module ActiveAgent
  # Lets a generation pause for the user and continue with the answers.
  #
  # A tool asks by returning an {InputRequest}. The generation then ends
  # paused, and {Generation#resume_now} continues it from the response's
  # checkpoint. See {InputRequest} for the kinds of request and what an
  # answer does.
  #
  # @example Asking for confirmation before a side effect
  #   class SupportAgent < ApplicationAgent
  #     on_input_request :notify_reviewer
  #
  #     def issue_refund(order_id:, amount:)
  #       return ActiveAgent::InputRequest.confirm("Refund #{amount} on order #{order_id}?") unless input_answer
  #
  #       Refund.create!(order_id:, amount:)
  #     end
  #
  #     private
  #
  #     def notify_reviewer(response)
  #       ReviewMailer.pending(response.input_requests.map(&:prompt)).deliver_later
  #     end
  #   end
  module InputRequests
    extend ActiveSupport::Concern

    included do
      define_callbacks :input_request
    end

    class_methods do
      # Registers callbacks run when a generation pauses for input, before the
      # paused response is returned. A callback that takes an argument receives
      # the paused response.
      #
      # @param names [Array<Symbol>] methods to call
      # @param block [Proc] optional block to call
      # @return [void]
      def on_input_request(*names, &block)
        _insert_callbacks(names, block) do |callback, options|
          set_callback(:input_request, :before, ->(agent) { agent.send(:run_input_request_callback, callback) }, **options)
        end

        # The first callback a class sets makes ActiveSupport alias the chain's
        # runner into that class as a public method, which would list it among
        # the agent's actions and in its release digest.
        private :_run_input_request_callbacks if public_method_defined?(:_run_input_request_callbacks, false)
      end
    end

    # Whether this generation continues one that paused for input.
    #
    # @return [Boolean]
    def resuming?
      !@_input_request_resume.nil?
    end

    # Returns the answer for the tool call being run, when the call is being
    # dispatched again on resume; nil otherwise.
    #
    # @return [Object, nil]
    def input_answer
      InputRequest.answer_for(InputRequest.current_tool_call_id)
    end

    # Continues a generation that paused for input. The action has already
    # run again, so tools, instructions and options are current; the
    # conversation is replaced with the checkpoint's, not merged with what the
    # action added.
    #
    # Answers to `:secret` requests are scrubbed from every tool result and
    # tool error of this generation, so they reach neither the model nor
    # telemetry.
    #
    # @param checkpoint [Hash] the paused response's checkpoint
    # @param answers [Hash] an answer per paused tool call id
    # @return [ActiveAgent::Providers::Common::PromptResponse]
    # @raise [InputRequest::ResumeError] before any tool runs or any request
    #   is sent, when the answers or the checkpoint do not fit
    def resume_prompt(checkpoint:, answers:)
      resume = InputRequest::Resume.new(checkpoint:, answers:)
      resume.assert_action!(action_name)

      input_request_secrets.concat(resume.secret_answers)
      prompt_options[:messages] = resume.messages
      @_input_request_resume = resume

      process_prompt
    ensure
      @_input_request_resume = nil
    end

    private

    # @return [Array<String>] the secret answers this generation has received
    def input_request_secrets
      @_input_request_secrets ||= []
    end

    # @param value [Object]
    # @return [Object] `value` without any secret answer in it
    def scrub_input_request_secrets(value)
      InputRequest.scrub(value, input_request_secrets)
    end

    # @param error [Exception]
    # @return [Exception] `error`, or a copy whose message holds no secret answer
    def scrub_input_request_secrets_error(error)
      InputRequest.scrub_error(error, input_request_secrets)
    end

    # Calls one on_input_request callback, with the paused response when it
    # takes an argument.
    #
    # @param callback [Symbol, Proc]
    # @return [void]
    def run_input_request_callback(callback)
      if callback.is_a?(Proc)
        callback.arity.zero? ? instance_exec(&callback) : instance_exec(@_input_request_response, &callback)
      else
        method(callback).arity.zero? ? send(callback) : send(callback, @_input_request_response)
      end
    end

    # Runs the on_input_request callbacks for a paused response.
    #
    # @param response [ActiveAgent::Providers::Common::PromptResponse]
    # @return [void]
    def run_input_request_callbacks(response)
      return unless response.respond_to?(:awaiting_input?) && response.awaiting_input?

      @_input_request_response = response
      run_callbacks(:input_request)
    ensure
      @_input_request_response = nil
    end
  end
end
