# frozen_string_literal: true

require "test_helper"

module Integration
  module OpenAI
    module TestHelper
      extend ActiveSupport::Concern

      included do
        include WebMock::API
      end

      class_methods do
        def test_request_builder(agent, action_name)
          test "#{action_name} Request Building" do
            cassette_name = [ self.class.name.underscore, action_name ].join("/")
            request_body  = agent.const_get(action_name.to_s.upcase, false)

            # Run Once to Record Response & Smoke Test
            VCR.use_cassette(cassette_name) do
              agent.send(action_name).generate_now
            end

            # Run Again to Validate that the Request is well formed and not mutated
            cassette_file = YAML.load_file("test/fixtures/vcr_cassettes/#{cassette_name}.yml")
            request_method = cassette_file.dig("http_interactions", 0, "request", "method").to_sym
            request_uri    = cassette_file.dig("http_interactions", 0, "request", "uri")
            response_body  = cassette_file.dig("http_interactions", 0, "response", "body", "string")

            stub_request(request_method, request_uri).to_return(body: response_body)
            agent.send(action_name).generate_now
            assert_requested request_method, request_uri, body: request_body, times: 2
          end
        end
      end
    end
  end
end
