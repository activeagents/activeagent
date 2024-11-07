# ActionPrompt

ActionPrompt is a module within the ActiveAgent framework that provides a structured way to create and manage prompts for AI interactions. It includes several support classes to handle different aspects of prompt creation and management.

## Main Components

### ActionPrompt::Base

The main module that can be included in your agent classes. It provides the core functionality for creating and managing prompts.

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
