require "test_helper"

module Docs
  module Agents
    module Instructions
      module DefaultTemplate
        # region default_template
        class Agent < ApplicationAgent
          generate_with :mock
          # endregion default_template

          def action
            prompt
          end
        end

        class Tests < ActiveSupport::TestCase
          test "uses default instructions template when none specified" do
            prompt = Agent.with(message: "Hello").action

            assert_equal "You are a helpful assistant.", prompt.instructions
          end
        end
      end

      module InlineString
        # region inline_string
        class Agent < ApplicationAgent
          generate_with :mock, instructions: "You are a helpful assistant that responds in a friendly manner."
          # endregion inline_string

          def action
            prompt
          end
        end

        class Tests < ActiveSupport::TestCase
          test "uses inline string instructions" do
            prompt = Agent.with(message: "Hello").action

            assert_equal "You are a helpful assistant that responds in a friendly manner.", prompt.instructions
          end
        end
      end

      module CustomTemplate
        # region custom_template
        class Agent < ApplicationAgent
          generate_with :mock, instructions: {
            template: :custom_instructions, locals: { from: "English", to: "French" }
          }
          # endregion custom_template

          def action
            prompt
          end
        end

        class Tests < ActiveSupport::TestCase
          test "uses custom template with locals" do
            prompt = Agent.with(message: "Hello world").action

            assert_equal "Translate text from English to French.", prompt.instructions
          end
        end
      end

      module DynamicMethod
        # region dynamic_method
        class Agent < ApplicationAgent
          generate_with :mock, instructions: :dynamic_instructions_method

          private

          def dynamic_instructions_method
            if params[:user]&.admin?
              "You have access to admin tools. Use them responsibly."
            else
              "You are a helpful assistant with standard capabilities."
            end
          end
          # endregion dynamic_method

          public

          def action
            prompt
          end
        end


        class Tests < ActiveSupport::TestCase
          test "uses dynamic method for admin user" do
            user = Struct.new(:admin?).new(true)
            prompt = Agent.with(message: "Hello", user: user).action

            assert_equal "You have access to admin tools. Use them responsibly.", prompt.instructions
          end

          test "uses dynamic method for standard user" do
            user = Struct.new(:admin?).new(false)
            prompt = Agent.with(message: "Hello", user: user).action

            assert_equal "You are a helpful assistant with standard capabilities.", prompt.instructions
          end

          test "uses dynamic method when user is nil" do
            prompt = Agent.with(message: "Hello").action

            assert_equal "You are a helpful assistant with standard capabilities.", prompt.instructions
          end
        end
      end

      module MulitArray
        # region multi_array
        class Agent < ApplicationAgent
          generate_with :mock, instructions: [
            "You are a helpful assistant.",
            "Always respond in a concise manner.",
            "Use bullet points where appropriate."
          ]
          # endregion multi_array

          def action
            prompt
          end
        end

        class Tests < ActiveSupport::TestCase
          test "uses array of instructions joined together" do
            prompt = Agent.with(message: "Hello").action

            expected_instructions = [ "You are a helpful assistant.", "Always respond in a concise manner.", "Use bullet points where appropriate." ]
            assert_equal expected_instructions, prompt.instructions
          end
        end
      end

      module Precedence
        # region precedence
        class Agent < ApplicationAgent
          generate_with :mock, instructions: "Global instructions"

          def action_with_override
            # Priority 1: Highest - overrides global
            prompt(instructions: "Override for this action")
          end

          def action_with_global
            # Uses Priority 2: Global instructions
            prompt
          end
          # endregion precedence
        end

        class Tests < ActiveSupport::TestCase
          test "action-level instructions override global instructions" do
            prompt = Agent.with(message: "Hello").action_with_override

            assert_equal "Override for this action", prompt.instructions
          end

          test "uses global instructions when action doesn't override" do
            prompt = Agent.with(message: "Hello").action_with_global

            assert_equal "Global instructions", prompt.instructions
          end
        end
      end

      module TemplateBindingAt
        class Agent < ApplicationAgent
          generate_with :mock

          # region template_binding_at
          def action
            @name = params[:name]
            prompt
          end
          # endregion template_binding_at
        end

        class Tests < ActiveSupport::TestCase
          test "uses default instructions template when none specified" do
            prompt = Agent.with(name: "Andor").action

            assert_equal "You are a helpful assistant named Andor", prompt.instructions
          end
        end
      end

      module TemplateBindingLocals
        class Agent < ApplicationAgent
          generate_with :mock

          def action
            prompt
          end
        end

        class Tests < ActiveSupport::TestCase
          test "uses default instructions template when none specified" do
            # region template_binding_locals
            prompt = Agent.with(instructions: { locals: { name: "Andor" } }).action
            # endregion template_binding_locals

            assert_equal "You are a helpful assistant named Andor", prompt.instructions
          end
        end
      end

      module TemplateBindingParams
        class Agent < ApplicationAgent
          generate_with :mock

          def action
            prompt
          end
        end

        class Tests < ActiveSupport::TestCase
          test "uses default instructions template when none specified" do
            # region template_binding_params
            prompt = Agent.with(name: "Andor").action
            # endregion template_binding_params

            assert_equal "You are a helpful assistant named Andor", prompt.instructions
          end
        end
      end

      module TemplateBindingController
        class Agent < ApplicationAgent
          generate_with :mock

          def action
            prompt
          end

          def tool_action
            {}
          end
        end

        class Tests < ActiveSupport::TestCase
          test "uses default instructions template when none specified" do
            prompt = Agent.with(name: "Andor").action

            assert_equal "- tool_action", prompt.instructions
          end
        end
      end
    end
  end
end
