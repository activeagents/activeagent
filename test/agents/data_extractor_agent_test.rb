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
    agent = DataExtractorAgent.with(text: @sample_text, analysis_type: "full")

    generation1 = agent.analyze_document
    prompt1 = generation1.context
    assert_equal "Analyze this document: #{@sample_text}", prompt1.message.content
    
    agent_instance = DataExtractorAgent.new
    agent_instance.action_name = "analyze_document"
    all_schemas = agent_instance.send(:action_schemas)
    
    agent2 = DataExtractorAgent.with(text: @sample_text, use_structured_output: true)
    generation2 = agent2.analyze_document
    prompt2 = generation2.context
    assert_equal "Analyze this document: #{@sample_text}", prompt2.message.content
    
    schema2 = prompt2.options[:json_schema]
    assert schema2.present?
    assert_equal "object", schema2["type"], "Should have object type for structured output"
    assert schema2["properties"]["summary"].present?
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
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_resume_data
    prompt = generation.context

    assert_equal @sample_text, prompt.message.content
    assert prompt.options.present?

    schema = prompt.options[:json_schema]
    assert schema.present?, "JSON schema should be present in options"
    assert_equal "object", schema["type"]
    assert schema["properties"]["personal_info"].present?
    assert schema["properties"]["experience"].present?
    assert schema["properties"]["education"].present?
    assert schema["properties"]["skills"].present?
    assert_includes schema["required"], "personal_info"

    provider = DataExtractorAgent.generation_provider
    provider_instance = provider.class.new(provider.config)
    provider_instance.instance_variable_set(:@prompt, prompt)

    params = provider_instance.send(:prompt_parameters)
    assert_equal "json_schema", params[:response_format][:type]
    assert_equal schema, params[:response_format][:json_schema][:schema]
  end

  test "data extractor agent can extract contact info with simple schema" do
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_contact_info
    prompt = generation.context

    assert_equal @sample_text, prompt.message.content

    schema = prompt.options[:json_schema]
    assert schema.present?, "JSON schema should be present in options"
    assert_equal "object", schema["type"]
    assert schema["properties"]["name"].present?
    assert schema["properties"]["email"].present?
    assert schema["properties"]["phone"].present?
    assert schema["properties"]["location"].present?
    assert_includes schema["required"], "name"

    refute schema["properties"]["experience"]
    refute schema["properties"]["education"]
  end

  test "data extractor agent can extract skills with categorization" do
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_skills
    prompt = generation.context

    assert_equal @sample_text, prompt.message.content

    schema = prompt.options[:json_schema]
    assert schema.present?, "JSON schema should be present in options"
    assert_equal "object", schema["type"]
    assert schema["properties"]["technical_skills"].present?
    assert schema["properties"]["soft_skills"].present?
    assert schema["properties"]["certifications"].present?

    assert_equal "array", schema["properties"]["technical_skills"]["type"]
    assert_equal "string", schema["properties"]["technical_skills"]["items"]["type"]
  end

  test "data extractor agent integrates properly with OpenAI provider" do
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_resume_data
    prompt = generation.context

    config = DataExtractorAgent.generation_provider.config.merge({
      "api_key" => "test-key"
    })

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    provider.instance_variable_set(:@prompt, prompt)

    mock_response = {
      "id" => "test-response-id",
      "choices" => [ {
        "message" => {
          "role" => "assistant",
          "content" => '{"personal_info": {"name": "John Smith", "email": "john.smith@email.com"}, "skills": {"programming_languages": ["Ruby", "JavaScript"]}}'
        }
      } ]
    }

    result = provider.send(:chat_response, mock_response)

    assert result.message.content.is_a?(Hash)
    assert_equal "John Smith", result.message.content[:personal_info][:name]
    assert_equal "john.smith@email.com", result.message.content[:personal_info][:email]
    assert_equal [ "Ruby", "JavaScript" ], result.message.content[:skills][:programming_languages]
  end

  test "data extractor agent handles different text inputs" do
    simple_text = "Jane Doe, Software Developer at ABC Company. Email: jane@abc.com, Phone: 555-9876"

    agent = DataExtractorAgent.with(text: simple_text)
    generation = agent.extract_contact_info
    prompt = generation.context

    assert_equal simple_text, prompt.message.content
    assert prompt.options[:json_schema].present?

    schema = prompt.options[:json_schema]
    assert_equal "object", schema["type"]
    assert_includes schema["required"], "name"
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

  test "data extractor agent validates schema structure" do
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_resume_data
    prompt = generation.context

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
  end
end
