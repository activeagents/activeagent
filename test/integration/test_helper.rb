# frozen_string_literal: true

require "test_helper"

module Integration
  module TestHelper
    extend ActiveSupport::Concern

    included do
      include WebMock::API
    end

    class_methods do
      def test_request_builder(agent_class, action_name, trigger_name)
        agent_name = agent_class.name.demodulize.underscore

        test "#{agent_name} #{action_name} Request Building" do
          cassette_name = [ self.class.name.underscore, "#{agent_name}_#{action_name}" ].join("/")
          request_body  = agent_class.const_get(action_name.to_s.upcase, true)

          # Run Once to Record Response & Smoke Test
          VCR.use_cassette(cassette_name) do
            agent_class.send(action_name).send(trigger_name)
          end

          # Validate that the 1st recorded request matches our expectations
          cassette_file = YAML.load_file("test/fixtures/vcr_cassettes/#{cassette_name}.yml")
          saved_request_body = JSON.parse(cassette_file.dig("http_interactions", 0, "request", "body", "string"), symbolize_names: true)
          assert_equal saved_request_body, request_body

          # Run Again to Validate that the Request cycle is well formed and not mutated since recording it last
          cassette_file.dig("http_interactions").each do |interaction|
            request_method   = interaction.dig("request", "method").to_sym
            request_uri      = interaction.dig("request", "uri")
            stub_request(request_method, request_uri).to_return(
              body:    interaction.dig("response", "body", "string"),
              status:  interaction.dig("response", "status", "code"),
              headers: interaction.dig("response", "headers")
            )
          end

          agent_class.send(action_name).send(trigger_name)

          cassette_file.dig("http_interactions").each do |interaction|
            request_method = interaction.dig("request", "method").to_sym
            request_uri    = interaction.dig("request", "uri")

            assert_requested request_method, request_uri, body: request_body, times: 2
          end
        end
      end
    end
  end
end
