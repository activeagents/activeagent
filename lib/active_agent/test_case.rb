# frozen_string_literal: true

require "active_support/test_case"
require "rails-dom-testing"

module ActiveAgent
  class NonInferrableAgentError < ::StandardError
    def initialize(name)
      super("Unable to determine the agent to test from #{name}. " \
        "You'll need to specify it using tests YourAgent in your " \
        "test case definition")
    end
  end

  class TestCase < ActiveSupport::TestCase
    module ClearTestDeliveries
      extend ActiveSupport::Concern

      included do
        setup :clear_test_deliveries
        teardown :clear_test_deliveries
      end

      private

      def clear_test_deliveries
        if ActiveAgent::Base.delivery_method == :test
          ActiveAgent::Base.deliveries.clear
        end
      end
    end

    module Behavior
      extend ActiveSupport::Concern

      include ActiveSupport::Testing::ConstantLookup
      include TestHelper
      include Rails::Dom::Testing::Assertions::SelectorAssertions
      include Rails::Dom::Testing::Assertions::DomAssertions

      included do
        class_attribute :_agent_class
        setup :initialize_test_deliveries
        setup :set_expected_prompt
        teardown :restore_test_deliveries
        ActiveSupport.run_load_hooks(:active_agent_test_case, self)
      end

      module ClassMethods
        def tests(agent)
          case agent
          when String, Symbol
            self._agent_class = agent.to_s.camelize.constantize
          when Module
            self._agent_class = agent
          else
            raise NonInferrableAgentError.new(agent)
          end
        end

        def agent_class
          if agent = _agent_class
            agent
          else
            tests determine_default_agent(name)
          end
        end

        def determine_default_agent(name)
          agent = determine_constant_from_test_name(name) do |constant|
            Class === constant && constant < ActiveAgent::Base
          end
          raise NonInferrableAgentError.new(name) if agent.nil?
          agent
        end
      end

      # Reads the fixture file for the given agent.
      #
      # This is useful when testing agents by being able to write the body of
      # an promt inside a fixture. See the testing guide for a concrete example:
      # https://guides.rubyonrails.org/testing.html#revenge-of-the-fixtures
      def read_fixture(action)
        IO.readlines(File.join(Rails.root, "test", "fixtures", self.class.agent_class.name.underscore, action))
      end

      private

      def initialize_test_deliveries
        set_delivery_method :test
        @old_perform_deliveries = ActiveAgent::Base.perform_deliveries
        ActiveAgent::Base.perform_deliveries = true
        ActiveAgent::Base.deliveries.clear
      end

      def restore_test_deliveries
        restore_delivery_method
        ActiveAgent::Base.perform_deliveries = @old_perform_deliveries
      end

      def set_delivery_method(method)
        @old_delivery_method = ActiveAgent::Base.delivery_method
        ActiveAgent::Base.delivery_method = method
      end

      def restore_delivery_method
        ActiveAgent::Base.deliveries.clear
        ActiveAgent::Base.delivery_method = @old_delivery_method
      end

      def set_expected_prompt
        @expected = ActiveAgent::ActionPrompt::Prompt.new
        @expected.content_type ["text", "plain", {"charset" => charset}]
        @expected.mime_version = "1.0"
      end

      def charset
        "UTF-8"
      end
    end

    include Behavior
  end
end
