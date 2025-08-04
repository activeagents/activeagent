require "test_helper"

class OptionHierarchyTest < ActiveSupport::TestCase
  def create_test_agent(options = {})
    # Create a fresh agent class for each test to avoid pollution
    Class.new(ApplicationAgent) do
      default_options = { model: "gpt-4", temperature: 0.5, max_tokens: 1000 }
      generate_with :openai, **default_options.merge(options)

      def test_action
        prompt(message: "Test action message")
      end

      def custom_template_action
        prompt(template_path: "support_agent", template_name: "custom_prompt_context")
      end
    end
  end

  test "prompt options override agent options" do
    test_agent_class = create_test_agent
    agent = test_agent_class.new

    prompt = agent.prompt(
      message: "test",
      options: {
        temperature: 0.9,
        model: "gpt-3.5-turbo"
      }
    )

    assert_equal "gpt-3.5-turbo", prompt.options[:model]
    assert_equal 0.9, prompt.options[:temperature]
    assert_equal 1000, prompt.options[:max_tokens] # Should keep agent default
  end

  test "agent options override config options" do
    test_agent_class = create_test_agent
    agent = test_agent_class.new

    # Store original config to restore later
    original_config = test_agent_class.generation_provider.config.dup

    # Mock config to have different temperature
    config = { "temperature" => 0.3, "model" => "gpt-3.5-turbo" }
    test_agent_class.generation_provider.config.merge!(config)

    prompt = agent.prompt(message: "test")

    # Agent options should override config
    assert_equal "gpt-4", prompt.options[:model]
    assert_equal 0.5, prompt.options[:temperature]
    assert_equal 1000, prompt.options[:max_tokens]
  ensure
    # Restore original config to prevent test pollution
    test_agent_class.generation_provider.config.clear
    test_agent_class.generation_provider.config.merge!(original_config)
  end

  test "with method supports runtime options via options parameter" do
    test_agent_class = create_test_agent

    # region runtime_options_with_method
    prompt = test_agent_class.with(
      message: "test",
      options: {
        temperature: 0.8,
        model: "gpt-4o"
      }
    ).prompt_context
    # endregion runtime_options_with_method

    assert_equal "test", prompt.message.content
    assert_equal 0.8, prompt.options[:temperature]
    assert_equal "gpt-4o", prompt.options[:model]
    assert_equal 1000, prompt.options[:max_tokens] # Should keep agent default
  end

  test "explicit options parameter has correct priority" do
    test_agent_class = create_test_agent
    agent = test_agent_class.new

    prompt = agent.prompt(
      message: "test",
      options: { temperature: 0.6, model: "gpt-3.5-turbo" },
    )

    # Direct prompt options should override options parameter
    assert_equal 0.6, prompt.options[:temperature]
    assert_equal "gpt-3.5-turbo", prompt.options[:model] # from options param
  end

  test "template_path can be overridden in prompt method" do
    test_agent_class = create_test_agent
    agent = test_agent_class.new

    # This should work without raising an error about missing template
    prompt = agent.prompt(
      message: "test",
      template_path: "application_agent",
      template_name: "create_test_agent"
    )

    assert_equal "test", prompt.message.content
    assert_not_nil prompt.body
  end

  test "template_path override in action method" do
    test_agent_class = create_test_agent
    agent = test_agent_class.new
    # Test the custom_template_action which overrides template_path
    prompt = agent.custom_template_action

    # Should not raise missing template error
    assert_not_nil prompt
    # Should contain template content
    assert_includes prompt.parts.first.content, "Test template content"
  end

  test "body content is set when using custom body without message" do
    test_agent_class = create_test_agent
    agent = test_agent_class.new

    prompt = agent.prompt(
      body: "Direct body content"
    )

    # When body is provided without message, it should be used directly
    # The body content should be in the parts
    assert_equal 1, prompt.parts.length
    assert_equal "Direct body content", prompt.parts.first.content
  end

  test "action method creates prompt with proper context" do
    test_agent_class = create_test_agent
    agent = test_agent_class.new
    prompt = agent.test_action

    assert_equal "Test action message", prompt.message.content
    assert_not_nil prompt
  end

  test "runtime options are properly extracted in with method" do
    test_agent_class = create_test_agent

    # Test that runtime options are properly separated from regular params
    test_agent_class.with(
      message: "Hello",
      custom_param: "not_a_runtime_option",
      options: {
        temperature: 0.8,
        model: "gpt-4o"
      }
    ).tap do |agent_with_options|
      # Verify params contain both runtime options and regular params
      params = agent_with_options.instance_variable_get(:@params)

      # Runtime options should be in :options key
      assert_equal 0.8, params[:options][:temperature]
      assert_equal "gpt-4o", params[:options][:model]

      # Regular params should still be accessible
      assert_equal "Hello", params[:message]
      assert_equal "not_a_runtime_option", params[:custom_param]
    end
  end

  test "different runtime option types are supported" do
    test_agent_class = create_test_agent

    # region runtime_options_types
    parameterized_agent = test_agent_class.with(
      message: "test",
      options: {
        temperature: 0.8,
        model: "gpt-4o",
        top_p: 0.95,
        frequency_penalty: 0.1,
        presence_penalty: 0.2,
        seed: 12345,
        stop: [ "END" ]
      },
      user: "test-user"
    )

    prompt = parameterized_agent.prompt_context
    # endregion runtime_options_types

    assert_equal 0.95, prompt.options[:top_p]
    assert_equal 0.1, prompt.options[:frequency_penalty]
    assert_equal 0.2, prompt.options[:presence_penalty]
    assert_equal 12345, prompt.options[:seed]
    assert_equal [ "END" ], prompt.options[:stop]
  end

  test "template path and name can be overridden separately" do
    test_agent_class = create_test_agent
    agent = test_agent_class.new

    prompt = agent.prompt(
      template_path: "application_agent",
      template_name: "create_test_agent"
    )

    # Check what the actual content is for debugging
    actual_content = prompt.parts.first.content

    # Should use the specified template
    assert_includes actual_content, "Test agent prompt content"
  end

  test "options hierarchy with explicit options hash" do
    test_agent_class = create_test_agent
    agent = test_agent_class.new

    # region runtime_options_in_prompt
    # Explicit options via :options parameter
    prompt = agent.prompt(
      message: "test",
      options: {
        temperature: 0.6,
        model: "claude-3",
        max_tokens: 2000
      }
    )
    # endregion runtime_options_in_prompt

    assert_equal 0.6, prompt.options[:temperature]  # Direct param wins
    assert_equal "claude-3", prompt.options[:model]  # From options hash
    assert_equal 2000, prompt.options[:max_tokens]  # From options hash
  end

  test "runtime options example output" do
    test_agent_class = create_test_agent

    # Example of using runtime options with the with method
    prompt = test_agent_class.with(
      message: "Translate 'Hello' to Spanish",
      options: {
        temperature: 0.7,
        model: "gpt-4o",
        max_tokens: 100
      }
    ).prompt_context

    doc_example_output({
      prompt_options: prompt.options,
      message: prompt.message.content
    })
    assert_equal "Translate 'Hello' to Spanish", prompt.message.content
    assert_equal 0.7, prompt.options[:temperature]
    assert_equal "gpt-4o", prompt.options[:model]
    assert_equal 100, prompt.options[:max_tokens]
  end
end
