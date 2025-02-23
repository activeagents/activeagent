# Active Agent: Action Prompt

ActionPrompt provides a structured way to create and manage prompts and tools for AI interactions. It includes several support classes to handle different aspects of prompt creation and management. The Base class implements an AbstractController to perform actions that render prompts..

## Main Components

Module - for including in your agent classes to provide prompt functionality.
Base class - for creating and managing prompts in ActiveAgent.
Tool class - for representing the tool object sent to the Agent's generation provider.
Message - class for representing a single message within a prompt.
Prompt - class for representing the context of a prompt, including messages, actions, and other attributes.

### ActionPrompt::Base

The base class is used to create and manage prompts in Active Agent. It provides the core functionality for creating and managing contexts with prompts, tools, and messages.

#### Core Methods
`prompt` - Creates a new prompt object with the given attributes.


### ActionPrompt::Tool

### ActionPrompt::Message

Represents a single message within a prompt.

### ActionPrompt::Prompt

Manages the overall structure of a prompt, including multiple messages, actions, and other attributes.

### ActionPrompt::Action

Represents an action that represents the tool object sent to the Agent's generation provider can be associated with a prompt or message.

## Usage

To use ActionPrompt in your agent, include the module in your agent class:

```ruby
class MyAgent
  include ActiveAgent::ActionPrompt
  
  # Your agent code here
end
