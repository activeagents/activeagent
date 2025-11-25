require "test_helper"

class ActionsExamplesTest < ActiveSupport::TestCase
  # region quick_example_summary_agent
  class SummaryAgent < ApplicationAgent
    def summarize
      prompt(
        instructions: "Summarize in 2-3 sentences",
        message: params[:text],
        temperature: 0.3
      )
    end
  end
  # endregion quick_example_summary_agent

  test "demonstrates basic action definition with summarize" do
    VCR.use_cassette("docs/actions_examples/quick_example_summary_usage") do
      text = "Artificial intelligence has revolutionized many industries. Machine learning algorithms can now process vast amounts of data to identify patterns and make predictions. Deep learning, a subset of machine learning, has enabled breakthroughs in image recognition, natural language processing, and autonomous systems."
      response =
      # region quick_example_summary_usage
      # Synchronous execution
      SummaryAgent.with(text:).summarize.generate_now
      # Create generation for async execution
      SummaryAgent.with(text:).summarize.generate_later
      # endregion quick_example_summary_usage

      assert_not_nil response.message.content
      assert response.message.content.length < 500  # Should be a brief summary

      doc_example_output(response)
    end
  end

  test "demonstrates message with image content" do
    VCR.use_cassette("docs/actions_examples/actions_message_with_image") do
      # region messages_with_image
      response = ApplicationAgent.prompt(
        "Analyze this image", image: "https://picsum.photos/200"
      ).generate_now
      # endregion messages_with_image

      assert_not_nil response.message.content
      assert response.message.content.length > 0

      doc_example_output(response)
    end
  end

  class OpenAIBasicExample < ActiveSupport::TestCase
    # region tools_weather_agent
    class WeatherAgent < ApplicationAgent
      generate_with :openai, model: "gpt-4o"

      def weather_update
        prompt(
          input: "What's the weather in Boston?",
          tools: [ {
            name: "get_current_weather",
            description: "Get the current weather in a given location",
            parameters: {
              type: "object",
              properties: {
                location: {
                  type: "string",
                  description: "The city and state, e.g. San Francisco, CA"
                },
                unit: {
                  type: "string",
                  enum: [ "celsius", "fahrenheit" ]
                }
              },
              required: [ "location" ]
            }
          } ]
        )
      end

      def get_current_weather(location:, unit: "fahrenheit")
        { location: location, unit: unit, temperature: "22", conditions: "sunny" }
      end
    end
    # endregion tools_weather_agent

    test "OpenAI basic function registration" do
      VCR.use_cassette("docs/actions_examples/tools") do
        response = WeatherAgent.weather_update.generate_now

        assert response.message.content.present?

        doc_example_output(response)
      end
    end
  end

  class McpsExample < ActiveSupport::TestCase
    # region mcps_research_agent
    class ResearchAgent < ApplicationAgent
      generate_with :anthropic, model: "claude-haiku-4-5"

      def research
        prompt(
          message: "Research AI developments",
          mcps: [ { name: "github", url: "https://api.githubcopilot.com/mcp/", authorization: ENV["GITHUB_MCP_TOKEN"] } ]
        )
      end
    end
    # endregion mcps_research_agent

    test "MCP connection" do
      VCR.use_cassette("docs/actions_examples/mcps") do
        response = ResearchAgent.research.generate_now

        assert response.message.content.present?

        doc_example_output(response)
      end
    end
  end

  # region structured_output_extract
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
  # endregion structured_output_extract

  test "json schema with view template" do
    VCR.use_cassette("docs/actions_examples/structured_output") do
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

  test "quick start example" do
    VCR.use_cassette("docs/actions_examples/embeddings_vectorize") do
      # region embeddings_vectorize
      class MyAgent < ApplicationAgent
        embed_with :openai, model: "text-embedding-3-small"

        def vectorize
          embed(input: params[:text])
        end
      end

      response = MyAgent.with(text: "Hello world").vectorize.embed_now
      vector = response.data.first[:embedding]  # => [0.123, -0.456, ...]
      # endregion embeddings_vectorize

      assert_kind_of Array, vector
      assert vector.all? { |v| v.is_a?(Float) }
    end
  end
end
