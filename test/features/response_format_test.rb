require "test_helper"

# How an agent's prompt hands its response_format to the provider, before any
# provider-specific conversion.
class ResponseFormatTest < ActiveSupport::TestCase
  GREETING_SCHEMA = {
    type: "object",
    properties: { text: { type: "string" } },
    required: [ "text" ],
    additionalProperties: false
  }.freeze

  class GreetingAgent < ApplicationAgent
    generate_with :mock, model: "mock-model"

    def nested
      prompt(message: "Say hello",
             response_format: { type: "json_schema", json_schema: { name: "greeting", strict: true, schema: GREETING_SCHEMA } })
    end

    # No greeting.json view exists: the schema has to come from the format.
    def flat
      prompt(message: "Say hello",
             response_format: { type: "json_schema", name: "greeting", strict: true, schema: GREETING_SCHEMA })
    end

    def flat_schema_only
      prompt(message: "Say hello", response_format: { type: "json_schema", schema: GREETING_SCHEMA })
    end
  end

  test "hands a flat json_schema to the provider as the nested shape" do
    nested = GreetingAgent.nested.generate_now.raw_request[:response_format]
    flat = GreetingAgent.flat.generate_now.raw_request[:response_format]

    assert_equal nested, flat
    assert_equal({ type: "json_schema", json_schema: { name: "greeting", strict: true, schema: GREETING_SCHEMA } }, flat)
  end

  test "hands over only the fields a flat json_schema gives" do
    response_format = GreetingAgent.flat_schema_only.generate_now.raw_request[:response_format]

    assert_equal({ type: "json_schema", json_schema: { schema: GREETING_SCHEMA } }, response_format)
  end
end
