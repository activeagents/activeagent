require "test_helper"

# Tests for code examples in docs/agents.md
#
# Each example is wrapped in its own TestCase class to isolate agent definitions
# and prevent class name conflicts. This follows the pattern used in other
# documentation test files like actions_examples_test.rb.
#
# Test Coverage:
# - Quick Example: SupportAgent with callbacks
# - Basic Structure: TranslationAgent
# - Invocation: with() parameters and direct methods
# - Actions Interface: prompt() and embed()
# - Using Concerns: ResearchTools module
# - Callbacks: before_generation and after_generation
# - Streaming: on_stream with real-time updates
module Docs
  class AgentsExamplesTest < ActiveSupport::TestCase
    # =============================================================================
    # Quick Example - SupportAgent
    # =============================================================================
    class QuickExampleTest < ActiveSupport::TestCase
      # Mock User class for testing
      class User
        def self.find(id)
          new(id)
        end

        def initialize(id)
          @id = id
        end

        attr_reader :id
      end

      # region quick_example_support_agent
      class SupportAgent < ApplicationAgent
        before_generation :load_user_context

        def help
          prompt message: "User needs help: #{params[:message]}"
        end

        private

        def load_user_context
          @user = User.find(params[:user_id]) if params[:user_id]
        end
      end
      # endregion quick_example_support_agent

      test "demonstrates basic agent with callbacks" do
        VCR.use_cassette("docs/agents_examples/quick_example_support_agent") do
          response =
          # region quick_example_support_agent_usage
          SupportAgent.with(user_id: 1, message: "Need help").help.generate_now
          # endregion quick_example_support_agent_usage

          assert response.success?
          assert_not_nil response.message.content
          assert response.message.content.length > 0

          doc_example_output(response)
        end
      end
    end

    # =============================================================================
    # Basic Structure - TranslationAgent
    # =============================================================================
    class BasicStructureTest < ActiveSupport::TestCase
      # region basic_structure_translation_agent
      class TranslationAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o"

        def translate
          prompt message: "Translate '#{params[:text]}' to #{params[:target_lang]}"
        end
      end
      # endregion basic_structure_translation_agent

      test "demonstrates basic agent structure" do
        VCR.use_cassette("docs/agents_examples/basic_structure_translation_agent") do
          response = TranslationAgent.with(
            text: "Hello world",
            target_lang: "Spanish"
          ).translate.generate_now

          assert response.success?
          assert_not_nil response.message.content
          assert response.message.content.length > 0

          doc_example_output(response)
        end
      end
    end

    # =============================================================================
    # Invocation Patterns
    # =============================================================================
    class InvocationTest < ActiveSupport::TestCase
      # region invocation_translation_agent
      class TranslationAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o"

        def translate
          prompt message: "Translate '#{params[:text]}' to #{params[:target_lang]}"
        end
      end
      # endregion invocation_translation_agent

      test "demonstrates with parameters invocation pattern" do
        VCR.use_cassette("docs/agents_examples/invocation_with_parameters") do
          # region invocation_with_parameters
          # With parameters
          generation = TranslationAgent.with(
            text: "Hello world",
            target_lang: "es"
          ).translate

          # Execute synchronously
          response = generation.generate_now
          # response.message.content  # => "Hola mundo"
          # endregion invocation_with_parameters

          assert response.success?
          assert_not_nil response.message.content
          assert response.message.content.length > 0

          doc_example_output(response)
        end
      end

      test "demonstrates direct method invocation for prototyping" do
        VCR.use_cassette("docs/agents_examples/invocation_direct_methods") do
          # region invocation_direct_methods
          response = ApplicationAgent.prompt(message: "Hello").generate_now
          # endregion invocation_direct_methods

          assert response.success?
          assert_not_nil response.message.content

          doc_example_output(response)
        end
      end
    end

    # =============================================================================
    # Actions Interface
    # =============================================================================
    class ActionsInterfaceTest < ActiveSupport::TestCase
      # region actions_interface_agent
      class MyAgent < ApplicationAgent
        def my_action
          # Simple message
          prompt "User message: #{params[:message]}"
        end

        def embed_text
          # Simple input
          embed "Text to embed: #{params[:input]}"
        end
      end
      # endregion actions_interface_agent

      test "demonstrates prompt action interface" do
        VCR.use_cassette("docs/agents_examples/actions_interface_prompt") do
          response = MyAgent.with(message: "Hello").my_action.generate_now

          assert response.success?
          assert_not_nil response.message.content

          doc_example_output(response)
        end
      end

      test "demonstrates embed action interface" do
        VCR.use_cassette("docs/agents_examples/actions_interface_embed") do
          response = MyAgent.with(input: "Test text").embed_text.embed_now

          assert response.success?
          assert_not_nil response.data
          assert_kind_of Array, response.data.first[:embedding]

          doc_example_output(response)
        end
      end
    end

    # =============================================================================
    # Using Concerns
    # =============================================================================
    class UsingConcernsTest < ActiveSupport::TestCase
      # region concerns_research_tools
      # app/agents/concerns/research_tools.rb
      module ResearchTools
        extend ActiveSupport::Concern

        def search_papers
          prompt message: "Search: #{params[:query]}"
        end

        def analyze_data
          prompt message: "Analyze: #{params[:data]}"
        end
      end

      # app/agents/research_agent.rb
      class ResearchAgent < ApplicationAgent
        include ResearchTools  # Adds search_papers and analyze_data actions

        generate_with :openai, model: "gpt-4o"
      end
      # endregion concerns_research_tools

      test "demonstrates concern usage with search_papers" do
        VCR.use_cassette("docs/agents_examples/concerns_search_papers") do
          response = ResearchAgent.with(
            query: "quantum computing papers from 2023"
          ).search_papers.generate_now

          assert response.success?
          assert_not_nil response.message.content

          doc_example_output(response)
        end
      end

      test "demonstrates concern usage with analyze_data" do
        VCR.use_cassette("docs/agents_examples/concerns_analyze_data") do
          response = ResearchAgent.with(
            data: "Temperature readings: 20, 22, 21, 23, 22"
          ).analyze_data.generate_now

          assert response.success?
          assert_not_nil response.message.content

          doc_example_output(response)
        end
      end
    end

    # =============================================================================
    # Callbacks
    # =============================================================================
    class CallbacksTest < ActiveSupport::TestCase
      # Mock User class for testing
      class User
        def self.find(id)
          new(id)
        end

        def initialize(id)
          @id = id
        end

        attr_reader :id
      end

      # region callbacks_agent
      class MyAgent < ApplicationAgent
        before_generation :load_context
        after_generation :log_response

        def chat
          prompt message: params[:message]
        end

        private

        def load_context
          @user = User.find(params[:user_id]) if params[:user_id]
        end

        def log_response
          Rails.logger.info "Generated response"
        end
      end
      # endregion callbacks_agent

      test "demonstrates callbacks lifecycle" do
        VCR.use_cassette("docs/agents_examples/callbacks") do
          response = MyAgent.with(user_id: 1, message: "Hello").chat.generate_now

          assert response.success?
          assert_not_nil response.message.content

          doc_example_output(response)
        end
      end
    end    # =============================================================================
    # Streaming
    # =============================================================================
    class StreamingTest < ActiveSupport::TestCase
      # region streaming_agent
      class StreamingAgent < ApplicationAgent
        on_stream :broadcast_chunk

        def chat
          prompt message: params[:message], stream: true
        end

        private

        def broadcast_chunk(chunk)
          # In real app: ActionCable.server.broadcast("chat", content: chunk.delta)
        end
      end
      # endregion streaming_agent

      test "demonstrates streaming responses" do
        VCR.use_cassette("docs/agents_examples/streaming") do
          response = StreamingAgent.with(message: "Tell me a short joke").chat.generate_now

          assert response.success?
          assert_not_nil response.message.content

          doc_example_output(response)
        end
      end
    end
  end
end
