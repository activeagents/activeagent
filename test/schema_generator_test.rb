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

    attribute :name, :string
    attribute :email, :string
    attribute :age, :integer
    attribute :active, :boolean

    validates :name, presence: true, length: { minimum: 2, maximum: 100 }
    validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :age, numericality: { greater_than_or_equal_to: 18 }
  end
  # endregion basic_user_model

  # region blog_post_model
  class TestBlogPost
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveModel::Validations
    include ActiveAgent::SchemaGenerator

    attribute :title, :string
    attribute :content, :string
    attribute :published_at, :datetime
    attribute :tags, :string
    attribute :status, :string

    validates :title, presence: true, length: { maximum: 200 }
    validates :content, presence: true
    validates :status, inclusion: { in: [ "draft", "published", "archived" ] }
  end
  # endregion blog_post_model

  test "generates basic json schema from ActiveModel" do
    # region basic_schema_generation
    schema = TestUser.to_json_schema
    # endregion basic_schema_generation

    assert_equal "object", schema[:type]
    assert schema[:properties].key?("name")
    assert schema[:properties].key?("email")
    assert schema[:properties].key?("age")
    assert schema[:properties].key?("active")

    assert_equal "string", schema[:properties]["name"][:type]
    assert_equal "string", schema[:properties]["email"][:type]
    assert_equal "integer", schema[:properties]["age"][:type]
    assert_equal "boolean", schema[:properties]["active"][:type]

    doc_example_output(schema)
  end

  test "includes validations in schema" do
    # region schema_with_validations
    schema = TestUser.to_json_schema
    # endregion schema_with_validations

    assert schema[:required].include?("name")
    assert schema[:required].include?("email")
    assert_equal 2, schema[:properties]["name"][:minLength]
    assert_equal 100, schema[:properties]["name"][:maxLength]
    assert_equal "email", schema[:properties]["email"][:format]
    assert_equal 18, schema[:properties]["age"][:minimum]

    doc_example_output(schema)
  end

  test "generates strict schema for structured output" do
    # region strict_schema_generation
    schema = TestBlogPost.to_json_schema(strict: true, name: "blog_post_schema")
    # endregion strict_schema_generation

    assert_equal "json_schema", schema[:format][:type]
    assert_equal "blog_post_schema", schema[:format][:name]
    assert schema[:format][:strict]
    assert_equal "object", schema[:format][:schema][:type]
    assert schema[:format][:schema][:properties].key?("title")
    assert schema[:format][:schema][:properties].key?("content")

    doc_example_output(schema)
  end

  test "excludes specified fields" do
    # region schema_with_exclusions
    schema = TestBlogPost.to_json_schema(exclude: [ :tags, :published_at ])
    # endregion schema_with_exclusions

    assert schema[:properties].key?("title")
    assert schema[:properties].key?("content")
    assert schema[:properties].key?("status")
    assert_not schema[:properties].key?("tags")
    assert_not schema[:properties].key?("published_at")

    doc_example_output(schema)
  end

  test "handles enum validations" do
    # region schema_with_enums
    schema = TestBlogPost.to_json_schema
    # endregion schema_with_enums

    assert_equal [ "draft", "published", "archived" ], schema[:properties]["status"][:enum]

    doc_example_output(schema)
  end

  test "agent can use schema generator for structured output" do
    # region agent_using_schema
    # Generate schema from model - returns a Ruby hash
    user_schema = TestUser.to_json_schema(strict: true, name: "user_extraction")

    # In actual usage, the agent would use the hash directly:
    # prompt(output_schema: user_schema)
    # endregion agent_using_schema

    assert user_schema.is_a?(Hash)
    assert_equal "json_schema", user_schema[:format][:type]
    assert_equal "object", user_schema[:format][:schema][:type]

    doc_example_output(user_schema)
  end

  test "generates schema from ActiveRecord model with columns" do
    # region activerecord_schema_generation
    schema = User.to_json_schema
    # endregion activerecord_schema_generation

    assert_equal "object", schema[:type]
    assert schema[:properties].key?("name")
    assert schema[:properties].key?("email")
    assert schema[:properties].key?("age")
    assert schema[:properties].key?("role")
    assert schema[:properties].key?("active")

    # Check column types are properly mapped
    assert_equal "string", schema[:properties]["name"][:type]
    assert_equal "string", schema[:properties]["email"][:type]
    assert_equal "integer", schema[:properties]["age"][:type]
    assert_equal "boolean", schema[:properties]["active"][:type]

    # Check required fields (non-nullable columns)
    assert schema[:required].include?("name")
    assert schema[:required].include?("email")

    doc_example_output(schema)
  end

  test "generates schema with associations" do
    # region activerecord_schema_with_associations
    schema = User.to_json_schema(include_associations: true)
    # endregion activerecord_schema_with_associations

    assert schema[:properties].key?("posts")
    assert schema[:properties].key?("profile")
    assert_equal "array", schema[:properties]["posts"][:type]
    assert schema[:properties]["posts"][:items].key?(:"$ref")

    doc_example_output(schema)
  end
end
