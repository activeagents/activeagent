require "test_helper"

class DataExtractorAgentTest < ActiveSupport::TestCase
  def setup
    @sample_text = File.read(File.join(File.dirname(__FILE__), "../fixtures/sample_resume.txt"))
  end

  test "data extractor agent loads JSON schema from views" do
    # Test that the agent can load schemas from JSON views
    agent = DataExtractorAgent.new
    agent.params = {text: @sample_text}

    # Test each action can load its schema from view using the new prompt parameter
    %w[extract_resume_data extract_contact_info extract_skills].each do |action|
      agent.action_name = action

      # Test the load_json_schema_from_view method directly
      schema = agent.send(:load_json_schema_from_view, true)

      assert schema.present?, "Schema should be loaded for action #{action}"
      assert_equal "object", schema["type"], "Schema should be an object for action #{action}"
      assert schema["properties"].present?, "Schema should have properties for action #{action}"

      # puts "✓ Schema loaded for #{action}: #{schema.keys}"
    end
  end

  test "data extractor agent supports different json_schema parameter formats" do
    # Test different ways to specify json_schema parameter
    agent = DataExtractorAgent.new
    agent.params = {text: @sample_text}
    agent.action_name = "extract_resume_data"

    # Test json_schema: true
    schema1 = agent.send(:load_json_schema_from_view, true)
    assert schema1.present?

    # Test json_schema: { template: "extract_resume_data" }
    schema2 = agent.send(:load_json_schema_from_view, {template: "extract_resume_data"})
    assert schema2.present?
    assert_equal schema1, schema2

    # Test json_schema: "extract_resume_data"
    schema3 = agent.send(:load_json_schema_from_view, "extract_resume_data")
    assert schema3.present?
    assert_equal schema1, schema3

    # puts "✓ All json_schema parameter formats work correctly"
  end

  test "data extractor agent demonstrates usage patterns" do
    # Demonstrate different usage patterns for the json_schema parameter
    agent = DataExtractorAgent.with(text: @sample_text)

    # Pattern 1: json_schema: true (loads action_name.json.erb/jbuilder)
    generation1 = agent.extract_resume_data  # Uses json_schema: true internally
    schema1 = generation1.context.options[:json_schema]
    assert schema1.present?

    # Could also be written as:
    # prompt(message: params[:text], json_schema: true)

    # Pattern 2: json_schema: { template: "custom_schema" }
    # This would load custom_schema.json.erb/jbuilder instead
    # generation2 = prompt(message: params[:text], json_schema: { template: "extract_contact_info" })

    # Pattern 3: json_schema: "template_name"
    # This would load template_name.json.erb/jbuilder
    # generation3 = prompt(message: params[:text], json_schema: "extract_skills")

    # puts "✓ All usage patterns demonstrated successfully"
  end

  test "data extractor agent properly sets JSON schema from views in actions" do
    # Test the integration of schema loading within actual agent actions
    agent = DataExtractorAgent.with(text: @sample_text)

    # Test extract_resume_data
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

    # puts "✓ extract_resume_data schema loaded with keys: #{schema["properties"].keys}"
  end

  test "data extractor agent can extract full resume data with structured output" do
    # Test that the agent creates the correct prompt structure
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_resume_data
    prompt = generation.context

    # Verify the prompt has the right message
    assert_equal @sample_text, prompt.message.content
    assert prompt.options.present?

    # Verify the JSON schema structure is in options
    schema = prompt.options[:json_schema]
    assert schema.present?, "JSON schema should be present in options"
    assert_equal "object", schema["type"]
    assert schema["properties"]["personal_info"].present?
    assert schema["properties"]["experience"].present?
    assert schema["properties"]["education"].present?
    assert schema["properties"]["skills"].present?
    assert_includes schema["required"], "personal_info"

    # Test that the provider correctly sets up structured output
    provider = DataExtractorAgent.generation_provider
    provider_instance = provider.class.new(provider.config)
    provider_instance.instance_variable_set(:@prompt, prompt)

    params = provider_instance.send(:prompt_parameters)
    assert_equal "json_schema", params[:response_format][:type]
    assert_equal schema, params[:response_format][:json_schema][:schema]
  end

  test "data extractor agent can extract contact info with simple schema" do
    # Test with a simpler extraction schema
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_contact_info
    prompt = generation.context

    # Verify the prompt structure
    assert_equal @sample_text, prompt.message.content

    # Verify the simpler JSON schema
    schema = prompt.options[:json_schema]
    assert schema.present?, "JSON schema should be present in options"
    assert_equal "object", schema["type"]
    assert schema["properties"]["name"].present?
    assert schema["properties"]["email"].present?
    assert schema["properties"]["phone"].present?
    assert schema["properties"]["location"].present?
    assert_includes schema["required"], "name"

    # Ensure it doesn't include the complex nested structures
    refute schema["properties"]["experience"]
    refute schema["properties"]["education"]
  end

  test "data extractor agent can extract skills with categorization" do
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_skills
    prompt = generation.context

    # Verify the prompt structure
    assert_equal @sample_text, prompt.message.content

    # Verify the skills-focused JSON schema
    schema = prompt.options[:json_schema]
    assert schema.present?, "JSON schema should be present in options"
    assert_equal "object", schema["type"]
    assert schema["properties"]["technical_skills"].present?
    assert schema["properties"]["soft_skills"].present?
    assert schema["properties"]["certifications"].present?

    # Verify array types for skill categories
    assert_equal "array", schema["properties"]["technical_skills"]["type"]
    assert_equal "string", schema["properties"]["technical_skills"]["items"]["type"]
  end

  test "data extractor agent integrates properly with OpenAI provider" do
    # Test full integration with the provider
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_resume_data
    prompt = generation.context

    # Create a mock response that should be parsed as JSON
    config = DataExtractorAgent.generation_provider.config.merge({
      "api_key" => "test-key"
    })

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    provider.instance_variable_set(:@prompt, prompt)

    # Mock a structured response
    mock_response = {
      "id" => "test-response-id",
      "choices" => [{
        "message" => {
          "role" => "assistant",
          "content" => '{"personal_info": {"name": "John Smith", "email": "john.smith@email.com"}, "skills": {"programming_languages": ["Ruby", "JavaScript"]}}'
        }
      }]
    }

    # Test that the provider correctly parses the JSON response
    result = provider.send(:chat_response, mock_response)

    # Verify the content was parsed as structured data
    assert result.message.content.is_a?(Hash)
    assert_equal "John Smith", result.message.content[:personal_info][:name]
    assert_equal "john.smith@email.com", result.message.content[:personal_info][:email]
    assert_equal ["Ruby", "JavaScript"], result.message.content[:skills][:programming_languages]
  end

  test "data extractor agent handles different text inputs" do
    # Test with different input text
    simple_text = "Jane Doe, Software Developer at ABC Company. Email: jane@abc.com, Phone: 555-9876"

    agent = DataExtractorAgent.with(text: simple_text)
    generation = agent.extract_contact_info
    prompt = generation.context

    assert_equal simple_text, prompt.message.content
    assert prompt.options[:json_schema].present?

    # Verify the schema is still properly structured
    schema = prompt.options[:json_schema]
    assert_equal "object", schema["type"]
    assert_includes schema["required"], "name"
  end

  test "data extractor agent prompt includes proper instructions" do
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_resume_data
    prompt = generation.context

    # Check that the agent class has the right instructions
    assert_includes DataExtractorAgent.options[:instructions], "Extract structured data"
    assert_includes DataExtractorAgent.options[:instructions], "JSON format specified"

    # Verify the prompt has messages (including system instructions)
    assert prompt.messages.any? { |msg| msg.role == :system }
    system_message = prompt.messages.find { |msg| msg.role == :system }
    assert_includes system_message.content, "Extract structured data"
  end

  test "data extractor agent uses correct model configuration" do
    # Verify the agent is configured with the right model
    assert_equal "gpt-4o-mini", DataExtractorAgent.options[:model]
    # Check the actual provider class name
    provider_name = DataExtractorAgent.generation_provider.class.name.demodulize.underscore
    assert_equal "open_ai_provider", provider_name
  end

  test "data extractor agent validates schema structure" do
    agent = DataExtractorAgent.with(text: @sample_text)
    generation = agent.extract_resume_data
    prompt = generation.context

    schema = prompt.options[:json_schema]

    # Validate required nested schema properties
    personal_info_props = schema["properties"]["personal_info"]["properties"]
    assert personal_info_props["name"].present?
    assert personal_info_props["email"].present?
    assert personal_info_props["phone"].present?

    # Validate experience array structure
    experience_schema = schema["properties"]["experience"]
    assert_equal "array", experience_schema["type"]
    experience_item = experience_schema["items"]
    assert_equal "object", experience_item["type"]
    assert experience_item["properties"]["company"].present?
    assert experience_item["properties"]["achievements"].present?
    assert_equal "array", experience_item["properties"]["achievements"]["type"]

    # Validate skills structure
    skills_props = schema["properties"]["skills"]["properties"]
    assert skills_props["programming_languages"].present?
    assert skills_props["frameworks"].present?
    assert_equal "array", skills_props["programming_languages"]["type"]
  end
end
