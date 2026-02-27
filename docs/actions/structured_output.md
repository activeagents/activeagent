---
title: Structured Output
description: Control JSON responses from AI models with json_object for simple output or json_schema for validated structured data.
---
# {{ $frontmatter.title }}

Control JSON responses from AI models with `json_object` (simple) or `json_schema` (validated).

Default: agents return plain text or markdown. Use `response_format` for JSON output. See [Messages](/actions/messages) for general prompt parameters and [Agents](/agents) for the complete agent lifecycle.

## Response Format Types

Two JSON response formats:

- **`json_object`** - Valid JSON without schema enforcement
- **`json_schema`** - Schema-validated JSON output

## Provider Support

| Provider       | `json_object` | `json_schema` | Notes |
|:---------------|:-------------:|:-------------:|:------|
| **OpenAI**     | 🟩            | 🟩             | Native support with strict mode (Responses API only for json_schema) |
| **Anthropic**  | 🟦            | ❌             | Emulated via prompt engineering technique |
| **OpenRouter** | 🟩            | 🟩             | Native support, depends on underlying model |
| **Ollama**     | 🟨            | 🟨             | Model-dependent, support varies by model |
| **RubyLLM**    | 🟨            | 🟨             | Depends on underlying provider/model |
| **Mock**       | 🟩            | 🟩             | Accepted but not validated or enforced |

## JSON Object Mode

Valid JSON without strict schema validation.

### Basic Usage

<<< @/../test/docs/actions/structured_output_examples_test.rb#basic_json_object_agent {ruby:line-numbers}

<<< @/../test/docs/actions/structured_output_examples_test.rb#basic_json_object_usage {ruby:line-numbers}

### Parsing JSON Objects

Use `.parsed_json` (or aliases `.json_object` / `.parse_json`) to extract and parse JSON from responses:

<<< @/../test/docs/actions/structured_output_examples_test.rb#json_object_parsing {ruby:line-numbers}

The method automatically:
- Finds the first `{` or `[` in the content
- Extracts JSON between opening and closing brackets
- Parses and transforms keys as specified
- Returns `nil` if parsing fails

### Emulated Support (Anthropic)

Anthropic doesn't natively support JSON mode. ActiveAgent emulates it by:

1. Prepending `"Here is the JSON requested:\n{"` to prime Claude
2. Receiving Claude's continuation
3. Reconstructing complete JSON
4. Removing the lead-in from message history

<<< @/../test/docs/actions/structured_output_examples_test.rb#anthropic_json_agent {ruby:line-numbers}

**Best practices for emulated mode:**
- Be explicit in prompts: "return a JSON object"
- Describe expected structure
- Validate output in production code

## JSON Schema Mode

Guaranteed schema conformance with automatic validation.

### Using Schema Views

Reference schema files from your agent's view directory:

::: code-group
<<< @/../test/docs/actions/structured_output_examples_test.rb#json_schema_with_view_agent {ruby:line-numbers} [data_extract_agent.rb]
<<< @/../test/dummy/app/views/agents/docs/actions/structured_output_examples/data_extraction/parse_resume.json {json:line-numbers} [data_extraction/parse_resume.json]
:::

### Schema Loading

Schemas are loaded from standard view paths as `{action_name}.json`:

1. **Action-specific**: `views/agents/{agent}/{action}.json`
2. **Custom named**: `views/agents/{agent}/{custom_name}.json`

When `response_format: :json_schema`, it loads `{action_name}.json` by default.

### Named Schemas

Share schemas across multiple actions by referencing schema files by name:

<<< @/../test/docs/actions/structured_output_examples_test.rb#named_json_schema_agent {ruby:line-numbers}

Place shared schemas at the agent level (e.g., `views/agents/my_agent/colors.json`) and reference them from any action. Use this pattern for:
- Reusing schemas across multiple actions in the same agent
- Organizing related schemas in one location
- Maintaining consistency across agent methods

### Inline Schema Definition

Pass schemas directly via `response_format`:

<<< @/../test/docs/actions/structured_output_examples_test.rb#inline_json_schema_agent {json:line-numbers}

## Schema Generation

Generate schemas from Ruby models for consistency and reusability.

### From ActiveModel

<<< @/../test/docs/actions/structured_output_examples_test.rb#user_model_with_schema {ruby:line-numbers}

<<< @/../test/docs/actions/structured_output_examples_test.rb#generate_schema_activemodel {ruby:line-numbers}

### From ActiveRecord

```ruby
class BlogPost < ApplicationRecord
  include ActiveAgent::SchemaGenerator
end

schema = BlogPost.to_json_schema(
  strict: true,
  name: "blog_post",
  exclude: [:created_at, :updated_at]  # Omit timestamps
)
```

Columns and validations are automatically detected.

### Using Generated Schemas

Integrate generated schemas into agents:

<<< @/../test/docs/actions/structured_output_examples_test.rb#extraction_agent_with_model {ruby:line-numbers}

## Troubleshooting

**Invalid JSON** - Check provider support table above. Verify model compatibility and valid JSON Schema.

**Missing fields** - Use `strict: true` mode. Add validations to your model.

**Type mismatches** - Match schema types to provider capabilities. Test with actual responses.

## See Also

- [Data Extraction Agent Example](/examples/data_extraction_agent)
- [Actions & Prompts](/actions/messages)
- [OpenAI Provider](/providers/open_ai)
- [OpenRouter Provider](/providers/open_router)
- [Anthropic Provider](/providers/anthropic)
