# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module Ollama
    module Embedding
      class NativeFormatTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          embed_with :ollama, model: "all-minilm"

          # Single input with default model (all-minilm)
          SINGLE_INPUT_DEFAULT_MODEL = {
            "model": "all-minilm",
            "input": "Your text string goes here"
          }
          def single_input_default_model
            embed(
              input: "Your text string goes here"
            )
          end

          # Multi input with default model (all-minilm)
          MULTI_INPUT_DEFAULT_MODEL = {
            "model": "all-minilm",
            "input": [
              "First text string goes here",
              "Second text string goes here"
            ]
          }
          def multi_input_default_model
            embed(
              input: [
                "First text string goes here",
                "Second text string goes here"
              ]
            )
          end

          # Single input with custom model (nomic-embed-text)
          SINGLE_INPUT_CUSTOM_MODEL = {
            "model": "nomic-embed-text",
            "input": "Your text string goes here"
          }
          def single_input_custom_model
            embed(
              model: "nomic-embed-text",
              input: "Your text string goes here"
            )
          end

          # Multi input with custom model (nomic-embed-text)
          MULTI_INPUT_CUSTOM_MODEL = {
            "model": "nomic-embed-text",
            "input": [
              "First text string goes here",
              "Second text string goes here"
            ]
          }
          def multi_input_custom_model
            embed(
              model: "nomic-embed-text",
              input: [
                "First text string goes here",
                "Second text string goes here"
              ]
            )
          end
        end

        ################################################################################
        # This automatically runs all the tests for these the test actions
        ################################################################################
        [
          :single_input_default_model,
          :multi_input_default_model,
          :single_input_custom_model,
          :multi_input_custom_model
        ].each do |action_name|
          test_request_builder(TestAgent, action_name, :embed_now, TestAgent.const_get(action_name.to_s.upcase, true))
        end
      end
    end
  end
end
