module ActiveAgent
  module ActionPrompt
    class Action
      attr_accessor :agent_name, :id, :name, :params, :description, :parameters

      def initialize(attributes = {})
        @id = attributes.fetch(:id, nil)
        @name = attributes.fetch(:name, "")
        @params = attributes.fetch(:params, {})
        @description = attributes.fetch(:description, "")
        @parameters = attributes.fetch(:parameters, {})
      end

      def to_h
        {
          id: id,
          name: name,
          params: params,
          description: description,
          parameters: parameters
        }.compact
      end
    end
  end
end
