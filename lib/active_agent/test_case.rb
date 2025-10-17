# # frozen_string_literal: true

# require_relative "test_helper"
# require "active_support/test_case"
# require "rails-dom-testing"

# module ActiveAgent
#   class NonInferrableAgentError < ::StandardError
#     def initialize(name)
#       super("Unable to determine the agent to test from #{name}. " \
#         "You'll need to specify it using tests YourAgent in your " \
#         "test case definition")
#     end
#   end

#   class TestCase < ActiveSupport::TestCase
#     module ClearTestDeliveries
#       extend ActiveSupport::Concern

#       included do
#         setup :clear_test_generations
#         teardown :clear_test_generations
#       end

#       private

#       def clear_test_generations
#         if ActiveAgent::Base.generation_method == :test
#           ActiveAgent::Base.generations.clear
#         end
#       end
#     end

#     module Behavior
#       extend ActiveSupport::Concern

#       include ActiveSupport::Testing::ConstantLookup
#       include TestHelper
#       include Rails::Dom::Testing::Assertions::SelectorAssertions
#       include Rails::Dom::Testing::Assertions::DomAssertions

#       included do
#         class_attribute :_agent_class
#         setup :initialize_test_generations
#         setup :set_expected_prompt
#         teardown :restore_test_generations
#         ActiveSupport.run_load_hooks(:active_agent_test_case, self)
#       end

#       module ClassMethods
#         def tests(agent)
#           case agent
#           when String, Symbol
#             self._agent_class = agent.to_s.camelize.constantize
#           when Module
#             self._agent_class = agent
#           else
#             raise NonInferrableAgentError.new(agent)
#           end
#         end

#         def agent_class
#           if agent = _agent_class
#             agent
#           else
#             tests determine_default_agent(name)
#           end
#         end

#         def determine_default_agent(name)
#           agent = determine_constant_from_test_name(name) do |constant|
#             Class === constant && constant < ActiveAgent::Base
#           end
#           raise NonInferrableAgentError.new(name) if agent.nil?
#           agent
#         end
#       end

#       # Reads the fixture file for the given agent.
#       #
#       # This is useful when testing agents by being able to write the body of
#       # an promt inside a fixture. See the testing guide for a concrete example:
#       # https://guides.rubyonrails.org/testing.html#revenge-of-the-fixtures
#       def read_fixture(action)
#         IO.readlines(File.join(Rails.root, "test", "fixtures", self.class.agent_class.name.underscore, action))
#       end

#       private

#       def initialize_test_generations
#         set_generation_method :test
#         @old_process_prompts = ActiveAgent::Base.process_prompts
#         ActiveAgent::Base.process_prompts = true
#         ActiveAgent::Base.generations.clear
#       end

#       def restore_test_generations
#         restore_generation_method
#         ActiveAgent::Base.process_prompts = @old_process_prompts
#       end

#       def set_generation_method(method)
#         @old_generation_method = ActiveAgent::Base.generation_method
#         ActiveAgent::Base.generation_method = method
#       end

#       def restore_generation_method
#         ActiveAgent::Base.generations.clear
#         ActiveAgent::Base.generation_method = @old_generation_method
#       end

#       def set_expected_prompt
#         @expected = ActiveAgent::ActionPrompt::Prompt.new
#         @expected.content_type ["text", "plain", {"charset" => charset}]
#         @expected.mime_version = "1.0"
#       end

#       def charset
#         "UTF-8"
#       end
#     end

#     include Behavior
#   end
# end
