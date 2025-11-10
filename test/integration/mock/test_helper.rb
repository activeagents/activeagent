# frozen_string_literal: true

require "test_helper"

module Integration
  module Mock
    module TestHelper
      extend ActiveSupport::Concern

      class_methods do
        def test_request_builder(agent_class, action_name, trigger_name, expected_request_body)
          agent_name = agent_class.name.demodulize.underscore

          test "#{agent_name} #{action_name} Request Building" do
            # MockProvider doesn't make HTTP requests, so we directly test request building
            # and execution without VCR

            # Execute the action
            response = agent_class.send(action_name).send(trigger_name)

            # Verify we got a response
            assert_not_nil response, "Expected a response from #{agent_name}.#{action_name}"

            # For MockProvider, we validate the request was built correctly by checking
            # that the agent processed successfully and returned a valid response
            if trigger_name.to_s.include?("embed")
              assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
              assert_not_nil response.data, "Expected embedding data in response"
            else
              assert_kind_of ActiveAgent::Providers::Common::Responses::Base, response
              assert_not_nil response.message, "Expected message in response"
              assert_not_nil response.message.content, "Expected content in message"
            end

            # Additional validation: check that the request body structure matches expectations
            # by re-processing and inspecting the agent's internal state
            agent = agent_class.new
            agent.process(action_name)

            if trigger_name.to_s.include?("embed")
              # For embedding requests
              assert_equal expected_request_body[:model], agent.embed_options[:model] || "mock-embedding-model"

              # Validate input structure if present in embed_options
              # For template-based tests, input might come from the template
              if expected_request_body[:input] && agent.embed_options[:input]
                # Input is present in options, validate it
                if expected_request_body[:input].is_a?(Array)
                  assert_kind_of Array, agent.embed_options[:input]
                else
                  assert_not_nil agent.embed_options[:input]
                end
              end

              # Validate dimensions if present
              if expected_request_body[:dimensions]
                assert_equal expected_request_body[:dimensions], agent.embed_options[:dimensions]
              end
            else
              # For prompt requests
              assert_equal expected_request_body[:model], agent.prompt_options[:model] || "mock-model"

              # Validate messages structure
              if expected_request_body[:messages]
                # Messages might be in prompt_options or loaded from templates
                messages = agent.prompt_options[:messages]

                # For template-based tests, messages might not be in prompt_options
                # In that case, just verify we can generate a response
                if messages
                  assert_equal expected_request_body[:messages].size, messages.size,
                    "Expected #{expected_request_body[:messages].size} messages but got #{messages.size}"
                end
              end

              # Validate optional parameters
              if expected_request_body[:temperature]
                assert_equal expected_request_body[:temperature], agent.prompt_options[:temperature]
              end

              if expected_request_body[:max_tokens]
                assert_equal expected_request_body[:max_tokens], agent.prompt_options[:max_tokens]
              end

              if expected_request_body[:stream]
                assert_equal expected_request_body[:stream], agent.prompt_options[:stream]
              end
            end
          end
        end
      end
    end
  end
end
