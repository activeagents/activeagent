# frozen_string_literal: true

require "test_helper"
require "active_agent/schema_generator"

# Load the dummy app's models
require_relative "dummy/app/models/application_record"
require_relative "dummy/app/models/user"
require_relative "dummy/app/models/post"
require_relative "dummy/app/models/profile"

class SchemaGeneratorTest < ActiveSupport::TestCase
  include WebMock::API

  # region basic_user_model
  class TestUser
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveModel::Validations
    include ActiveAgent::SchemaGenerator

    attribute :name,   :string
    attribute :email,  :string
    attribute :age,    :integer
    attribute :active, :boolean

    validates :name,  presence: true, length: { minimum: 2, maximum: 100 }
    validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :age,   numericality: { greater_than_or_equal_to: 18 }
  end
  # endregion basic_user_model

  # region blog_post_model
  class TestBlogPost
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveModel::Validations
    include ActiveAgent::SchemaGenerator

    attribute :title,        :string
    attribute :content,      :string
    attribute :published_at, :datetime
    attribute :tags,         :string
    attribute :status,       :string

    validates :title,   presence: true, length: { maximum: 200 }
    validates :content, presence: true
    validates :status,  inclusion: { in: [ "draft", "published", "archived" ] }
  end
  # endregion blog_post_model

  test "generates basic json schema from ActiveModel" do
    # region basic_schema_generation
    json_schema = TestUser.to_json_schema
    # endregion basic_schema_generation

    assert_equal "object", json_schema[:schema][:type]
    assert json_schema[:schema][:properties].key?(:name)
    assert json_schema[:schema][:properties].key?(:email)
    assert json_schema[:schema][:properties].key?(:age)
    assert json_schema[:schema][:properties].key?(:active)

    assert_equal "string", json_schema[:schema][:properties][:name][:type]
    assert_equal "string", json_schema[:schema][:properties][:email][:type]
    assert_equal "integer", json_schema[:schema][:properties][:age][:type]
    assert_equal "boolean", json_schema[:schema][:properties][:active][:type]

    doc_example_output(json_schema)
  end

  test "includes validations in schema" do
    # region schema_with_validations
    json_schema = TestUser.to_json_schema
    # endregion schema_with_validations

    assert json_schema[:schema][:required].include?(:name)
    assert json_schema[:schema][:required].include?(:email)
    assert_equal 2, json_schema[:schema][:properties][:name][:min_length]
    assert_equal 100, json_schema[:schema][:properties][:name][:max_length]
    assert_equal "email", json_schema[:schema][:properties][:email][:format]
    assert_equal 18, json_schema[:schema][:properties][:age][:minimum]

    doc_example_output(json_schema)
  end

  test "generates strict schema for structured output" do
    # region strict_schema_generation
    json_schema = TestBlogPost.to_json_schema(strict: true, name: "blog_post_schema")
    # endregion strict_schema_generation

    assert_equal "blog_post_schema", json_schema[:name]
    assert json_schema[:strict]
    assert_equal "object", json_schema[:schema][:type]
    assert json_schema[:schema][:properties].key?(:title)
    assert json_schema[:schema][:properties].key?(:content)
    # In strict mode, all properties should be required
    assert_equal json_schema[:schema][:properties].keys.sort, json_schema[:schema][:required].sort

    doc_example_output(json_schema)
  end

  test "excludes specified fields" do
    # region schema_with_exclusions
    json_schema = TestBlogPost.to_json_schema(exclude: [ :tags, :published_at ])
    # endregion schema_with_exclusions

    assert json_schema[:schema][:properties].key?(:title)
    assert json_schema[:schema][:properties].key?(:content)
    assert json_schema[:schema][:properties].key?(:status)
    assert_not json_schema[:schema][:properties].key?(:tags)
    assert_not json_schema[:schema][:properties].key?(:published_at)

    doc_example_output(json_schema)
  end

  test "handles enum validations" do
    # region schema_with_enums
    json_schema = TestBlogPost.to_json_schema
    # endregion schema_with_enums

    assert_equal [ "draft", "published", "archived" ], json_schema[:schema][:properties][:status][:enum]

    doc_example_output(json_schema)
  end

  test "agent can use schema generator for structured output" do
    # region agent_using_schema
    # Generate schema from model - returns a Ruby hash
    user_schema = TestUser.to_json_schema(strict: true, name: "user_extraction")

    # In actual usage, the agent would use the hash directly:
    # prompt(
    #   message: "Extract user data",
    #   response_format: {
    #     type: "json_schema",
    #     json_schema: user_schema
    #   }
    # )
    # endregion agent_using_schema

    assert user_schema.is_a?(Hash)
    assert_equal "user_extraction", user_schema[:name]
    assert user_schema[:strict]
    assert_equal "object", user_schema[:schema][:type]

    doc_example_output(user_schema)
  end

  test "generates schema from ActiveRecord model with columns" do
    # region activerecord_schema_generation
    json_schema = User.to_json_schema
    # endregion activerecord_schema_generation

    assert_equal "object", json_schema[:schema][:type]
    assert json_schema[:schema][:properties].key?(:name)
    assert json_schema[:schema][:properties].key?(:email)
    assert json_schema[:schema][:properties].key?(:age)
    assert json_schema[:schema][:properties].key?(:role)
    assert json_schema[:schema][:properties].key?(:active)

    # Check column types are properly mapped
    assert_equal "string", json_schema[:schema][:properties][:name][:type]
    assert_equal "string", json_schema[:schema][:properties][:email][:type]
    assert_equal "integer", json_schema[:schema][:properties][:age][:type]
    assert_equal "boolean", json_schema[:schema][:properties][:active][:type]

    # Check required fields (non-nullable columns)
    assert json_schema[:schema][:required].include?(:name)
    assert json_schema[:schema][:required].include?(:email)

    doc_example_output(json_schema)
  end

  test "generates schema with associations" do
    # region activerecord_schema_with_associations
    json_schema = User.to_json_schema(include_associations: true)
    # endregion activerecord_schema_with_associations

    assert json_schema[:schema][:properties].key?(:posts)
    assert json_schema[:schema][:properties].key?(:profile)
    assert_equal "array", json_schema[:schema][:properties][:posts][:type]
    assert json_schema[:schema][:properties][:posts][:items].key?(:"$ref")

    doc_example_output(json_schema)
  end

  # ActiveModel classes that nest arrays of other ActiveModel classes with
  # has_many.
  class TestAddress
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :street, :string
    attribute :city,   :string

    validates :city, presence: true
  end

  class TestPerson
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :name, :string
    has_many :addresses, class_name: "SchemaGeneratorTest::TestAddress"

    validates :name, presence: true
  end

  class TestEmployee < TestPerson
    has_many :skills, class_name: "SchemaGeneratorTest::TestSkill"
  end

  class TestSkill
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :label, :string
  end

  class TestDiscount
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :promo_code, :string
  end

  class TestLineItem
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :sku, :string
    has_many :discounts, class_name: "SchemaGeneratorTest::TestDiscount"
  end

  class TestOrder
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :order_number, :string
    has_many :line_items, class_name: "SchemaGeneratorTest::TestLineItem"
  end

  class TestCategory
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :title, :string
    has_many :subcategories, class_name: "SchemaGeneratorTest::TestCategory"
  end

  class TestTeam
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :title, :string
    has_many :members, class_name: "SchemaGeneratorTest::TestMember"
  end

  class TestMember
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :name, :string
    has_many :teams, class_name: "SchemaGeneratorTest::TestTeam"
  end

  class TestOffice
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :floor, :integer
  end

  class TestCompany
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :name, :string
    has_many :addresses, class_name: "SchemaGeneratorTest::TestOffice"
  end

  class TestContractor
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    has_many :addresses, class_name: "SchemaGeneratorTest::TestAddress"
    has_many :companies, class_name: "SchemaGeneratorTest::TestCompany"
  end

  class TestRoute
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    attribute :name, :string
    has_many :stops, class_name: "SchemaGeneratorTest::TestAddress"

    validates :name,  length: { minimum: 2, maximum: 50 }
    validates :stops, length: { minimum: 1, maximum: 5 }
  end

  class NestedSchemaAgent < ActiveAgent::Base
    generate_with :mock, model: "mock-model"

    def extract(model = TestOrder)
      prompt(message: "Extract the order", response_format: { type: "json_schema", json_schema: model.to_json_schema(strict: true, name: "order") })
    end
  end

  class ResponsesNestedSchemaAgent < NestedSchemaAgent
    generate_with :openai, model: "gpt-4o-mini", api_version: :responses, access_token: "test-key"
  end

  class ChatNestedSchemaAgent < NestedSchemaAgent
    generate_with :openai, model: "gpt-4o-mini", api_version: :chat, access_token: "test-key"
  end

  ADDRESS_SCHEMA = {
    type: "object",
    properties: { street: { type: "string" }, city: { type: "string" } },
    required: [ :city ],
    additional_properties: false
  }.freeze

  test "has_many nests an array of another ActiveModel's schema under $defs" do
    assert_equal(
      {
        name: "schema_generator_test/test_person",
        schema: {
          type: "object",
          properties: {
            name: { type: "string" },
            addresses: { type: "array", items: { "$ref": "#/$defs/address" } }
          },
          required: [ :name ],
          additional_properties: false,
          "$defs": { address: ADDRESS_SCHEMA }
        }
      },
      TestPerson.to_json_schema
    )
  end

  test "strict mode requires every property, nested ones included" do
    schema = TestPerson.to_json_schema(strict: true, name: "person")

    assert_equal [ :addresses, :name ], schema[:schema][:required]
    assert_equal TestAddress.to_json_schema(strict: true)[:schema], schema[:schema][:"$defs"][:address]
    assert_equal [ :city, :street ], schema[:schema][:"$defs"][:address][:required]
  end

  test "additional_properties reaches the nested schema" do
    schema = TestPerson.to_json_schema(additional_properties: true)

    assert schema[:schema][:"$defs"][:address][:additional_properties]
  end

  test "exclude leaves out the nested array and its definition" do
    schema = TestPerson.to_json_schema(exclude: [ :addresses ])

    assert_equal [ :name ], schema[:schema][:properties].keys
    assert_not schema[:schema].key?(:"$defs")
  end

  test "exclude applies to the declaring class only" do
    schema = TestPerson.to_json_schema(exclude: [ :street ])

    assert_equal [ :street, :city ], schema[:schema][:"$defs"][:address][:properties].keys
  end

  test "a nested class's own definitions move up to the root $defs" do
    schema = TestOrder.to_json_schema[:schema]

    assert_equal [ :lineItem, :discount ], schema[:"$defs"].keys
    assert_equal({ type: "array", items: { "$ref": "#/$defs/lineItem" } }, schema[:properties][:line_items])
    assert_equal({ type: "array", items: { "$ref": "#/$defs/discount" } }, schema[:"$defs"][:lineItem][:properties][:discounts])
    assert_not schema[:"$defs"][:lineItem].key?(:"$defs")
  end

  test "a strict nested schema reaches the provider with its field names and references intact" do
    sent = NestedSchemaAgent.extract.generate_now.raw_request[:response_format][:json_schema][:schema]

    assert_equal(
      {
        type: "object",
        properties: {
          order_number: { type: "string" },
          line_items: { type: "array", items: { "$ref": "#/$defs/lineItem" } }
        },
        required: [ :line_items, :order_number ],
        additionalProperties: false,
        "$defs": {
          lineItem: {
            type: "object",
            properties: { sku: { type: "string" }, discounts: { type: "array", items: { "$ref": "#/$defs/discount" } } },
            required: [ :discounts, :sku ],
            additionalProperties: false
          },
          discount: { type: "object", properties: { promo_code: { type: "string" } }, required: [ :promo_code ], additionalProperties: false }
        }
      },
      sent
    )
  end

  class TestItemList
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveAgent::SchemaGenerator

    has_many :line_items, class_name: "SchemaGeneratorTest::TestLineItem"
  end

  test "a strict schema with only a multiword association requires the property it sends" do
    sent = NestedSchemaAgent.extract(TestItemList).generate_now.raw_request[:response_format][:json_schema][:schema]

    assert_equal [ :line_items ], sent[:properties].keys
    assert_equal sent[:properties].keys, sent[:required]
    assert_equal "#/$defs/lineItem", sent[:properties][:line_items][:items][:"$ref"]
  end

  [ ResponsesNestedSchemaAgent, ChatNestedSchemaAgent ].each do |agent|
    test "#{agent.name.demodulize} sends a consistent strict schema on the wire" do
      chat = agent == ChatNestedSchemaAgent
      endpoint = chat ? "https://api.openai.com/v1/chat/completions" : "https://api.openai.com/v1/responses"
      content = { order_number: "demo", line_items: [ { sku: "SKU-1", discounts: [ { promo_code: "DEMO" } ] } ] }.to_json
      reply = if chat
        { id: "chatcmpl_schema", object: "chat.completion", model: "gpt-4o-mini",
          choices: [ { index: 0, message: { role: "assistant", content: content }, finish_reason: "stop" } ],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }
      else
        { id: "resp_schema", object: "response", status: "completed", model: "gpt-4o-mini",
          output: [ { type: "message", id: "msg_schema", role: "assistant", status: "completed",
                      content: [ { type: "output_text", text: content, annotations: [] } ] } ],
          usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } }
      end
      body = nil
      stub_request(:post, endpoint).to_return do |request|
        body = JSON.parse(request.body)
        { status: 200, headers: { "Content-Type" => "application/json" }, body: reply.to_json }
      end

      agent.extract.generate_now

      format = chat ? body.dig("response_format", "json_schema") : body.dig("text", "format")
      assert_equal "order", format["name"]
      assert_equal true, format["strict"]
      schema = format.fetch("schema")
      assert_equal [ "order_number", "line_items" ], schema.fetch("properties").keys
      [ schema, *schema.fetch("$defs").values ].each do |object|
        assert_equal object.fetch("properties").keys.sort, object.fetch("required").sort
        assert_equal false, object["additionalProperties"]
      end
      assert_equal "#/$defs/lineItem", schema.dig("properties", "line_items", "items", "$ref")
      assert_equal "#/$defs/discount", schema.dig("$defs", "lineItem", "properties", "discounts", "items", "$ref")
      assert_equal [ "promo_code" ], schema.dig("$defs", "discount", "properties").keys
    end
  end

  test "a class that nests itself raises" do
    error = assert_raises(ArgumentError) { TestCategory.to_json_schema }

    assert_match "TestCategory.has_many :subcategories is recursive (SchemaGeneratorTest::TestCategory > SchemaGeneratorTest::TestCategory)", error.message
  end

  test "a class nested back inside its own nested class raises" do
    error = assert_raises(ArgumentError) { TestTeam.to_json_schema }

    assert_match "TestMember.has_many :teams is recursive (SchemaGeneratorTest::TestTeam > SchemaGeneratorTest::TestMember > SchemaGeneratorTest::TestTeam)", error.message
  end

  test "two classes under one definition name raise" do
    error = assert_raises(ArgumentError) { TestContractor.to_json_schema }

    assert_match "address", error.message
  end

  test "has_many on a subclass leaves the parent's declarations alone" do
    assert_equal [ :addresses ], TestPerson.schema_associations.keys
    assert_equal [ :addresses, :skills ], TestEmployee.schema_associations.keys
    assert_equal [ :name, :addresses, :skills ], TestEmployee.to_json_schema[:schema][:properties].keys
    assert_raises(FrozenError) { TestEmployee.schema_associations[:projects] = "Project" }
  end

  test "has_many declares an attribute that defaults to an empty array" do
    person = TestPerson.new(name: "Ada", addresses: [ { city: "London" } ])

    assert_equal [ { city: "London" } ], person.addresses
    assert_equal [], TestPerson.new.addresses
    assert_not_same TestPerson.new.addresses, TestPerson.new.addresses
  end

  test "has_many without ActiveModel::Attributes explains what is missing" do
    model = Class.new do
      include ActiveModel::Model
      include ActiveAgent::SchemaGenerator

      def self.name = "PlainForm"
    end

    error = assert_raises(ArgumentError) { model.has_many :addresses, class_name: "SchemaGeneratorTest::TestAddress" }

    assert_equal "PlainForm.has_many :addresses needs ActiveModel::Attributes to declare the attribute; include it before calling has_many", error.message
    assert_empty model.schema_associations
  end

  test "a length validation limits a nested array's items, not its characters" do
    properties = TestRoute.to_json_schema[:schema][:properties]

    assert_equal({ type: "array", items: { "$ref": "#/$defs/stop" }, min_items: 1, max_items: 5 }, properties[:stops])
    assert_equal({ type: "string", min_length: 2, max_length: 50 }, properties[:name])
  end

  test "ActiveRecord models keep ActiveRecord's has_many" do
    assert_equal ActiveRecord::Associations::ClassMethods, User.method(:has_many).owner
  end
end
