# Structured Output

Structured output allows agents to return responses in a predefined JSON format, ensuring consistent and reliable data extraction. ActiveAgent provides comprehensive support for structured output through JSON schemas and automatic model schema generation.

## Overview

Structured output ensures AI responses conform to a specific JSON schema, making it ideal for:
- Data extraction from unstructured text, images, and documents
- API integrations requiring consistent response formats
- Form processing and validation
- Database record creation from natural language

## Key Features

### Automatic JSON Parsing
When using structured output, responses are automatically:
- Tagged with `content_type: "application/json"`
- Parsed from JSON strings to Ruby hashes
- Validated against the provided schema

### Schema Generator
ActiveAgent includes a `SchemaGenerator` module that creates JSON schemas from:
- ActiveRecord models with database columns and validations
- ActiveModel classes with attributes and validations
- Custom Ruby classes with the module included

## Quick Start

### Using Model Schema Generation

ActiveAgent can automatically generate schemas from your Rails models:

<<< @/../test/schema_generator_test.rb#agent_using_schema {ruby:line-numbers}

### Basic Structured Output Example

Define a schema and use it with the `output_schema` parameter:

<<< @/../test/integration/structured_output_json_parsing_test.rb#34-70{ruby:line-numbers}

The response will automatically have:
- `content_type` set to `"application/json"`
- `content` parsed as a Ruby Hash
- `raw_content` available as the original JSON string

## Schema Generation

### From ActiveModel

Create schemas from ActiveModel classes with validations:

<<< @/../test/schema_generator_test.rb#basic_user_model {ruby:line-numbers}

Generate the schema:

<<< @/../test/schema_generator_test.rb#basic_schema_generation {ruby:line-numbers}

### From ActiveRecord

Generate schemas from database-backed models:

<<< @/../test/schema_generator_test.rb#activerecord_schema_generation {ruby:line-numbers}

### Strict Schemas

For providers requiring strict schemas (like OpenAI):

<<< @/../test/schema_generator_test.rb#strict_schema_generation {ruby:line-numbers}

In strict mode:
- All properties are marked as required
- `additionalProperties` is set to false
- The schema is wrapped with name and strict flags

### Excluding Fields

Exclude sensitive or unnecessary fields from schemas:

<<< @/../test/schema_generator_test.rb#schema_with_exclusions {ruby:line-numbers}

## JSON Response Handling

### Automatic Parsing

With structured output, responses are automatically parsed:

```ruby
# Without structured output
response = agent.prompt(message: "Hello").generate_now
response.message.content # => "Hello! How can I help?"
response.message.content_type # => "text/plain"

# With structured output
response = agent.prompt(
  message: "Extract user data",
  output_schema: schema
).generate_now
response.message.content # => { "name" => "John", "age" => 30 }
response.message.content_type # => "application/json"
response.message.raw_content # => '{"name":"John","age":30}'
```

### Error Handling

Handle JSON parsing errors gracefully:

<<< @/../test/integration/structured_output_json_parsing_test.rb#155-169{ruby:line-numbers}

## Provider Support

Different AI providers have varying levels of structured output support:

- **[OpenAI](/docs/generation-providers/openai-provider#structured-output)** - Native JSON mode with strict schema validation
- **[OpenRouter](/docs/generation-providers/open-router-provider#structured-output-support)** - Support through compatible models, ideal for multimodal tasks
- **[Anthropic](/docs/generation-providers/anthropic-provider#structured-output)** - Instruction-based JSON generation
- **[Ollama](/docs/generation-providers/ollama-provider#structured-output)** - Local model support with JSON mode

## Real-World Examples

### Data Extraction Agent

The [Data Extraction Agent](/docs/agents/data-extraction-agent#structured-output) demonstrates comprehensive structured output usage:

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart_with_structured_output {ruby:line-numbers}

### Integration with Rails Models

Use your existing Rails models for schema generation:

<<< @/../test/integration/structured_output_json_parsing_test.rb#110-137{ruby:line-numbers}

## Best Practices

### 1. Use Model Schemas
Leverage ActiveRecord/ActiveModel for single source of truth:

```ruby
class User < ApplicationRecord
  include ActiveAgent::SchemaGenerator
  
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :age, numericality: { greater_than: 18 }
end

# In your agent
schema = User.to_json_schema(strict: true, name: "user_data")
prompt(output_schema: schema)
```

### 2. Schema Design
- Keep schemas focused and minimal
- Use strict mode for critical data
- Include validation constraints
- Provide clear descriptions for complex fields

### 3. Testing
Always test structured output with real providers:

```ruby
test "extracts data with correct schema" do
  VCR.use_cassette("structured_extraction") do
    response = agent.extract_data.generate_now
    
    assert_equal "application/json", response.message.content_type
    assert response.message.content.is_a?(Hash)
    assert_valid_schema response.message.content, expected_schema
  end
end
```

## Migration Guide

### From Manual JSON Parsing

Before:
```ruby
response = agent.prompt(message: "Extract data as JSON").generate_now
data = JSON.parse(response.message.content) rescue {}
```

After:
```ruby
response = agent.prompt(
  message: "Extract data",
  output_schema: MyModel.to_json_schema(strict: true)
).generate_now
data = response.message.content # Already parsed!
```

### From Custom Schemas

Before:
```ruby
schema = {
  type: "object",
  properties: {
    name: { type: "string" },
    age: { type: "integer" }
  }
}
```

After:
```ruby
class ExtractedUser
  include ActiveModel::Model
  include ActiveAgent::SchemaGenerator
  
  attribute :name, :string
  attribute :age, :integer
end

schema = ExtractedUser.to_json_schema(strict: true)
```

## Troubleshooting

### Common Issues

**Invalid JSON Response**
- Ensure provider supports structured output
- Check model compatibility
- Verify schema is valid JSON Schema

**Missing Fields**
- Use strict mode to require all fields
- Add validation constraints to model
- Check provider documentation for limitations

**Type Mismatches**
- Ensure schema types match provider capabilities
- Use appropriate type coercion in models
- Test with actual provider responses

## See Also

- [Data Extraction Agent](/docs/agents/data-extraction-agent) - Complete extraction examples
- [OpenAI Structured Output](/docs/generation-providers/openai-provider#structured-output) - OpenAI implementation details
- [OpenRouter Structured Output](/docs/generation-providers/open-router-provider#structured-output-support) - Multimodal extraction