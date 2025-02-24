# Active Agent: Action Prompt

Action Prompt provides a structured way to create and manage prompts for AI interactions. It enables composing messages, handling actions/tools, and managing conversation context through several key components.

Action Prompt manages the overall prompt structure including:

- Messages list with system/user/assistant roles
- Action/tool definitions
- Headers and context tracking
- Content type and encoding 
- Multipart message handling

```ruby
prompt = ActionPrompt::Prompt.new(
  instructions: "System guidance",
  message: "User input",
  actions: [tool_definition, action_schema],
  context: messages
)
```

## ActionPrompt::Message 

Represents individual messages with:

### Content and Role
```ruby
message = ActionPrompt::Message.new(
  content: "Search for a hotel",
  role: :user
)
```

- Content stores the actual message text
- Role defines the message sender type (system/user/assistant/function/tool)
- Messages form interactions between roles in a Context

### Action Requests and Responses
```ruby
message = ActionPrompt::Message.new(
  content: "Search for a hotel",
  role: :tool,
  requested_actions: [{name: "search", params: {query: "hotel"}}]
)
```

- Tracks if message requests actions/tools
- Maintains list of requested_actions
- Action responses include function call results
- Handles tool execution state

### Content Type and Encoding
- Default content_type is "text/plain"
- Supports multiple content types for rich messages
- Default charset is UTF-8
- Handles content encoding/decoding

### Role Validation
- Enforces valid roles via VALID_ROLES constant
- Validates on message creation
- Raises ArgumentError for invalid roles
- Supported roles: system, assistant, user, tool, function

```ruby
message = ActionPrompt::Message.new(
  content: "Hello",
  role: :user,
  content_type: "text/plain",
  charset: "UTF-8"
)
```

### ActionPrompt::Action

Defines callable tools/functions:

- Name and parameters schema
- Validation and type checking
- Response handling
- Action execution

## Usage with Base Agents

```ruby
class MyAgent < ActiveAgent::Base
  # Define available actions
  def action_schemas
    [
      {name: "search", params: {query: :string}}
    ]
  end

  # Handle action responses
  def perform_action(action) 
    case action.name
    when "search"
      search_service.query(action.params[:query])
    end
  end
end
```

The Base agent integrates with ActionPrompt to:

1. Create prompts with context
2. Register available actions
3. Process action requests
4. Handle responses and update context
5. Manage the conversation flow

See Base.rb for full agent integration details.
