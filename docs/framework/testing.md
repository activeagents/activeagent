---
title: Testing ActiveAgent Applications
description: Testing strategies for ActiveAgent applications with credential management, VCR integration, and test patterns.
---
# {{ $frontmatter.title }}

Test ActiveAgent applications with credential helpers, VCR for API recording, and proper agent patterns.

## Credential Management

Skip tests gracefully when API credentials aren't available:

```ruby
class MyAgentTest < ActiveSupport::TestCase
  test "generates response with OpenAI" do
    skip "Requires API credentials" unless has_openai_credentials?

    VCR.use_cassette("my_agent_test") do
      result = MyAgent.with(input: "test").process.generate_now
      assert result.message.content.present?
    end
  end
end
```

### Available Helpers

```ruby
has_openai_credentials?       # Rails credentials or ENV vars
has_anthropic_credentials?    # Rails credentials or ENV vars
has_openrouter_credentials?   # Rails credentials or ENV vars
has_ollama_credentials?       # Ollama server configuration
has_provider_credentials?(:openai)  # Generic check
```

### Credential Setup

**Rails credentials** (recommended):
```bash
rails credentials:edit
```

```yaml
openai:
  access_token: your-api-key
anthropic:
  access_token: your-api-key
```

**Environment variables** (fallback):
```bash
export OPENAI_ACCESS_TOKEN=your-api-key
export ANTHROPIC_ACCESS_TOKEN=your-api-key
```

## Testing Agent Actions

Use the `Agent.with(params).action.generate_now` pattern:

```ruby
class MyAgentTest < ActiveSupport::TestCase
  test "processes user input" do
    skip unless has_openai_credentials?

    VCR.use_cassette("my_agent_process") do
      result = MyAgent.with(input: "test data").process.generate_now

      assert result.message.content.present?
      assert_includes result.message.content, "processed"
    end
  end
end
```

### Common Test Patterns

**Basic agent test:**
```ruby
test "support agent responds to help request" do
  VCR.use_cassette("support_agent_help") do
    response = SupportAgent.with(
      user_id: 1,
      message: "Need help"
    ).help.generate_now

    assert response.message.content.present?
    doc_example_output(response)  # Generate docs
  end
end
```

**Testing with custom configuration:**
```ruby
class ConfigurationTest < ActiveAgentTestCase
  test "custom provider settings" do
    custom_config = { "openai" => { "model" => "gpt-4" } }

    with_active_agent_config(custom_config) do
      # Test with custom configuration
    end
  end
end
```

## Testing Concerns

Test that shared functionality is properly included:

```ruby
test "research agent includes concern tools" do
  expected_actions = ["search_papers", "analyze_data"]
  agent_actions = ResearchAgent.new.action_methods

  expected_actions.each do |action|
    assert_includes agent_actions, action
  end
end
```

## Documentation Examples

Generate examples from test results:

```ruby
test "help agent example" do
  VCR.use_cassette("help_agent_example") do
    result = HelpAgent.with(query: "How do I reset password?").help.generate_now

    doc_example_output(result)  # Creates example file
    assert result.message.content.present?
  end
end
```

Include in documentation:
```markdown
::: details Response Example
<!-- @include: @/parts/examples/help-agent-test-help-agent-example.md -->
:::
```

## Testing Multiple Providers

Test across different providers:

```ruby
test "works with different providers" do
  skip unless has_openai_credentials?

  agent_class = Class.new(ApplicationAgent) do
    generate_with :openai, model: "gpt-4o"
    def analyze; prompt message: "test"; end
  end

  result = agent_class.with.analyze.generate_now
  assert result.message.content.present?
end
```

## Common Issues

**Wrong pattern error:**
```ruby
# Wrong - actions don't accept arguments
agent.my_action(param: "value")  # Error!

# Right - use with pattern
MyAgent.with(param: "value").my_action.generate_now
```

**Missing credentials:**
- Set Rails credentials: `rails credentials:edit`
- Export environment variables in shell
- Check credential helper method names

**VCR cassette issues:**
- Delete old cassettes: `rm test/fixtures/vcr_cassettes/test.yml`
- Re-run tests to record new cassettes
- Verify API credentials are valid

## Test Base Classes

- `ActiveSupport::TestCase` - Standard Rails tests with credential helpers
- `ActiveAgentTestCase` - For tests needing configuration management
