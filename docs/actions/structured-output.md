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

```ruby
# Generate schema from model - returns a Ruby hash
user_schema = TestUser.to_json_schema(strict: true, name: "user_extraction")

# In actual usage, the agent would use the hash directly:
# prompt(output_schema: user_schema)
```

### Basic Structured Output Example

Define a schema and use it with the `output_schema` parameter:

```ruby
class DataExtractionAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"

  def extract_data
    prompt(
      message: params[:text],
      output_schema: params[:schema]
    )
  end
end

# Define your schema
user_schema = {
  name: "user_extraction",
  strict: true,
  schema: {
    type: "object",
    properties: {
      name: { type: "string" },
      email: { type: "string" },
      age: { type: "integer" }
    },
    required: ["name", "email", "age"],
    additionalProperties: false
  }
}

# Use the schema
response = DataExtractionAgent.with(
  text: "John Doe, age 30, john@example.com",
  schema: user_schema
).extract_data.generate_now

# Response is automatically parsed
response.message.content # => {"name" => "John Doe", "email" => "john@example.com", "age" => 30}
response.message.content_type # => "application/json"
response.message.raw_content # => '{"name":"John Doe","email":"john@example.com","age":30}'
```

The response will automatically have:
- `content_type` set to `"application/json"`
- `content` parsed as a Ruby Hash
- `raw_content` available as the original JSON string

## Schema Generation

### From ActiveModel

Create schemas from ActiveModel classes with validations:

```ruby
class TestUser
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Validations
  include ActiveAgent::SchemaGenerator

  attribute :name, :string
  attribute :email, :string
  attribute :age, :integer
  attribute :active, :boolean

  validates :name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :age, numericality: { greater_than_or_equal_to: 18 }
end
```

Generate the schema:

```ruby
schema = TestUser.to_json_schema
```

### From ActiveRecord

Generate schemas from database-backed models:

```ruby
schema = User.to_json_schema
```

### Strict Schemas

For providers requiring strict schemas (like OpenAI):

```ruby
schema = TestBlogPost.to_json_schema(strict: true, name: "blog_post_schema")
```

In strict mode:
- All properties are marked as required
- `additionalProperties` is set to false
- The schema is wrapped with name and strict flags

### Excluding Fields

Exclude sensitive or unnecessary fields from schemas:

```ruby
schema = TestBlogPost.to_json_schema(exclude: [ :tags, :published_at ])
```

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

```ruby
class RobustExtractionAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"

  def extract_with_validation
    response = prompt(
      message: params[:text],
      output_schema: params[:schema]
    ).generate_now

    # Validate the parsed JSON
    begin
      data = response.message.content
      validate_schema(data, params[:schema])
      data
    rescue JSON::ParserError => e
      Rails.logger.error "JSON parsing failed: #{e.message}"
      # Fallback to raw content
      response.message.raw_content
    rescue => e
      Rails.logger.error "Validation failed: #{e.message}"
      nil
    end
  end

  private

  def validate_schema(data, schema)
    # Implement your validation logic
    schema[:schema][:required].each do |field|
      raise "Missing required field: #{field}" unless data.key?(field.to_s)
    end
  end
end
```

## Provider Support

Different AI providers have varying levels of structured output support:

- **[OpenAI](/providers/openai-provider#structured-output)** - Native JSON mode with strict schema validation
- **[OpenRouter](/providers/open-router-provider#structured-output-support)** - Support through compatible models, ideal for multimodal tasks
- **[Anthropic](/providers/anthropic-provider#structured-output)** - Instruction-based JSON generation
- **[Ollama](/providers/ollama-provider#structured-output)** - Local model support with JSON mode

## Real-World Examples

### Data Extraction Agent

The [Data Extraction Agent](/examples/data-extraction-agent#structured-output) demonstrates comprehensive structured output usage:

```ruby
prompt = DataExtractionAgent.with(
  output_schema: :chart_schema,
  image_path: sales_chart_path
).parse_content
```

### Integration with Rails Models

Use your existing Rails models for schema generation:

```ruby
class User < ApplicationRecord
  include ActiveAgent::SchemaGenerator

  # ActiveRecord attributes are automatically detected
  # name, email, age from database columns
end

class UserExtractionAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"

  def extract_user
    # Generate schema from the model
    user_schema = User.to_json_schema(strict: true, name: "user_extraction")

    prompt(
      message: params[:text],
      output_schema: user_schema
    )
  end
end

# Extract user data from text
response = UserExtractionAgent.with(
  text: "Contact: Jane Smith, jane@example.com, 28 years old"
).extract_user.generate_now

# Create a User record from the extracted data
user_data = response.message.content
user = User.new(user_data)
user.save! if user.valid?
```

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

- [Data Extraction Agent](/examples/data-extraction-agent) - Complete extraction examples
- [OpenAI Structured Output](/providers/openai-provider#structured-output) - OpenAI implementation details
- [OpenRouter Structured Output](/providers/open-router-provider#structured-output-support) - Multimodal extraction
