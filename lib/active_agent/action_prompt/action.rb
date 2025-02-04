module ActiveAgent
  module ActionPrompt
    class Action
      attr_accessor :agent_name, :name, :params

      def initialize(attributes = {})
        @name = attributes.fetch(:name, "")
        @params = attributes.fetch(:params, {})
      end

      def perform_action
        agent_name.constantize
      end
    end
  end
end
