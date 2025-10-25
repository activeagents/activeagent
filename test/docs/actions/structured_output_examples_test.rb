require "test_helper"

module Docs
  module Actions
    module StructuredOutputExamples
      # Base ApplicationAgent for tests
      class ApplicationAgent < ActiveAgent::Base
        # Will be overridden in specific agents
      end

      # region basic_json_object_agent
      class DataAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o"

        def extract
          prompt(
            "Extract user info as a JSON object: John Doe, 30, john@example.com",
            response_format: :json_object
          )
        end
      end
      # endregion basic_json_object_agent

      # region anthropic_json_agent
      class AnthropicAgent < ApplicationAgent
        generate_with :anthropic, model: "claude-3-5-sonnet-latest"

        def extract
          prompt(
            "Extract user data as JSON: Jane Smith, jane@example.com, 28",
            response_format: :json_object
          )
        end
      end
      # endregion anthropic_json_agent

      # region json_schema_with_view_agent
      class DataExtractionAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o"

        def parse_resume
          prompt(
            message: "Extract resume data: #{params[:file_data]}",
            # Loads views/agents/data_extraction/parse_resume/schema.json
            response_format: :json_schema
          )
        end
      end
      # endregion json_schema_with_view_agent

      class InlineSchemaAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o"

        def parse
          # region named_json_schema_agent
          prompt(
            "Extract colors: red, blue, green. Return as json.",
            response_format: {
              type:        "json_schema",
              json_schema: :colors_schema
            }
          )
          # endregion named_json_schema_agent
        end

        def extract
          # region inline_json_schema_agent
          prompt(
            "Extract colors: red, blue, green. Return as json.",
            response_format: {
              type: "json_schema",
              json_schema: {
                name: "color_list",
                schema: {
                  type: "object",
                  properties: {
                    colors: {
                      type: "array",
                      items: { type: "string" }
                    }
                  },
                  required: [ "colors" ],
                  additionalProperties: false
                },
                strict: true
              }
            }
          )
          # endregion inline_json_schema_agent
        end
      end


      # region user_model_with_schema
      class User
        include ActiveModel::Model
        include ActiveModel::Attributes
        include ActiveAgent::SchemaGenerator

        attribute :name, :string
        attribute :email, :string
        attribute :age, :integer

        validates :name, presence: true, length: { minimum: 2 }
        validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
        validates :age, numericality: { greater_than_or_equal_to: 18 }
      end
      # endregion user_model_with_schema

      class ExtractionAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o"

        def extract_user
          # region extraction_agent_with_model
          prompt(
            message: params[:text],
            response_format: {
              type:        "json_schema",
              json_schema: User.to_json_schema(strict: true, name: "user_data")
            }
          )
          # endregion extraction_agent_with_model
        end
      end

      class Tests < ActiveSupport::TestCase
        test "basic json object extraction" do
          VCR.use_cassette("docs/actions/structured_output/basic_json_object") do
            # region basic_json_object_usage
            response = DataAgent.extract.generate_now
            data = response.message.parsed_json
            # => { name: "John Doe", age: 30, email: "john@example.com" }
            # endregion basic_json_object_usage

            assert response.success?
            assert_not_nil data
            assert_kind_of Hash, data
            assert_includes data.keys, :name
            assert_includes data.keys, :email
            assert_includes data.keys, :age
          end
        end

        test "json object parsing with options" do
          VCR.use_cassette("docs/actions/structured_output/basic_json_object") do
            response = DataAgent.extract.generate_now

            # region json_object_parsing
            data = response.message.parsed_json(
              symbolize_names: true,       # Convert keys to symbols (default: true)
              normalize_names: :underscore # Normalize keys (default: :underscore)
            )
            # endregion json_object_parsing

            assert_not_nil data
            assert_kind_of Hash, data
          end
        end

        test "anthropic emulated json mode" do
          VCR.use_cassette("docs/actions/structured_output/anthropic_json") do
            response = AnthropicAgent.extract.generate_now

            assert response.success?
            assert_not_nil response.message.parsed_json
            data = response.message.parsed_json
            assert_kind_of Hash, data
          end
        end

        test "inline json schema" do
          VCR.use_cassette("docs/actions/structured_output/inline_schema") do
            # region inline_schema_usage
            response = InlineSchemaAgent.extract.generate_now
            response.message.parsed_json # => { colors: ["red", "blue", "green"] }
            # endregion inline_schema_usage

            assert response.success?
            assert_kind_of Hash, response.message.parsed_json
            assert_includes response.message.parsed_json.keys, :colors
            assert_kind_of Array, response.message.parsed_json[:colors]
          end
        end

        test "named json schema" do
          VCR.use_cassette("docs/actions/structured_output/named_schema") do
            response = InlineSchemaAgent.parse.generate_now

            assert response.success?
            assert_kind_of Hash, response.message.parsed_json
            assert_includes response.message.parsed_json.keys, :colors
            assert_kind_of Array, response.message.parsed_json[:colors]
          end
        end

        test "generate schema from activemodel" do
          # region generate_schema_activemodel
          schema = User.to_json_schema
          # => { type: "object", properties: { name: {...}, email: {...} }, required: [...] }
          # endregion generate_schema_activemodel

          assert_kind_of Hash, schema
          assert_equal "object", schema[:type]
          assert_includes schema[:properties].keys, :name
          assert_includes schema[:properties].keys, :email
          assert_includes schema[:properties].keys, :age
          assert_includes schema[:required], :name
          assert_includes schema[:required], :email
        end

        test "use generated schema in agent" do
          VCR.use_cassette("docs/actions/structured_output/generated_schema") do
            response = ExtractionAgent.with(
              text: "John Smith is 25 years old and his email is john@example.com"
            ).extract_user.generate_now

            assert response.success?
            assert_kind_of Hash, response.message.parsed_json
          end
        end

        test "json schema with view template" do
          VCR.use_cassette("docs/actions/structured_output/json_schema_with_view") do
            # region json_schema_view_usage
            response = DataExtractionAgent.with(
              file_data: "Resume: John Smith\nEmail: john@example.com\nPhone: 555-1234\n" \
                         "Education: BS Computer Science, MIT, 2015\n" \
                         "Experience: Software Engineer at TechCo, 2015-2020"
            ).parse_resume.generate_now

            data = response.message.parsed_json
            # => { name: "John Smith", email: "john@example.com", ... }
            # endregion json_schema_view_usage

            assert response.success?
            assert_kind_of Hash, data
            assert_includes data.keys, :name
            assert_includes data.keys, :email
            assert_includes data.keys, :experience
          end
        end

        test "access response content types" do
          VCR.use_cassette("docs/actions/structured_output/inline_schema") do
            response = InlineSchemaAgent.extract.generate_now

            # region response_content_access
            response.message.parsed_json # Parsed hash
            response.message.content     # Original JSON string
            # endregion response_content_access

            assert_kind_of Hash, response.message.parsed_json
            assert_kind_of String, response.message.content
          end
        end
      end

      class ProviderSupportTests < ActiveSupport::TestCase
        test "openai native json object support" do
          VCR.use_cassette("docs/actions/structured_output/openai_json_object") do
            # region openai_json_object
            class OpenAIAgent < ApplicationAgent
              generate_with :openai, model: "gpt-4o"

              def extract
                prompt(
                  "Extract as JSON: Alice, 35, alice@test.com",
                  response_format: { type: "json_object" }
                )
              end
            end
            # endregion openai_json_object

            response = OpenAIAgent.extract.generate_now
            assert response.success?
            data = response.message.parsed_json
            assert_kind_of Hash, data
          end
        end

        test "openai native json schema support" do
          VCR.use_cassette("docs/actions/structured_output/openai_json_schema") do
            # region openai_json_schema
            class OpenAISchemaAgent < ApplicationAgent
              generate_with :openai, model: "gpt-4o"

              def extract
                prompt(
                  "List fruits: apple, banana, orange. Return as JSON.",
                  response_format: {
                    type: "json_schema",
                    json_schema: {
                      name: "fruits",
                      schema: {
                        type: "object",
                        properties: {
                          items: {
                            type: "array",
                            items: { type: "string" }
                          }
                        },
                        required: [ "items" ],
                        additionalProperties: false
                      },
                      strict: true
                    }
                  }
                )
              end
            end
            # endregion openai_json_schema

            response = OpenAISchemaAgent.extract.generate_now
            assert response.success?
            assert_kind_of Hash, response.message.parsed_json
          end
        end

        test "openrouter json object support" do
          VCR.use_cassette("docs/actions/structured_output/openrouter_json_object") do
            # region openrouter_json_object
            class OpenRouterAgent < ApplicationAgent
              generate_with :open_router, model: "openai/gpt-4o-mini"

              def extract
                prompt(
                  "Extract as JSON: Bob, 40, bob@test.com",
                  response_format: { type: "json_object" }
                )
              end
            end
            # endregion openrouter_json_object

            response = OpenRouterAgent.extract.generate_now
            assert response.success?
            data = response.message.parsed_json
            assert_kind_of Hash, data
          end
        end

        test "openrouter json schema support" do
          VCR.use_cassette("docs/actions/structured_output/openrouter_json_schema") do
            # region openrouter_json_schema
            class OpenRouterSchemaAgent < ApplicationAgent
              generate_with :open_router, model: "openai/gpt-4o-mini"

              def extract
                prompt(
                  "List animals: dog, cat, bird. Return as JSON.",
                  response_format: {
                    type: "json_schema",
                    json_schema: {
                      name: "animals",
                      schema: {
                        type: "object",
                        properties: {
                          list: {
                            type: "array",
                            items: { type: "string" }
                          }
                        },
                        required: [ "list" ],
                        additionalProperties: false
                      },
                      strict: true
                    }
                  }
                )
              end
            end
            # endregion openrouter_json_schema

            response = OpenRouterSchemaAgent.extract.generate_now
            assert response.success?
            # OpenRouter may return JSON as string, need to parse
            content = response.message.parsed_json
            if content.is_a?(String)
              content = JSON.parse(content)
            end
            assert_kind_of Hash, content
          end
        end

        test "ollama json object support" do
          skip "Ollama tests require local setup"
            # region ollama_json_object
            class OllamaAgent < ApplicationAgent
              generate_with :ollama, model: "llama3.2"

              def extract
                prompt(
                  "Extract as JSON: Charlie, 45, charlie@test.com",
                  response_format: { type: "json_object" }
                )
              end
            end
          # endregion ollama_json_object          response = OllamaAgent.extract.generate_now
          assert response.success?
        end
      end

      class BestPracticesTests < ActiveSupport::TestCase
        test "strict mode for critical data" do
          VCR.use_cassette("docs/actions/structured_output/strict_mode") do
            # region strict_mode_example
            class StrictAgent < ApplicationAgent
              generate_with :openai, model: "gpt-4o"

              def extract
                prompt(
                  "Extract as JSON: David, david@test.com",
                  response_format: {
                    type: "json_schema",
                    json_schema: {
                      name: "user_info",
                      schema: {
                        type: "object",
                        properties: {
                          name: { type: "string" },
                          email: { type: "string" }
                        },
                        required: [ "name", "email" ],
                        additionalProperties: false
                      },
                      strict: true
                    }
                  }
                )
              end
            end
            # endregion strict_mode_example

            response = StrictAgent.extract.generate_now
            assert response.success?
            assert_kind_of Hash, response.message.parsed_json
            assert_includes response.message.parsed_json.keys, :name
            assert_includes response.message.parsed_json.keys, :email
          end
        end

        test "test with real providers using vcr" do
          # region test_with_vcr
          VCR.use_cassette("docs/actions/structured_output/extraction") do
            response = DataAgent.extract.generate_now
            assert_includes response.message.parsed_json.keys, :name
          end
          # endregion test_with_vcr
        end
      end

      class TroubleshootingTests < ActiveSupport::TestCase
        test "validates strict mode schema" do
          # region strict_mode_validation
          schema = User.to_json_schema(strict: true, name: "user_data")
          # endregion strict_mode_validation

          assert_kind_of Hash, schema
          assert_equal true, schema[:strict]
          assert_equal "user_data", schema[:name]
          assert_kind_of Hash, schema[:schema]
        end

        test "handles missing fields with strict mode" do
          VCR.use_cassette("docs/actions/structured_output/strict_mode") do
            response = StrictAgent.extract.generate_now

            # Strict mode ensures all required fields are present
            assert response.success?
            assert_includes response.message.parsed_json.keys, :name
            assert_includes response.message.parsed_json.keys, :email
          end
        end
      end

      # Helper agent for tests
      class StrictAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o"

        def extract
          prompt(
            "Extract as JSON: David, david@test.com",
            response_format: {
              type: "json_schema",
              json_schema: {
                name: "user_info",
                schema: {
                  type: "object",
                  properties: {
                    name: { type: "string" },
                    email: { type: "string" }
                  },
                  required: [ "name", "email" ],
                  additionalProperties: false
                },
                strict: true
              }
            }
          )
        end
      end
    end
  end
end
