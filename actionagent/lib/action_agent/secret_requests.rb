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
      # @yieldparam run [AgentRun] the run the answer belongs to
      # @yieldparam name [String] the secret's name, as the model asked for it
      # @yieldparam value [String] the answer
      def register(agent_class_name, &handler)
        raise ArgumentError, "A secret request handler needs a block" unless handler

        @handlers[agent_class_name.to_s] = handler
      end

      def unregister(agent_class_name)
        @handlers.delete(agent_class_name.to_s)
      end

      # @param agent [Agent, nil]
      # @return [Proc, nil]
      def handler_for(agent)
        name = agent&.agent_class_name.to_s
        name.empty? ? nil : @handlers[name]
      end
    end
  end
end
