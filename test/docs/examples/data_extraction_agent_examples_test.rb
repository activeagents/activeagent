require "test_helper"

module Docs
  module Examples
    module DataExtractionAgentExamples
      # Base ApplicationAgent for tests
      class ApplicationAgent < ActiveAgent::Base
        # Will be overridden in specific agents
      end

      class QuickStart < ActiveSupport::TestCase
        # region quick_start_agent
        class ResumeExtractorAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o"

          def parse
            prompt(
              message: "Extract resume data into JSON.",
              document: params[:document],
              response_format: :json_schema # Loads parse.json schema
            )
          end
        end
        # endregion quick_start_agent

        test "quick start extraction" do
          VCR.use_cassette("docs/examples/data_extraction_agent/quick_start") do
            path = Rails.root.join("../../test/fixtures/files/")

            # region quick_start_usage
            # Read and encode PDF
            pdf_file = File.read(path + "sample_resume.pdf")
            pdf_data = "data:application/pdf;base64,#{Base64.strict_encode64(pdf_file)}"

            # Extract structured data
            response = ResumeExtractorAgent.with(document: pdf_data).parse.generate_now

            # Access parsed fields
            resume = response.message.parsed_json
            resume[:name]        # => "John Doe"
            resume[:email]       # => "john.doe@example.com"
            resume[:experience]  # => [{"job_title"=>"Senior Software Engineer", ...}]
            # endregion quick_start_usage

            doc_example_output(response.message.parsed_json)

            assert_kind_of Hash, resume
            assert resume.key?(:name)
          end
        end
      end


      class ModelGeneratedSchema < ActiveSupport::TestCase
        # region model_generated_schema_model
        class Resume
          include ActiveModel::Model
          include ActiveModel::Attributes
          include ActiveAgent::SchemaGenerator

          attribute :name, :string
          attribute :email, :string
          attribute :phone, :string
          attribute :education
          attribute :experience

          validates :name, presence: true, length: { minimum: 2 }
          validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
          validates :phone, presence: true
        end
        # endregion model_generated_schema_model

        # region model_generated_schema_agent
        class ResumeExtractorAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o"

          def parse
            prompt(
              message: "Extract resume data into JSON.",
              document: params[:document],
              response_format: {
                type: "json_schema",
                json_schema: Resume.to_json_schema(strict: true, name: "resume_schema")
              }
            )
          end
        end
        # endregion model_generated_schema_agent

        test "model-generated schema usage" do
          VCR.use_cassette("docs/examples/data_extraction_agent/model_generated_schema") do
            # Read and encode PDF
            pdf_file = File.read(Rails.root.join("../../test/fixtures/files/sample_resume.pdf"))
            pdf_data = "data:application/pdf;base64,#{Base64.strict_encode64(pdf_file)}"

            response = ResumeExtractorAgent.with(document: pdf_data).parse.generate_now

            json_schema = Resume.to_json_schema(strict: true, name: "resume_schema")
            assert_equal "resume_schema", json_schema[:name]
            assert json_schema[:strict]
            assert_equal "object", json_schema[:schema][:type]

            resume = response.message.parsed_json
            assert_kind_of Hash, resume

            doc_example_output(response)
          end
        end
      end

      class ConsensusValidation < ActiveSupport::TestCase
        # region consensus_validation_example
        class ResumeExtractorAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o"

          # Require two extraction attempts to produce identical results
          around_prompt do |agent, action|
            attempt_one = action.call
            attempt_two = action.call

            next if attempt_one.message.parsed_json == attempt_two.message.parsed_json

            fail "Consensus not reached in #{agent.class.name}##{agent.action_name}: " \
                 "Two attempts produced different results"
          end

          def parse
            prompt(
              message: "Extract resume data into JSON.",
              document: params[:document],
              response_format: :json_schema
            )
          end
        end
        # endregion consensus_validation_example

        test "consensus validation pattern" do
          VCR.use_cassette("docs/examples/data_extraction_agent/consensus_validation") do
            # Read and encode PDF
            pdf_file = File.read(Rails.root.join("../../test/fixtures/files/sample_resume.pdf"))
            pdf_data = "data:application/pdf;base64,#{Base64.strict_encode64(pdf_file)}"

            # This will run the extraction twice and ensure results match
            response = ResumeExtractorAgent.with(document: pdf_data).parse.generate_now

            assert_not_nil response
            assert_not_nil response.message.content

            doc_example_output(response)
          end
        end
      end
    end
  end
end
