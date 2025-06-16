---
title: Active Agent
model:
  - title: Context (Model)
    link: /docs/action-prompt/prompts
    icon: 📝
    details: Prompt Context is the core data model that contains the runtime context, messages, variables, and configuration for the prompt.
  - title: Prompt Context Management (Callbacks)
    link: /docs/active-agent/callbacks
    icon: 🔄
    details: Callbacks enable contextual prompting, retrieval, generation response handling, and persistence.
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

