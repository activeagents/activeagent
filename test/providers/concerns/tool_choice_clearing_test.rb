# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/concerns/tool_choice_clearing"

module ActiveAgent
  module Providers
    class ToolChoiceClearingTest < ActiveSupport::TestCase
      # Mock request object with tool_choice attribute
      MockRequest = Struct.new(:tool_choice, keyword_init: true)

      # Mock provider that includes the concern
      class MockProvider
        include ActiveAgent::Providers::ToolChoiceClearing

        attr_accessor :request, :used_function_names, :forces_required, :forces_specific

        def initialize(tool_choice:, used_function_names: [], forces_required: false, forces_specific: [false, nil])
          @request = MockRequest.new(tool_choice: tool_choice)
          @used_function_names = used_function_names
          @forces_required = forces_required
          @forces_specific = forces_specific
        end

        private

        def extract_used_function_names
          @used_function_names
        end

        def tool_choice_forces_required?
          @forces_required
        end

        def tool_choice_forces_specific?
          @forces_specific
        end
      end

      test "does nothing when tool_choice is nil" do
        provider = MockProvider.new(tool_choice: nil)

        provider.prepare_prompt_request_tools

        assert_nil provider.request.tool_choice
      end

      test "does nothing when no tools were used and required is set" do
        provider = MockProvider.new(
          tool_choice: "required",
          forces_required: true,
          used_function_names: []
        )

        provider.prepare_prompt_request_tools

        assert_equal "required", provider.request.tool_choice
      end

      test "clears tool_choice when required and tools were used" do
        provider = MockProvider.new(
          tool_choice: "required",
          forces_required: true,
          used_function_names: ["get_weather"]
        )

        provider.prepare_prompt_request_tools

        assert_nil provider.request.tool_choice
      end

      test "clears tool_choice when specific tool was forced and that tool was used" do
        provider = MockProvider.new(
          tool_choice: { type: "function", function: { name: "search" } },
          forces_specific: [true, "search"],
          used_function_names: ["search"]
        )

        provider.prepare_prompt_request_tools

        assert_nil provider.request.tool_choice
      end

      test "does not clear tool_choice when specific tool was forced but different tool was used" do
        original_choice = { type: "function", function: { name: "search" } }
        provider = MockProvider.new(
          tool_choice: original_choice,
          forces_specific: [true, "search"],
          used_function_names: ["calculate"]
        )

        provider.prepare_prompt_request_tools

        assert_equal original_choice, provider.request.tool_choice
      end

      test "does not clear tool_choice when specific tool was forced but no tools were used" do
        original_choice = { type: "function", function: { name: "search" } }
        provider = MockProvider.new(
          tool_choice: original_choice,
          forces_specific: [true, "search"],
          used_function_names: []
        )

        provider.prepare_prompt_request_tools

        assert_equal original_choice, provider.request.tool_choice
      end

      test "does not clear when tool_choice is auto and tools were used" do
        provider = MockProvider.new(
          tool_choice: "auto",
          forces_required: false,
          forces_specific: [false, nil],
          used_function_names: ["get_weather"]
        )

        provider.prepare_prompt_request_tools

        assert_equal "auto", provider.request.tool_choice
      end

      # Verify the abstract methods raise NotImplementedError
      class BareProvider
        include ActiveAgent::Providers::ToolChoiceClearing

        attr_accessor :request

        def initialize
          @request = MockRequest.new(tool_choice: "required")
        end
      end

      test "extract_used_function_names raises NotImplementedError" do
        provider = BareProvider.new

        assert_raises(NotImplementedError) do
          provider.prepare_prompt_request_tools
        end
      end
    end
  end
end
