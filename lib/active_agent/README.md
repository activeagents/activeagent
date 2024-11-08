# Active Agent
Active Agent is a Rails framework for creating and managing AI agents. It provides a structured way to interact with generation providers through agents with context including prompts, tools, and messages. It includes two core modules, Generation Provider and Action Prompt, along with several support classes to handle different aspects of agent creation and management.

## Main Components

- Base class - for creating and configuring agents.
- Generation Provider - module for configuring and interacting with generation providers through Prompts and Responses.
- Action Prompt - module for defining prompts, tools, and messages. The Base class implements an AbstractController to render prompts and actions.
- Queued Ge

