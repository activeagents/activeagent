# Testing ActiveAgent Applications

This guide covers testing strategies and utilities for ActiveAgent applications, including credential management, VCR integration, and test patterns.

## Credential Management

ActiveAgent provides helper methods for checking provider credentials in tests. These helpers check both Rails credentials and environment variables.

### Available Helper Methods

All test classes that inherit from `ActiveSupport::TestCase` have access to these credential helpers:

```ruby
# Check if any provider has credentials
has_provider_credentials?(provider)  # :openai, :anthropic, :open_router, :ollama

# Provider-specific helpers
has_openai_credentials?       # Checks Rails credentials and ENV vars
has_anthropic_credentials?    # Checks Rails credentials and ENV vars
has_openrouter_credentials?   # Checks Rails credentials and ENV vars
has_ollama_credentials?       # Checks for Ollama server configuration
```

### Using Credential Helpers in Tests

Skip tests when credentials aren't available:

```ruby
class MyAgentTest < ActiveSupport::TestCase
  test "generates response with OpenAI" do
    skip "Requires API credentials" unless has_openai_credentials?
    
    # Test implementation
  end
  
  test "uses Anthropic for complex reasoning" do
    skip "Requires API credentials" unless has_anthropic_credentials?
    
    # Test implementation
  end
end
```

### Credential Configuration

Credentials are checked in this order:

1. **Rails Credentials** (Recommended)
   ```bash
   rails credentials:edit
   ```
   
   ```yaml
   openai:
     access_token: your-api-key
   anthropic:
     access_token: your-api-key
   open_router:
     access_token: your-api-key  # or api_key
   ```

2. **Environment Variables** (Fallback)
   ```bash
   export OPENAI_ACCESS_TOKEN=your-api-key
   export OPENAI_API_KEY=your-api-key  # Alternative
   export ANTHROPIC_ACCESS_TOKEN=your-api-key
   export ANTHROPIC_API_KEY=your-api-key  # Alternative
   export OPENROUTER_API_KEY=your-api-key
   ```

## Testing Agent Actions

### The Correct Pattern

ActiveAgent uses a specific pattern for calling agent actions with parameters:

```ruby
# CORRECT: Use the class method 'with' to pass parameters
generation = MyAgent.with(param1: "value1", param2: "value2").action_name
result = generation.generate_now

# INCORRECT: Don't call actions directly with arguments
# agent = MyAgent.new
# result = agent.action_name(param1: "value1")  # This won't work!
```

### Complete Test Example

<<< @/../test/agents/builtin_tools_doc_test.rb#web_search_example{ruby:line-numbers}

### Testing with VCR

Use VCR to record and replay API responses:

```ruby
class MyAgentTest < ActiveSupport::TestCase
  test "performs complex task" do
    skip "Requires API credentials" unless has_openai_credentials?
    
    VCR.use_cassette("my_agent_complex_task") do
      generation = MyAgent.with(
        input: "test data",
        mode: "analysis"
      ).analyze
      
      result = generation.generate_now
      
      assert result.message.content.present?
      assert result.message.content.include?("expected text")
      
      # Generate documentation examples
      doc_example_output(result)
    end
  end
end
```

## Testing Concerns

ActiveAgent supports using concerns to share functionality across agents:

### Creating a Test for a Concern

<<< @/../test/agents/concern_tools_test.rb#10-23{ruby:line-numbers}

### Testing Concern Configuration

<<< @/../test/agents/concern_tools_test.rb#119-124{ruby:line-numbers}

## Generating Documentation Examples

Use the `doc_example_output` method to generate documentation examples from test results:

```ruby
test "example for documentation" do
  VCR.use_cassette("doc_example") do
    generation = MyAgent.with(
      query: "How do I use ActiveAgent?"
    ).help
    
    result = generation.generate_now
    
    # Generate example file in docs/parts/examples/
    doc_example_output(result)
  end
end
```

The generated examples can be included in documentation:

```markdown
::: details Response Example
<!-- @include: @/parts/examples/my-agent-test-example-for-documentation.md -->
:::
```

