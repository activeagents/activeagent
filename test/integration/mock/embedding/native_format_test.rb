# frozen_string_literal: true

require_relative "../test_helper"

module Integration
  module Mock
    module Embedding
      class NativeFormatTest < ActiveSupport::TestCase
        include Integration::Mock::TestHelper

        class TestAgent < ActiveAgent::Base
          embed_with :mock

          SINGLE_INPUT = {
            "model": "mock-embedding-model",
            "input": "Your text string goes here"
          }
          def single_input
            embed(
              input: "Your text string goes here"
            )
          end

          MULTI_INPUT = {
            "model": "mock-embedding-model",
            "input": [
              "First text string goes here",
              "Second text string goes here"
            ]
          }
          def multi_input
            embed(
              input: [
                "First text string goes here",
                "Second text string goes here"
              ]
            )
          end

          WITH_DIMENSIONS = {
            "model": "mock-embedding-model",
            "input": "Test with custom dimensions",
            "dimensions": 768
          }
          def with_dimensions
            embed(
              input: "Test with custom dimensions",
              dimensions: 768
            )
          end
        end

        ################################################################################
        # This automatically runs all the tests for these the test actions
        ################################################################################
        [
          :single_input,
          :multi_input,
          :with_dimensions
        ].each do |action_name|
          test_request_builder(TestAgent, action_name, :embed_now, TestAgent.const_get(action_name.to_s.upcase, true))
        end
      end
    end
  end
end
