require "test_helper"

class DataExtractorAgentTest < ActiveSupport::TestCase
  def setup
    @sample_text = File.read(File.join(File.dirname(__FILE__), "../fixtures/sample_resume.txt"))
  end

  test "data extractor agent loads structured output schema from views" do
    # Test that the agent can load schemas from JSON views
    agent = DataExtractorAgent.new
    agent.params = { text: @sample_text }

    # Test each action can load its schema from view using the new prompt parameter
    %w[extract_resume_data_schema extract_contact_info_schema extract_skills_schema].each do |template_name|
      # Test the load_structured_output_schema_from_view method directly
      schema = agent.send(:load_structured_output_schema_from_view, template_name)

      assert schema.present?, "Schema should be loaded for template #{template_name}"
      assert_equal "object", schema["type"], "Schema should be an object for template #{template_name}"
      assert schema["properties"].present?, "Schema should have properties for template #{template_name}"
    end
  end

  test "data extractor agent supports different structured_output parameter formats" do
    agent = DataExtractorAgent.new
    agent.params = { text: @sample_text }
    agent.action_name = "extract_resume_data"


    schema1 = agent.send(:load_structured_output_schema_from_view, { template: "extract_resume_data_schema" })
    assert schema1.present?


    schema2 = agent.send(:load_structured_output_schema_from_view, "extract_resume_data_schema")
    assert schema2.present?
    assert_equal schema1, schema2
  end

  test "data extractor agent demonstrates usage patterns" do
    agent = DataExtractorAgent.with(text: @sample_text)

    generation1 = agent.extract_resume_data
    schema1 = generation1.context.options[:json_schema]
    assert schema1.present?
  end

  test "data extractor agent action can serve both as tool and structured output" do
    agent = DataExtractorAgent.new
    agent.params = { text: @sample_text }
    agent.action_name = "analyze_document"

    tool_schema = agent.send(:load_structured_output_schema_from_view, "analyze_document")
    assert tool_schema.present?
    assert_equal "function", tool_schema["type"]
    assert tool_schema["function"]["name"].present?
    assert tool_schema["function"]["description"].present?
    assert tool_schema["function"]["parameters"]["properties"]["text"].present?
    assert_includes tool_schema["function"]["parameters"]["required"], "text"

    output_schema = agent.send(:load_structured_output_schema_from_view, "analyze_document_output")
    assert output_schema.present?
    assert_equal "object", output_schema["type"]
    assert output_schema["properties"]["summary"].present?
    assert output_schema["properties"]["key_topics"].present?
    assert output_schema["properties"]["sentiment"].present?
    assert_includes output_schema["required"], "summary"
  end

  test "data extractor agent analyze_document action works in both modes" do
    VCR.use_cassette("data_extractor_agent_analyze_document_regular") do
      agent = DataExtractorAgent.with(text: @sample_text, analysis_type: "full")
      generation1 = agent.analyze_document
      response1 = generation1.generate_now

      assert response1.message.content.is_a?(String)
      assert response1.message.content.length > 0
    end

    VCR.use_cassette("data_extractor_agent_analyze_document_structured") do
      agent2 = DataExtractorAgent.with(text: @sample_text, use_structured_output: true)
      generation2 = agent2.analyze_document
      response2 = generation2.generate_now

      assert response2.message.content.is_a?(Hash)
      assert response2.message.content[:summary].present?
      assert response2.message.content[:key_topics].present?
    end
  end

  test "data extractor agent demonstrates complete refactoring" do
    agent = DataExtractorAgent.with(text: "Test document")

    result = agent.extract_resume_data
    assert result.context.options[:json_schema].present?
    assert_equal "object", result.context.options[:json_schema]["type"]

    tool_result = agent.analyze_document
    structured_result = DataExtractorAgent.with(text: "Test document", use_structured_output: true).analyze_document

    assert structured_result.context.options[:json_schema].present?
    assert_equal "object", structured_result.context.options[:json_schema]["type"]
  end

  test "data extractor agent properly sets JSON schema from views in actions" do
    agent = DataExtractorAgent.with(text: @sample_text)

    generation = agent.extract_resume_data
    prompt = generation.context

    assert_equal @sample_text, prompt.message.content
    schema = prompt.options[:json_schema]
    assert schema.present?, "JSON schema should be loaded from view and set in options"
    assert_equal "object", schema["type"]
    assert schema["properties"]["personal_info"].present?
    assert schema["properties"]["experience"].present?
    assert schema["properties"]["education"].present?
    assert schema["properties"]["skills"].present?
    assert_includes schema["required"], "personal_info"
  end

  test "data extractor agent can extract full resume data with structured output" do
    VCR.use_cassette("data_extractor_agent_full_resume_extraction") do
      agent = DataExtractorAgent.with(text: @sample_text)
      generation = agent.extract_resume_data
      response = generation.generate_now

      assert response.message.content.is_a?(Hash)

      # Test personal info extraction
      personal_info = response.message.content[:personal_info]
      assert personal_info.present?
      assert_includes personal_info[:name], "John"
      assert_includes personal_info[:email], "john.smith@email.com"
      assert_includes personal_info[:phone], "555"

      # Test experience extraction
      experience = response.message.content[:experience]
      assert experience.present?
      assert experience.is_a?(Array)
      assert experience.length > 0

      # Test skills extraction
      skills = response.message.content[:skills]
      assert skills.present?
      assert skills[:programming_languages].present? if skills[:programming_languages]
    end
  end

  test "data extractor agent can extract contact info with simple schema" do
    VCR.use_cassette("data_extractor_agent_contact_info_extraction") do
      agent = DataExtractorAgent.with(text: @sample_text)
      generation = agent.extract_contact_info
      response = generation.generate_now

      assert response.message.content.is_a?(Hash)

      contact_info = response.message.content
      assert contact_info[:name].present?
      assert contact_info[:email].present?
      assert contact_info[:phone].present?
      assert contact_info[:location].present?

      # Verify extracted values match the sample resume
      assert_includes contact_info[:name], "John"
      assert_includes contact_info[:email], "john.smith@email.com"
      assert_includes contact_info[:phone], "555"
      assert_includes contact_info[:location], "San Francisco"
    end
  end

  test "data extractor agent can extract skills with categorization" do
    VCR.use_cassette("data_extractor_agent_skills_extraction") do
      agent = DataExtractorAgent.with(text: @sample_text)
      generation = agent.extract_skills
      response = generation.generate_now

      assert response.message.content.is_a?(Hash)

      skills = response.message.content
      assert skills[:technical_skills].present?
      assert skills[:technical_skills].is_a?(Array)

      # Check that technical skills include programming languages from the resume
      technical_skills = skills[:technical_skills]
      has_relevant_skills = technical_skills.any? { |skill|
        skill.downcase.include?("ruby") ||
        skill.downcase.include?("rails") ||
        skill.downcase.include?("javascript") ||
        skill.downcase.include?("node")
      }
      assert has_relevant_skills, "Should extract relevant technical skills from resume"
    end
  end

  test "data extractor agent integrates properly with OpenAI provider" do
    VCR.use_cassette("data_extractor_agent_resume_extraction") do
      agent = DataExtractorAgent.with(text: @sample_text)
      generation = agent.extract_resume_data
      response = generation.generate_now

      assert response.message.content.is_a?(Hash)
      assert response.message.content[:personal_info].present?
      assert response.message.content[:personal_info][:name].present?
      assert response.message.content[:personal_info][:email].present?
      assert response.message.content[:experience].present?
      assert response.message.content[:skills].present?
    end
  end

  test "data extractor agent handles different text inputs" do
    VCR.use_cassette("data_extractor_agent_contact_extraction") do
      simple_text = "Jane Doe, Software Developer at ABC Company. Email: jane@abc.com, Phone: 555-9876"

      agent = DataExtractorAgent.with(text: simple_text)
      generation = agent.extract_contact_info
      response = generation.generate_now

      assert response.message.content.is_a?(Hash)
      assert response.message.content[:name].present?
      assert response.message.content[:email].present?

      # Verify the actual extracted content
      assert_includes response.message.content[:name], "Jane"
      assert_includes response.message.content[:email], "jane@abc.com"
    end
  end

  test "data extractor agent prompt includes proper instructions" do
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_resume_data
    prompt = generation.context

    assert_includes DataExtractorAgent.options[:instructions], "Extract structured data"
    assert_includes DataExtractorAgent.options[:instructions], "JSON format specified"

    assert prompt.messages.any? { |msg| msg.role == :system }
    system_message = prompt.messages.find { |msg| msg.role == :system }
    assert_includes system_message.content, "Extract structured data"
  end

  test "data extractor agent uses correct model configuration" do
    assert_equal "gpt-4o-mini", DataExtractorAgent.options[:model]
    provider_name = DataExtractorAgent.generation_provider.class.name.demodulize.underscore
    assert_equal "open_ai_provider", provider_name
  end

  test "data extractor agent end-to-end structured output integration" do
    VCR.use_cassette("data_extractor_agent_end_to_end") do
      # Test multiple extraction types in sequence
      agent = DataExtractorAgent.with(text: @sample_text)

      # Test resume data extraction
      resume_response = agent.extract_resume_data.generate_now
      assert resume_response.message.content.is_a?(Hash)
      assert resume_response.message.content[:personal_info].present?
      assert resume_response.message.content[:experience].present?

      # Test contact info extraction
      contact_response = agent.extract_contact_info.generate_now
      assert contact_response.message.content.is_a?(Hash)
      assert contact_response.message.content[:name].present?
      assert contact_response.message.content[:email].present?

      # Test skills extraction
      skills_response = agent.extract_skills.generate_now
      assert skills_response.message.content.is_a?(Hash)
      assert skills_response.message.content[:technical_skills].present?

      # Verify all responses contain structured data, not plain text
      [ resume_response, contact_response, skills_response ].each do |response|
        refute response.message.content.is_a?(String), "Response should be structured JSON, not plain text"
      end
    end
  end

  test "data extractor agent validates schema structure and API integration" do
    VCR.use_cassette("data_extractor_agent_schema_validation") do
      agent = DataExtractorAgent.with(text: @sample_text)
      generation = agent.extract_resume_data
      prompt = generation.context

      # Test schema structure
      schema = prompt.options[:json_schema]
      personal_info_props = schema["properties"]["personal_info"]["properties"]
      assert personal_info_props["name"].present?
      assert personal_info_props["email"].present?
      assert personal_info_props["phone"].present?

      experience_schema = schema["properties"]["experience"]
      assert_equal "array", experience_schema["type"]
      experience_item = experience_schema["items"]
      assert_equal "object", experience_item["type"]
      assert experience_item["properties"]["company"].present?
      assert experience_item["properties"]["achievements"].present?
      assert_equal "array", experience_item["properties"]["achievements"]["type"]

      skills_props = schema["properties"]["skills"]["properties"]
      assert skills_props["programming_languages"].present?
      assert skills_props["frameworks"].present?
      assert_equal "array", skills_props["programming_languages"]["type"]

      # Test actual API integration
      response = generation.generate_now
      assert response.message.content.is_a?(Hash)
      assert response.message.content[:personal_info].present?
      assert response.message.content[:experience].present?
      assert response.message.content[:skills].present?
    end
  end
end