## Test Helpers

### ActiveAgentTestCase

Use `ActiveAgentTestCase` for tests that need to manage ActiveAgent configuration:

```ruby
class ConfigurationTest < ActiveAgentTestCase
  def test_with_custom_config
    with_active_agent_config(custom_config) do
      # Test with custom configuration
    end
  end
end
```

### Testing Multiple Providers

Test agent behavior across different providers:

```ruby
class MultiProviderTest < ActiveSupport::TestCase
  test "works with OpenAI" do
    skip unless has_openai_credentials?
    
    agent_class = Class.new(ApplicationAgent) do
      generate_with :openai, model: "gpt-4o"
      
      def test_action
        prompt message: "test"
      end
    end
    
    generation = agent_class.with.test_action
    result = generation.generate_now
    assert result.message.content.present?
  end
  
  test "works with Anthropic" do
    skip unless has_anthropic_credentials?
    
    agent_class = Class.new(ApplicationAgent) do
      generate_with :anthropic, model: "claude-3-5-sonnet-latest"
      
      def test_action
        prompt message: "test"
      end
    end
    
    generation = agent_class.with.test_action
    result = generation.generate_now
    assert result.message.content.present?
  end
end
```

## Testing Built-in Tools

When testing agents that use OpenAI's built-in tools (web search, image generation, MCP):

### Web Search Testing

```ruby
test "searches the web for information" do
  skip unless has_openai_credentials?
  
  VCR.use_cassette("web_search_test") do
    generation = WebSearchAgent.with(
      query: "Latest Ruby on Rails features",
      context_size: "high"
    ).search_with_tools
    
    result = generation.generate_now
    assert result.message.content.present?
  end
end
```

### Image Generation Testing

```ruby
test "generates images" do
  skip unless has_openai_credentials?
  
  VCR.use_cassette("image_generation_test") do
    generation = MultimodalAgent.with(
      description: "A peaceful mountain landscape",
      size: "1024x1024",
      quality: "high"
    ).create_image
    
    result = generation.generate_now
    assert result.message.content.present?
  end
end
```

### MCP Integration Testing

```ruby
test "connects to MCP servers" do
  skip unless has_openai_credentials?
  
  VCR.use_cassette("mcp_integration_test") do
    generation = ResearchAgent.with(
      query: "Ruby performance optimization",
      sources: ["github"]
    ).search_with_mcp_sources
    
    result = generation.generate_now
    assert result.message.content.present?
  end
end
```

## Best Practices

1. **Always use credential helpers** - Skip tests gracefully when credentials aren't available
2. **Use VCR for API calls** - Record responses for consistent, fast tests
3. **Follow the ActiveAgent pattern** - Use `Agent.with(params).action.generate_now`
4. **Generate documentation examples** - Use `doc_example_output` for real examples
5. **Test concerns separately** - Ensure shared functionality works correctly
6. **Clean up VCR cassettes** - Remove old cassettes when updating test implementations
7. **Test error handling** - Ensure agents handle API errors gracefully

## Common Issues

### Wrong Pattern Errors

If you see `wrong number of arguments` errors, you're likely calling actions incorrectly:

```ruby
# WRONG - Actions don't accept arguments directly
agent = MyAgent.new
agent.my_action(param: "value")  # Error!

# RIGHT - Use the with pattern
MyAgent.with(param: "value").my_action.generate_now
```

### Missing Credentials

If tests are skipped unexpectedly, check:

1. Rails credentials are properly set: `rails credentials:edit`
2. Environment variables are exported in your shell
3. The credential helper is checking the right keys

### VCR Cassette Issues

If tests fail with API errors when cassettes exist:

1. Delete old cassettes: `rm test/fixtures/vcr_cassettes/your_test.yml`
2. Re-run tests to record new cassettes
3. Ensure API credentials are valid

## Related Documentation

- [Getting Started](/docs/getting-started)
- [ActiveAgent Framework](/docs/framework/active-agent)
- [Generation Providers](/docs/framework/generation-provider)