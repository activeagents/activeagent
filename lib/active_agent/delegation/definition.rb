# frozen_string_literal: true

module ActiveAgent
  module Delegation
    # A sub-agent bound into a calling agent as a tool.
    #
    # Pairs the sub-agent's {Contract} — what it accepts and returns — with the
    # decisions that belong to the caller: what to call it, what it may spend,
    # and which backend serves it.
    class Definition
      # @return [Class] the sub-agent class
      attr_reader :agent_class
      # @return [Contract]
      attr_reader :contract
      # @return [Symbol] the tool name exposed to the calling model
      attr_reader :tool_name
      # @return [String]
      attr_reader :description
      # @return [Backend]
      attr_reader :backend
      # @return [Budget]
      attr_reader :budget
      # @return [Hash, Symbol, Proc, nil] params forwarded to the sub-agent
      attr_reader :params

      # @param agent_class [Class]
      # @param contract [Contract]
      # @param tool_name [Symbol, String, nil] defaults to the contract's action
      # @param description [String, nil] overrides the contract's description
      # @param backend [Backend, Symbol, Hash, nil]
      # @param budget [Budget, Hash, nil] merged over the contract's default budget
      # @param params [Hash, Symbol, Proc, nil]
      def initialize(agent_class:, contract:, tool_name: nil, description: nil, backend: nil, budget: nil, params: nil)
        @agent_class = agent_class
        @contract    = contract
        @tool_name   = (tool_name || contract.action).to_sym
        @description = description.presence || contract.description
        @backend     = Backend.build(backend)
        @budget      = contract.budget.merge(Budget.build(budget))
        @params      = params
      end

      # @return [Symbol] the sub-agent action invoked
      def action = contract.action

      # @return [Schema] declared inputs
      def schema = contract.schema

      # @return [Schema, nil] declared outputs
      def returns = contract.returns

      # @return [Boolean]
      def structured? = contract.structured?

      # @return [Symbol]
      def on_invalid = contract.on_invalid

      # The class a call actually instantiates, after any backend swap.
      #
      # @return [Class]
      def resolved_agent_class
        backend.agent_class_for(agent_class)
      end

      # Tool definition in ActiveAgent's common tools format.
      #
      # This is what the calling model sees — the whole point of declaring a
      # schema rather than describing the sub-agent in prose.
      #
      # @return [Hash]
      def to_tool
        {
          name: tool_name.to_s,
          description: description,
          parameters: schema.to_json_schema
        }
      end

      # Returns a copy with call-site overrides applied.
      #
      # @return [Definition]
      def with(tool_name: nil, description: nil, backend: nil, budget: nil, params: nil)
        self.class.new(
          agent_class: agent_class,
          contract: contract,
          tool_name: tool_name || self.tool_name,
          description: description || self.description,
          backend: backend || self.backend,
          budget: budget ? self.budget.merge(Budget.build(budget)) : self.budget,
          params: params || self.params
        )
      end
    end
  end
end
