<!-- Generated from structured_output_json_parsing_test.rb:69 -->
[activeagent/test/integration/structured_output_json_parsing_test.rb:69](vscode://file//Users/justinbowen/Documents/GitHub/claude-could/activeagent/test/integration/structured_output_json_parsing_test.rb:69)
<!-- Test: test-structured-output-sets-content-type-to-application/json-and-auto-parses-JSON -->

```ruby
# Response object
#<ActiveAgent::GenerationProvider::Response:0x508c
  @message=#<ActiveAgent::ActionPrompt::Message:0x50a0
    @action_id=nil,
    @action_name=nil,
    @action_requested=false,
    @charset="UTF-8",
    @content={"name"=>"John Doe", "age"=>30, "email"=>"john@example.com"},
    @role=:assistant>
  @prompt=#<ActiveAgent::ActionPrompt::Prompt:0x50b4 ...>
  @content_type="application/json"
  @raw_response={...}>

# Message content
response.message.content # => {"name"=>"John Doe", "age"=>30, "email"=>"john@example.com"}
```