<!-- Generated from structured_output_json_parsing_test.rb:151 -->
[activeagent/test/integration/structured_output_json_parsing_test.rb:151](vscode://file//Users/zane/Documents/Projects/quiltt/activeagent/test/integration/structured_output_json_parsing_test.rb:151)
<!-- Test: test-without-structured-output-uses-text/plain-content-type -->

```ruby
# Response object
#<ActiveAgent::GenerationProvider::Response:0x17f0
  @message=#<ActiveAgent::ActionPrompt::Message:0x17f8
    @action_id=nil,
    @action_name=nil,
    @action_requested=false,
    @charset="UTF-8",
    @content="The capital of France is Paris.",
    @role=:assistant>
  @prompt=#<ActiveAgent::ActionPrompt::Prompt:0x1800 ...>
  @content_type="text/plain"
  @raw_response={...}>

# Message content
response.message.content # => "The capital of France is Paris."
```