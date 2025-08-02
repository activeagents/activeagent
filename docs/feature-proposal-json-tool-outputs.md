# Feature Proposal: JSON Tool Outputs for Actions

## Overview

Currently, ActiveAgent supports JSON output through `output_schema` for generation providers, but actions that render tool JSON schemas with tool output schemas are not yet supported. This proposal outlines how this feature could work from a developer API perspective.

## Current State

- Actions can render prompts with various formats (text, html, json)
- Generation providers support `output_schema` for structured JSON responses
- Tools/functions are defined in the agent but don't have a way to specify output schemas for their JSON responses

## Proposed Feature

### 1. Action Definition with Tool Output Schema

```ruby
class TravelAgent < ApplicationAgent
  # Define a tool with output schema
  def book
    prompt(
      message: params[:message], 
      content_type: :json,
      template: "travel_agent/book",
      tool_output_schema: {
        type: "object",
        properties: {
          booking_id: { type: "string" },
          status: { type: "string", enum: ["confirmed", "pending", "failed"] },
          price: { type: "number" },
          details: {
            type: "object",
            properties: {
              flight: { type: "string" },
              hotel: { type: "string" },
              dates: {
                type: "object",
                properties: {
                  check_in: { type: "string", format: "date" },
                  check_out: { type: "string", format: "date" }
                }
              }
            }
          }
        },
        required: ["booking_id", "status", "price"]
      }
    )
  end
end
```

### 2. Template Support

The JSON template would need to conform to the defined schema:

```erb
<%# app/views/travel_agent/book.json.erb %>
{
  "booking_id": "<%= @prompt.booking_id %>",
  "status": "<%= @prompt.status %>",
  "price": <%= @prompt.price %>,
  "details": {
    "flight": "<%= @prompt.flight_number %>",
    "hotel": "<%= @prompt.hotel_name %>",
    "dates": {
      "check_in": "<%= @prompt.check_in_date %>",
      "check_out": "<%= @prompt.check_out_date %>"
    }
  }
}
```

### 3. ActionPrompt::Base Changes

The `prompt` method in `ActionPrompt::Base` would need to be updated to:

1. Accept `tool_output_schema` parameter
2. Validate the rendered JSON against the schema
3. Include the schema in the tool definition sent to the generation provider

```ruby
# lib/active_agent/action_prompt/base.rb
def prompt(message: nil, context: {}, content_type: nil, template: nil, tool_output_schema: nil)
  # ... existing code ...
  
  if tool_output_schema && content_type == :json
    # Register this action as a tool with output schema
    register_tool_with_schema(action_name, tool_output_schema)
    
    # Validate rendered output against schema
    validate_json_output(rendered_content, tool_output_schema)
  end
  
  # ... rest of implementation ...
end
```

### 4. Tool Registration

Tools would be automatically registered with their schemas:

```ruby
class ApplicationAgent < ActiveAgent::Base
  def self.tools
    @tools ||= actions.map do |action|
      if action.tool_output_schema
        {
          type: "function",
          function: {
            name: action.name,
            description: action.description,
            parameters: action.input_schema,
            output: action.tool_output_schema  # New field
          }
        }
      else
        # Existing tool definition without output schema
      end
    end
  end
end
```

## Benefits

1. **Type Safety**: Ensures tool outputs conform to expected schemas
2. **Better AI Integration**: Generation providers can understand what format to expect from tools
3. **Developer Experience**: Clear contract for what each tool returns
4. **Documentation**: Tool output schemas serve as documentation

## Implementation Considerations

1. **Schema Validation**: Need to add JSON Schema validation for tool outputs
2. **Error Handling**: What happens when output doesn't match schema?
3. **Backwards Compatibility**: Ensure existing tools without output schemas continue to work
4. **Generation Provider Support**: Different providers may handle tool output schemas differently

## Example Use Cases

### 1. E-commerce Order Processing
```ruby
def process_order
  prompt(
    message: params[:order_details],
    content_type: :json,
    tool_output_schema: {
      type: "object",
      properties: {
        order_id: { type: "string" },
        total: { type: "number" },
        items: {
          type: "array",
          items: {
            type: "object",
            properties: {
              sku: { type: "string" },
              quantity: { type: "integer" },
              price: { type: "number" }
            }
          }
        }
      }
    }
  )
end
```

### 2. Data Analysis Results
```ruby
def analyze_data
  prompt(
    message: params[:query],
    content_type: :json,
    tool_output_schema: {
      type: "object",
      properties: {
        summary: { type: "string" },
        metrics: {
          type: "object",
          properties: {
            mean: { type: "number" },
            median: { type: "number" },
            std_dev: { type: "number" }
          }
        },
        chart_data: {
          type: "array",
          items: {
            type: "object",
            properties: {
              x: { type: "number" },
              y: { type: "number" }
            }
          }
        }
      }
    }
  )
end
```

## Next Steps

1. Prototype the changes to `ActionPrompt::Base`
2. Add JSON Schema validation library dependency
3. Update generation provider integrations to support tool output schemas
4. Create comprehensive test suite
5. Update documentation and examples

## Questions for Discussion

1. Should we enforce schema validation or make it optional?
2. How should we handle schema validation errors during development vs production?
3. Should tool output schemas be defined at the class level or action level?
4. Do we need to support schema references ($ref) for complex schemas?