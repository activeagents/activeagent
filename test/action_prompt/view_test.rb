require "test_helper"
require "ostruct"

module ActiveAgent
  module ActionPrompt
    class ViewTest < ActiveSupport::TestCase
      class TestAgent < ApplicationAgent
        def dummy_action
          prompt
        end

        # Expose the private method for testing
        def test_prompt_view_instructions(param)
          prompt_view_instructions(param)
        end

        # Mock methods needed for template rendering
        def lookup_context
          @lookup_context ||= OpenStruct.new.tap do |ctx|
            ctx.define_singleton_method(:exists?) do |template_name, agent_name, *args|
              %w[instructions custom_template empty_template].include?(template_name.to_s) ||
                template_name == :symbol_template
            end

            ctx.define_singleton_method(:find_template) do |template_name, agent_name, *args|
              OpenStruct.new(virtual_path: "#{agent_name}/#{template_name}")
            end
          end
        end

        def agent_name
          "test_agent"
        end

        def render_to_string(template:, locals:, layout:)
          case template
          when "test_agent/instructions"
            "Default instructions from template"
          when "test_agent/custom_template"
            "Custom template content with locals: #{locals.inspect}"
          when "test_agent/symbol_template"
            "Symbol template content"
          when "test_agent/empty_template"
            ""
          else
            ""
          end
        end
      end

      setup do
        @agent = TestAgent.new
      end

      test "prompt_view_instructions with String returns the string directly" do
        result = @agent.test_prompt_view_instructions("Direct instructions")
        assert_equal "Direct instructions", result
      end

      test "prompt_view_instructions with Symbol renders template" do
        result = @agent.test_prompt_view_instructions(:symbol_template)
        assert_equal "Symbol template content", result
      end

      test "prompt_view_instructions with Array of strings returns the array" do
        instructions = [ "Step 1", "Step 2", "Step 3" ]
        result = @agent.test_prompt_view_instructions(instructions)
        assert_equal instructions, result
      end

      test "prompt_view_instructions with Array containing non-strings raises ArgumentError" do
        instructions = [ "Step 1", 123, "Step 3" ]
        error = assert_raises(ArgumentError) do
          @agent.test_prompt_view_instructions(instructions)
        end
        assert_equal "Instructions array must contain only strings", error.message
      end

      test "prompt_view_instructions with Hash containing template key renders template" do
        instructions = { template: "custom_template", locals: { name: "Test" } }
        result = @agent.test_prompt_view_instructions(instructions)
        assert_equal 'Custom template content with locals: {name: "Test"}', result
      end

      test "prompt_view_instructions with Hash missing template key raises ArgumentError" do
        instructions = { locals: { name: "Test" } }
        error = assert_raises(ArgumentError) do
          @agent.test_prompt_view_instructions(instructions)
        end
        assert_equal "Expected `:template` key in instructions hash", error.message
      end

      test "prompt_view_instructions with nil renders default instructions template" do
        result = @agent.test_prompt_view_instructions(nil)
        assert_equal "Default instructions from template", result
      end

      test "prompt_view_instructions with unsupported type raises ArgumentError" do
        error = assert_raises(ArgumentError) do
          @agent.test_prompt_view_instructions(123)
        end
        assert_equal "Instructions must be Hash, String, Symbol or nil", error.message
      end

      test "prompt_view_instructions with Hash and nil locals" do
        instructions = { template: "custom_template", locals: nil }
        result = @agent.test_prompt_view_instructions(instructions)
        assert_equal "Custom template content with locals: nil", result
      end

      test "prompt_view_instructions with empty Hash raises ArgumentError" do
        error = assert_raises(ArgumentError) do
          @agent.test_prompt_view_instructions({})
        end
        assert_equal "Expected `:template` key in instructions hash", error.message
      end

      test "prompt_view_instructions with empty Array returns nil" do
        result = @agent.test_prompt_view_instructions([])
        assert_nil result
      end

      test "prompt_view_instructions with empty String returns nil" do
        result = @agent.test_prompt_view_instructions("")
        assert_nil result
      end

      test "prompt_view_instructions with template that renders empty string returns nil" do
        instructions = { template: "empty_template" }
        result = @agent.test_prompt_view_instructions(instructions)
        assert_nil result
      end

      test "prompt_view_instructions with symbol template that renders empty string returns nil" do
        result = @agent.test_prompt_view_instructions(:empty_template)
        assert_nil result
      end
    end
  end
end
