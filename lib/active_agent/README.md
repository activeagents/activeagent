# Active Agent
Active Agent is a Rails framework for creating and managing AI agents. It provides a structured way to interact with generation providers through agents with context including prompts, tools, and messages. It includes two core modules, Generation Provider and Action Prompt, along with several support classes to handle different aspects of agent creation and management.

## Core Modules

- Generation Provider - module for configuring and interacting with generation providers through Prompts and Responses.
- Action Prompt - module for defining prompts, tools, and messages. The Base class implements an AbstractController to render prompts and actions. Prompts are Action Views that provide instructions for the agent to generate content, formatted messages for the agent and users including **streaming generative UI**.

## Main Components

- Base class - for creating and configuring agents.
- Queued Generation - module for managing queued generation requests and responses. Using the Generation Job class to perform asynchronous generation requests, it provides a way to **stream generation** requests back to the Job, Agent, or User.

### ActiveAgent::Base

The Base class is used to create agents that interact with generation providers through prompts and messages. It includes methods for configuring and interacting with generation providers using Prompts and Responses. The Base class also provides a structured way to render prompts and actions.

#### Core Methods

- `generate_with(provider, options = {})` - Configures the agent to generate content using the specified generation provider and options.
- `streams_with(provider, options = {})` - Configures the agent to stream content using the specified generation provider's stream option.
