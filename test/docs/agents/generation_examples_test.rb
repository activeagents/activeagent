require "test_helper"

module Docs
  module Agents
    module GenerationExamples
      # Test agent using Mock provider to avoid VCR dependencies
      class ApplicationAgent < ActiveAgent::Base
        generate_with :mock
        embed_with :mock
      end

      class SynchronousGeneration < ActiveSupport::TestCase
        test "standard synchronous generation" do
          response =
          # region synchronous_generation_basic
          ApplicationAgent.prompt(message: "Hello").generate_now
          # endregion synchronous_generation_basic

          assert_not_nil response
          assert_not_nil response.message.content
        end

        test "synchronous generation with immediate processing" do
          response =
          # region synchronous_generation_bang
          ApplicationAgent.prompt(message: "Hello").generate_now!
          # endregion synchronous_generation_bang

          assert_not_nil response
          assert_not_nil response.message.content
        end
      end

      class AsynchronousGeneration < ActiveSupport::TestCase
        test "basic background generation" do
          generation_job =
          # region asynchronous_generation_basic
          ApplicationAgent.prompt(message: "Analyze this data").generate_later
          # endregion asynchronous_generation_basic

          assert_kind_of ActiveAgent::GenerationJob, generation_job
        end


        test "background generation with job options" do
          generation_job =
          # region asynchronous_generation_options
          ApplicationAgent.prompt(message: "Generate report").generate_later(
            queue: :reports,
            priority: 10,
            wait: 5.minutes
          )
          # endregion asynchronous_generation_options

          assert_kind_of ActiveAgent::GenerationJob, generation_job
        end
      end

      class DirectGeneration < ActiveSupport::TestCase
        test "prompt generation without action methods" do
          # region direct_generation_basic
          response = ApplicationAgent.prompt(
            "What is 2+2?",
            temperature: 0.7
          ).generate_now
          # endregion direct_generation_basic

          assert_not_nil response
          assert_not_nil response.message.content
        end
      end

      class ParameterizedGeneration < ActiveSupport::TestCase
        # region parameterized_generation_agent
        class WelcomeAgent < ApplicationAgent
          def greet
            prompt(message: "Hello #{params[:name]}!")
          end
        end
        # endregion parameterized_generation_agent

        test "pass parameters to action methods" do
          # region parameterized_generation_usage
          response = WelcomeAgent.with(name: "Alice").greet.generate_now
          # endregion parameterized_generation_usage

          assert_not_nil response
          assert_includes response.message.content, "Alice"
        end
      end

      class ActionBasedGeneration < ActiveSupport::TestCase
        # region action_based_generation_agent
        class SupportAgent < ApplicationAgent
          def help(topic)
            prompt(message: "Help with #{topic}")
          end
        end
        # endregion action_based_generation_agent


        test "define reusable actions" do
          # region action_based_generation_usage
          response = SupportAgent.help("authentication").generate_now
          # endregion action_based_generation_usage

          assert_not_nil response
          assert_includes response.message.content, "authentication"
        end
      end

      class EmbeddingGeneration < ActiveSupport::TestCase
        test "generate embedding for single input" do
          # region embedding_generation_single
          response = ApplicationAgent.embed(
            input: "The quick brdown fox"
          ).embed_now

          embedding = response.data.first[:embedding]
          # endregion embedding_generation_single

          assert_kind_of Array, embedding
          assert embedding.all? { |v| v.is_a?(Float) }
        end


        test "generate embeddings for multiple inputs" do
          # region embedding_generation_multiple
          response = ApplicationAgent.embed(
            input: [ "First text", "Second text" ]
          ).embed_now
          # endregion embedding_generation_multiple

          embeddings = response.data.map { |e| e[:embedding] }

          assert_equal 2, embeddings.size
          assert embeddings.all? { |e| e.is_a?(Array) }
          assert embeddings.all? { |e| e.all? { |v| v.is_a?(Float) } }
        end
      end

      class InspectingBeforeExecution < ActiveSupport::TestCase
        test "access prompt properties before generating" do
          # region inspecting_before_execution
          generation = ApplicationAgent.prompt(message: "test")
          # endregion inspecting_before_execution

          assert_equal false, generation.processed?
          assert_equal "test", generation.message.content
          assert_not_nil generation.messages
          assert_not_nil generation.actions
          assert_not_nil generation.options
        end
      end

      class ResponseObjects < ActiveSupport::TestCase
        test "access prompt response content" do
          # region response_objects_prompt
          response = ApplicationAgent.prompt(message: "Hello").generate_now
          # endregion response_objects_prompt

          assert_not_nil response.message.content
          assert_not_nil response.messages
          assert_not_nil response.raw_response
        end


        test "access embedding response content" do
          # region response_objects_embedding
          response = ApplicationAgent.embed(input: "text").embed_now
          # endregion response_objects_embedding

          assert_kind_of Array, response.data
          assert_not_nil response.data.first[:embedding]
        end
      end

      class BackgroundJobConfiguration < ActiveSupport::TestCase
        # region background_job_configuration
        class MyAgent < ApplicationAgent
          self.generate_later_queue_name = :ai_tasks
        end
        # endregion background_job_configuration

        test "configure queue name" do
          assert_equal :ai_tasks, MyAgent.generate_later_queue_name
        end
      end
    end
  end
end
