# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module Ollama
    module Embedding
      class CommonFormatTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          embed_with :ollama, model: "all-minilm"

          TEMPLATES_DEFAULT = {
            "model": "all-minilm",
            "input": "The quick brown fox jumps over the lazy dog"
          }
          def templates_default
            embed
          end

          TEMPLATES_WITH_LOCALS = {
            "model": "all-minilm",
            "input": "Learning Ruby programming is fun and rewarding"
          }
          def templates_with_locals
            embed(locals: { topic: "Ruby", subject: "programming" })
          end

          INPUT_BARE = {
            "model": "all-minilm",
            "input": "Your text string goes here"
          }
          def input_bare
            embed("Your text string goes here")
          end

          INPUT_ARRAY = {
            "model": "all-minilm",
            "input": [
              "First text string goes here",
              "Second text string goes here"
            ]
          }
          def input_array
            embed([
              "First text string goes here",
              "Second text string goes here"
            ])
          end
        end

        ################################################################################
        # This automatically runs all the tests for these the test actions
        ################################################################################
        [
          # Template tests
          :templates_default,
          :templates_with_locals,

          # Input tests
          :input_bare,
          :input_array
        ].each do |action_name|
          test_request_builder(TestAgent, action_name, :embed_now, TestAgent.const_get(action_name.to_s.upcase, true))
        end
      end
    end
  end
end
