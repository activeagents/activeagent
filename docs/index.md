---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Active Agent"
  text: "Build AI in Rails"
  tagline: "Now Agents are Controllers \nMakes code tons of fun!"
  actions:
    - theme: brand
      text: Docs
      link: /docs
    - theme: alt
      text: Getting Started
      link: /docs/getting-started
    - theme: alt
      text: GitHub
      link: https://github.com/activeagents/activeagent
  image:
    light: /activeagent.png
    dark: /activeagent-dark.png
    alt: ActiveAgent

features:
  - title: Agents
    link: /docs/framework/active-agent
    icon: <img src="/activeagent.png" />
    details: Agents are Controllers with a common Generation API with enhanced memory and tooling.
  - title: Actions
    icon: 🦾
    link: /docs/action-prompt/actions
    details: Actions are tools for Agents to interact with systems and code.
  - title: Prompts
    icon: 📝
    link: /docs/action-prompt/prompts
    details: Prompts are rendered with Action View. Agents can generate content using Action View.
  - title: Generation Providers
    icon: 🏭
    link: /docs/framework/generation-provider
    details: Generation Providers establish a common interface for different AI service providers.
  - title: Queued Generation
    link: /docs/active-agent/queued-generation
    icon: ⏳
    details: Queued Generation manages asynchronous prompt generation and response cycles with Active Job.
  - title: Streaming
    link: /docs/active-agent/callbacks#on-stream-callbacks
    icon: 📡
    details: Streaming allows for real-time dynamic UI updates based on user & agent interactions, enhancing user experience and responsiveness in AI-driven applications.
  - title: Callbacks
    link: /docs/active-agent/callbacks
    icon: 🔄
    details: Callbacks enable contextual prompting using retrieval before_action or persistence after_generation.
  - title: Generative UI
    link: /docs/active-agent/generative-ui
    icon: 🖼️
    details: Generative UI allows for dynamic and interactive user interfaces that adapt based on AI-generated interactions and content, enhancing user engagement and experience.
  # - title: RAG
  #   icon: 📚
  #   details: Retrieval Augmented Generation enables agents to access external data sources, enhancing their capabilities and providing more accurate and contextually relevant responses. While RAG has become synonymous with vector databases, it can also be used with traditional databases.
  # - title: Memory
  #   icon: 🧠
  #   details: Memory allows agents to retain information across sessions, enabling personalized and context-aware interactions with users.
  # - title: Lightweight
  #   icon: ⚡
  #   details: Active Agent keeps things simple, no multi-step workflows or unnecessary complexity. It integrates directly into your Rails app with clear separation of concerns, making AI features easy to implement and maintain. With less than 10 lines of code, you can ship an AI feature.
  # - title: Rails-Native
  #   icon: 🚀
  #   details: Active Agent is built explicitly for Rails, following familiar patterns for concise, effortless integrations with your existing stack. It is the only comprehensive solution that truly embraces Rails conventions.
  # - title: Flexible
  #   icon: 🧩
  #   details: Active Agent works seamlessly with tools like LangChain Ruby, pgvector, and the neighbors gem. Its agent-based architecture handles tool calls, renders prompts, and generates vector embeddings for pgvector with ease.
---
