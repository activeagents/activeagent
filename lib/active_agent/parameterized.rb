# frozen_string_literal: true

module ActiveAgent
  module Parameterized
    extend ActiveSupport::Concern

    included do
      attr_writer :params

      def params
        @params ||= {}
      end
    end

    module ClassMethods
      def with(params)
        ActiveAgent::Parameterized::Agent.new(self, params)
      end
    end

    class Agent
      def initialize(agent, params)
        @agent = agent
        @params = params
      end

      def method_missing(method_name, ...)
        if @agent.public_instance_methods.include?(method_name)
          ActiveAgent::Parameterized::Generation.new(@agent, method_name, @params, ...)
        else
          super
        end
      end

      def respond_to_missing?(method, include_all = false)
        @agent.respond_to?(method, include_all)
      end
    end

    class Generation < ActiveAgent::Generation
      def initialize(agent_class, action, params, ...)
        super(agent_class, action, ...)
        @params = params
      end

      private

      def processed_agent
        @processed_agent ||= @agent_class.new.tap do |agent|
          agent.params = @params
          agent.process @action, *@args
        end
      end

      def enqueue_generation(generation_method, options = {})
        if processed?
          super
        else
          @agent_class.generation_job.set(options).perform_later(
            @agent_class.name, @action.to_s, params: @params, args: @args
          )
        end
      end
    end
  end
end
