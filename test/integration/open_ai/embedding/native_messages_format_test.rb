# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module OpenAI
    module Embedding
      class NativeMessagesFormatTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          embed_with :openai, model: "text-embedding-3-small"

          SINGLE_INPUT = {
            "model": "text-embedding-3-small",
            "input": "Your text string goes here"
          }
          def single_input
            embed(
              input: "Your text string goes here"
            )
          end

          MULTI_INPUT = {
            "model": "text-embedding-3-small",
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
        end

        ################################################################################
        # This automatically runs all the tests for these the test actions
        ################################################################################
        [
          :single_input,
          :multi_input
        ].each do |action_name|
          test_request_builder(TestAgent, action_name, :embed_now)
        end
      end
    end
  end
end
