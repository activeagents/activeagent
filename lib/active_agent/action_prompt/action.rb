module ActiveAgent
  module ActionPrompt
    class Action
      attr_accessor :agent_name, :id, :name, :params

      def initialize(attributes = {})
        @id = attributes.fetch(:id, nil)
        @name = attributes.fetch(:name, "")
        @params = attributes.fetch(:params, {})
      end
    end
  end
end
