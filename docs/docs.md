---
title: Active Agent
model:
  - title: Context (Model)
    link: /docs/action-prompt/prompts
    icon: 📝
    details: Prompt Context is the core data model that contains the runtime context, messages, variables, and configuration for the prompt.
view:
  - title: Prompt (View)
    link: /docs/framework/action-prompt
    icon: 🖼️
    details: Action View templates are responsible for rendering the prompts to agents and UI to users.
controller:
  - title: Agents (Controller)
    link: /docs/framework/active-agent
    icon: <img src="/activeagent.png" />
    details: Agents are Controllers with a common Generation API with enhanced memory and tooling.

---
# Active Agent

Active Agent provides a structured approach to building AI-powered applications through Agent Oriented Programming. Designing applications using agents allows developers to create modular, reusable components that can be easily integrated into existing systems. This approach promotes code reusability, maintainability, and scalability, making it easier to build complex AI-driven applications with the Object Oriented Ruby code you already use today.

## Core Concepts
Active Agent is built around a few core concepts that form the foundation of the framework. These concepts are designed to be familiar to developers who have experience with Ruby on Rails, making it easy to get started with Active Agent. 

- **Agents** are abstract controllers that handles AI interactions using a specified generation provider. Agents are more that lifeless objects, they are the controllers of your application's AI features. They are responsible for managing the flow of data and interactions between different components of your application. Active Agent provides a set of tools and conventions to help you build agents that are easy to understand, maintain, and extend.
- **Actions**: are the agent's interface to perform tasks and render Action Views for templated agent prompts and user interfaces. They provide a way to define reusable components (or leverage your existing view templates) that can be easily integrated into different agents. Actions can be used to retrieve datacreate custom views, handle user input, and manage the flow of data between different components of your application.
- **Prompts** are the core data model that contains the runtime context, messages, variables, and configuration for the prompt.
- **Views**: are responsible for presenting the prompt context and its associated data to the agent and user.
- **Generation Provider**: A generation provider is the backend interface to AI services that enable agents to generate content, embeddings, and request actions.

## MVC Architecture
Active Agent is built around a few core components that work together to provide a seamless experience for developers and users. Using familiar concepts from Rails that made it the MVC framework of choice for web applications, Active Agent extends these concepts to the world of AI and generative models.

## Model: Prompt Context
The Prompt is the core data model that contains the runtime context messages, variables, and configuration for the prompt. It is responsible for managing the contextual history and providing the necessary information for prompt and response cycles.

<FeatureCards :cards="$frontmatter.model" />

## View: Message templates
Message templates are responsible for presenting the prompt context and its associated data to the agent and user. They define the structure and layout of the messages that are displayed in the user interface. Message templates can be customized to fit the specific needs of your application and can include dynamic content based on the prompt context.

<FeatureCards :cards="$frontmatter.view" />

## Controller: Agents
Agents are the core of the Active Agent framework and control the prompt and response cycle. Agents are controllers for AI-driven interactions, managing prompts, actions, and responses. Agents are responsible for managing context, handling user input, generating content, and interacting with generation providers.

<FeatureCards :cards="$frontmatter.controller" />


### Queued Generation Jobs
Active Agent provides a built-in job queue for generating content asynchronously. This allows for efficient processing of requests and ensures that the application remains responsive even during heavy load. Scale it just like you would with any other Rails application with Active Jobs.

### Generation Providers are the AI Service Backends
Generation providers are the backend interfaces to AI services that enable agents to generate content, embeddings, and request actions. They provide a common interface for different AI providers, allowing developers to easily switch between them without changing the core application logic. Using `generate_with` method, you can easily switch between different providers, configurations, instructions, models, and other parameters to optimize the agentic processes.

<!-- 
## Key Features
- **Unified Interface**: All generation providers implement a common interface, making it easy to switch between them.
- **Customizable**: You can create your own generation providers to suit your specific needs.
- **Built-in Providers**: Active Agent comes with built-in providers for popular AI services like OpenAI and Anthropic.
- **Easy Integration**: Integrate with your existing Rails application with minimal setup.
- **Asynchronous Support**: Generation Jobs use Active Job to handle long-running background task processing with ease.
- **Error Handling**: Built-in error handling and retry mechanisms for robust applications.
- **Logging and Monitoring**: Track the performance and usage of your generation providers.
- **Testing Support**: Mock and stub generation providers for unit testing. -->
