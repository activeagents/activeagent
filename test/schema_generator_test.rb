# frozen_string_literal: true

require "test_helper"
require "active_agent/schema_generator"

# Load the dummy app's models
require_relative "dummy/app/models/application_record"
require_relative "dummy/app/models/user"
require_relative "dummy/app/models/post"
require_relative "dummy/app/models/profile"

class SchemaGeneratorTest < ActiveSupport::TestCase
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
end
