<!-- Generated from structured_output_json_parsing_test.rb:69 -->
[activeagent/test/integration/structured_output_json_parsing_test.rb:69](vscode://file//Users/sarbadajaiswal/development/Justin/activeagents/activeagent/test/integration/structured_output_json_parsing_test.rb:69)
<!-- Test: test-structured-output-sets-content-type-to-application/json-and-auto-parses-JSON -->

```ruby
# Response object
#<ActiveAgent::GenerationProvider::Response:0x22a8
  @message=#<ActiveAgent::ActionPrompt::Message:0x22b0
    @action_id=nil,
    @action_name=nil,
    @action_requested=false,
    @charset="UTF-8",
    @content={"name" => "John Doe", "age" => 30, "email" => "john@example.com"},
    @role=:assistant>
  @prompt=#<ActiveAgent::ActionPrompt::Prompt:0x22b8 ...>
  @content_type="application/json"
  @raw_response={...}>

# Message content
response.message.content # => {"name" => "John Doe", "age" => 30, "email" => "john@example.com"}
```