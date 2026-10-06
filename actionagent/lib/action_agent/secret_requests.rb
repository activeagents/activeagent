# frozen_string_literal: true

module ActionAgent
  # The agents allowed to ask a person for a secret with the `request_secret`
  # tool, each with the handler the answer is delivered to.
  #
  # Only agents the engine defines register here. The secret never reaches
  # the model, so an agent may ask for one only when engine code is there to
  # receive it. An agent is matched on its `agent_class_name`, which a
  # dashboard user can also type, so a handler checks the run it is given is
  # one it expects before keeping the value.
  #
  # A handler is a block, or an object with #call. An object may also
  # answer these, each optional:
  #
  #   refusal(run:, name:)           why the run may not ask for +name+, or
  #                                  nil; the model reads it as the call's
  #                                  error and nobody is asked
  #   prompt(run:, name:, prompt:)   the question a person reads, in place
  #                                  of the model's +prompt+
  #   answerable_by?(request, user)  whether +user+ may answer +request+, on
  #                                  top of InputRequest#answerable_by?
  #
  # @example
  #   ActionAgent::SecretRequests.register("ActionAgent::SetupAgent") do |run:, name:, value:|
  #     ProjectSecret.store!(run:, name:, value:)
  #   end
  #
  # @api private
  module SecretRequests
    @handlers = {}

    class << self
      # @param agent_class_name [String]
      # @param handler [#call, nil] the handler, unless given as a block
      # @yieldparam run [AgentRun] the run the answer belongs to
      # @yieldparam name [String] the secret's name, as the model asked for it
      # @yieldparam value [String] the answer
      def register(agent_class_name, handler = nil, &block)
        handler ||= block
        raise ArgumentError, "A secret request handler needs a block or an object with #call" unless handler.respond_to?(:call)

        @handlers[agent_class_name.to_s] = handler
      end

      def unregister(agent_class_name)
        @handlers.delete(agent_class_name.to_s)
      end

      # @param agent [Agent, nil]
      # @return [#call, nil]
      def handler_for(agent)
        name = agent&.agent_class_name.to_s
        name.empty? ? nil : @handlers[name]
      end

      # Why +run+'s agent may not ask for +name+, or nil.
      def refusal(agent, run:, name:)
        handler = handler_for(agent)
        handler.respond_to?(:refusal) ? handler.refusal(run: run, name: name) : nil
      end

      # The question a person is asked for +name+: the handler's wording, or
      # the model's +prompt+.
      def prompt(agent, run:, name:, prompt:)
        handler = handler_for(agent)
        handler.respond_to?(:prompt) ? handler.prompt(run: run, name: name, prompt: prompt) : prompt
      end

      # Whether +request+'s handler lets +user+ answer it. True for anything
      # but a `secret` request whose agent's handler decides.
      def answerable_by?(request, user)
        return true unless request.kind == "secret"

        handler = handler_for(request.subject.try(:agent))
        handler.respond_to?(:answerable_by?) ? handler.answerable_by?(request, user) == true : true
      end
    end
  end
end
