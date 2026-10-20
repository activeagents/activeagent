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

    def custom
      prompt(message: "Extract data", response_format: { type: "json_schema", json_schema: params[:schema] })
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

  test "normalizes schema keywords without renaming fields, definitions or literal data" do
    literal = { order_number: "demo", additional_properties: { min_length: 2 } }
    schema = {
      name: "order", strict: true, schema: {
        type: "object",
        properties: {
          order_number: { type: "string", min_length: 2 },
          line_items: { type: "array", min_items: 1, items: { "$ref": "#/$defs/line_item" } }
        },
        required: [ "order_number", "line_items" ], additional_properties: false,
        "$defs": {
          line_item: {
            type: "object", properties: { item_code: { type: "string", max_length: 20 } },
            required: [ "item_code" ], additional_properties: false
          }
        },
        default: literal, const: literal, enum: [ literal ], examples: [ literal ],
        dependent_required: { order_number: [ "line_items" ] }
      }
    }
    original = schema.deep_dup
    sent = GreetingAgent.with(schema: schema).custom.generate_now.raw_request[:response_format][:json_schema][:schema]

    assert_equal [ :order_number, :line_items ], sent[:properties].keys
    assert_equal [ "order_number", "line_items" ], sent[:required]
    assert_equal 2, sent[:properties][:order_number][:minLength]
    assert_equal 1, sent[:properties][:line_items][:minItems]
    assert_equal "#/$defs/line_item", sent[:properties][:line_items][:items][:"$ref"]
    assert_equal [ :line_item ], sent[:"$defs"].keys
    assert_equal({ type: "object", properties: { item_code: { type: "string", maxLength: 20 } },
                   required: [ "item_code" ], additionalProperties: false }, sent[:"$defs"][:line_item])
    assert_equal false, sent[:additionalProperties]
    %i[default const].each { |keyword| assert_equal literal, sent[keyword] }
    %i[enum examples].each { |keyword| assert_equal [ literal ], sent[keyword] }
    assert_equal({ order_number: [ "line_items" ] }, sent[:dependentRequired])
    assert_equal original, schema
  end

  test "normalizes schemas in named maps, compositions, tuples and conditional branches" do
    object = { type: "object", properties: { field_name: { type: "string", min_length: 1 } },
               required: [ "field_name" ], additional_properties: false }
    schema = { name: "nested", schema: {
      definitions: { named_object: object }, pattern_properties: { "^field_name$" => object },
      dependent_schemas: { field_name: object }, dependencies: { field_name: object, other_name: [ "field_name" ] },
      all_of: [ object ], any_of: [ object ], one_of: [ object ], prefix_items: [ object ], items: [ object, false ],
      additional_items: object, additional_properties: object, contains: object, property_names: { max_length: 20 },
      unevaluated_items: object, unevaluated_properties: object, content_schema: object,
      if: object, then: object, else: object, not: object
    } }
    sent = GreetingAgent.with(schema: schema).custom.generate_now.raw_request[:response_format][:json_schema][:schema]
    expected = { type: "object", properties: { field_name: { type: "string", minLength: 1 } },
                 required: [ "field_name" ], additionalProperties: false }

    assert_equal({ named_object: expected }, sent[:definitions])
    assert_equal({ "^field_name$": expected }, sent[:patternProperties])
    assert_equal({ field_name: expected }, sent[:dependentSchemas])
    assert_equal({ field_name: expected, other_name: [ "field_name" ] }, sent[:dependencies])
    %i[allOf anyOf oneOf prefixItems].each { |keyword| assert_equal [ expected ], sent[keyword] }
    assert_equal [ expected, false ], sent[:items]
    %i[additionalItems additionalProperties contains unevaluatedItems unevaluatedProperties contentSchema if then else not].each do |keyword|
      assert_equal expected, sent[keyword]
    end
    assert_equal({ maxLength: 20 }, sent[:propertyNames])
  end
end
