# frozen_string_literal: true

require "test_helper"
require "active_agent/schema_generator"

class StructuredOutputJsonParsingTest < ActiveSupport::TestCase
  class DataExtractionAgent < ApplicationAgent
    generate_with :openai

    def extract_user_data
      prompt(
        message: params[:message] || "Extract the following user data from this text: John Doe is 30 years old and his email is john@example.com",
        output_schema: params[:output_schema]
      )
    end

    def extract_with_model_schema
      prompt(
        message: "Extract user information from: Jane Smith, age 25, contact: jane.smith@email.com",
        output_schema: params[:output_schema]
      )
    end

    def extract_with_active_record_schema
      prompt(
        message: "Extract user data from: Alice Johnson, 28 years old, email: alice@example.com, bio: Software engineer",
        output_schema: params[:output_schema]
      )
    end

    # Remove the after_generation callback for now - focus on testing the core functionality
  end

  test "structured output sets content_type to application/json and auto-parses JSON" do
    VCR.use_cassette("structured_output_json_parsing") do
      # Create a test model class with schema generator
      test_user_model = Class.new do
        include ActiveModel::Model
        include ActiveModel::Attributes
        include ActiveModel::Validations
        include ActiveAgent::SchemaGenerator

        attribute :name, :string
        attribute :age, :integer
        attribute :email, :string

        validates :name, presence: true
        validates :age, presence: true, numericality: { greater_than: 0 }
        validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
      end

      # Generate schema from the model using the schema generator
      schema = test_user_model.to_json_schema(strict: true, name: "user_data")

      # Generate with structured output using the .with pattern
      response = DataExtractionAgent.with(output_schema: schema).extract_user_data.generate_now

      # Verify content_type is set to application/json
      assert_equal "application/json", response.message.content_type

      # Verify content is automatically parsed as JSON
      assert response.message.content.is_a?(Hash)
      assert response.message.content.key?("name")
      assert response.message.content.key?("age")

      # Verify raw content is still available as string
      assert response.message.raw_content.is_a?(String)

      doc_example_output(response)
    end
  end

  test "integration with ActiveModel schema generator for structured output" do
    VCR.use_cassette("structured_output_with_model_schema") do
      # Create an ActiveModel class for testing
      test_model = Class.new do
        include ActiveModel::Model
        include ActiveModel::Attributes
        include ActiveAgent::SchemaGenerator

        attribute :name, :string
        attribute :age, :integer
        attribute :email, :string
      end

      # Generate schema from ActiveModel
      schema = test_model.to_json_schema(strict: true, name: "user_data")

      # Generate response using model-generated schema
      response = DataExtractionAgent.with(output_schema: schema).extract_with_model_schema.generate_now

      # Verify content_type
      assert_equal "application/json", response.message.content_type

      # Verify JSON was automatically parsed
      assert response.message.content.is_a?(Hash)
      assert response.message.content.key?("name")
      assert response.message.content.key?("age")
      assert response.message.content.key?("email")

      # Verify values make sense
      assert_equal "Jane Smith", response.message.content["name"]
      assert_equal 25, response.message.content["age"]
      assert response.message.content["email"].include?("@")

      doc_example_output(response)
    end
  end

  test "integration with ActiveRecord schema generator for structured output" do
    VCR.use_cassette("structured_output_with_active_record_schema") do
      # Use the existing User model from test/dummy
      require_relative "../dummy/app/models/user"

      # Generate schema from ActiveRecord model
      schema = User.to_json_schema(strict: true, name: "user_data")

      # Generate response using ActiveRecord-generated schema
      response = DataExtractionAgent.with(output_schema: schema).extract_with_active_record_schema.generate_now

      # Verify content_type
      assert_equal "application/json", response.message.content_type

      # Verify JSON was automatically parsed
      assert response.message.content.is_a?(Hash)
      assert response.message.content.key?("name")
      assert response.message.content.key?("email")
      assert response.message.content.key?("age")

      # Verify the data makes sense
      assert response.message.content["name"].is_a?(String)
      assert response.message.content["age"].is_a?(Integer)
      assert response.message.content["email"].include?("@")

      doc_example_output(response)
    end
  end

  test "without structured output uses text/plain content_type" do
    VCR.use_cassette("plain_text_response") do
      # Generate without structured output (no output_schema)
      response = DataExtractionAgent.with(message: "What is the capital of France?").prompt_context.generate_now

      # Verify content_type is plain text
      assert_equal "text/plain", response.message.content_type

      # Content should not be parsed as JSON
      assert response.message.content.is_a?(String)
      assert response.message.content.downcase.include?("paris")

      doc_example_output(response)
    end
  end

  test "handles invalid JSON gracefully" do
    # This test ensures that if for some reason the provider returns invalid JSON
    # with application/json content_type, we handle it gracefully

    # Create a message with invalid JSON but JSON content_type
    message = ActiveAgent::ActionPrompt::Message.new(
      content: "{invalid json}",
      content_type: "application/json",
      role: :assistant
    )

    # Should return the raw string since parsing failed
    assert_equal "{invalid json}", message.content
    assert_equal "{invalid json}", message.raw_content
  end
end
