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
      link: /overview
    - theme: alt
      text: Getting Started
      link: /getting-started
    - theme: alt
      text: GitHub
      link: https://github.com/activeagents/activeagent
  image:
    light: /activeagent.png
    dark: /activeagent-dark.png
    alt: ActiveAgent

features:
  - title: Agents
    link: /framework/agents
    icon: <img src="/activeagent.png" />
    details: Controllers for AI. Define actions, manage context, and generate responses using Rails conventions.
  - title: Actions
    icon: 🦾
    link: /actions/actions
    details: Public methods that render prompts or execute tools. Use ERB templates for complex formatting.
  - title: Prompts
    icon: 📝
    link: /actions/prompts
    details: Runtime context with messages, actions, and parameters passed to AI providers.
  - title: Providers
    icon: 🏭
    link: /framework/providers
    details: Unified interface for OpenAI, Anthropic, Ollama, and OpenRouter. Switch with one line.
  - title: Tool Calling
    icon: 🔧
    link: /actions/tool-calling
    details: Let AI agents call Ruby methods to fetch data, perform actions, and make decisions.
  - title: Structured Output
    icon: 📊
    link: /agents/structured-output
    details: Extract data into validated JSON schemas. Perfect for forms, APIs, and data processing.
  - title: Streaming
    icon: 📡
    link: /agents/callbacks#on-stream-callbacks
    details: Real-time response streaming with Server-Sent Events for dynamic UIs.
  - title: Callbacks
    icon: 🔄
    link: /agents/callbacks
    details: Lifecycle hooks for retrieval, context management, and response handling.
  - title: Queued Generation
    link: /agents/queued-generation
    icon: ⏳
    details: Background processing with Active Job for async AI operations at scale.
  - title: Testing
    icon: 🧪
    link: /framework/testing
    details: Test with fixtures and VCR cassettes. Mock providers for fast, reliable tests.
  - title: Embeddings
    icon: 🎯
    link: /framework/embeddings
    details: Generate vector embeddings for semantic search, clustering, and RAG applications.
  - title: Rails-Native
    icon: 🚀
    link: /framework/agents
    details: Built for Rails. Familiar patterns, zero learning curve, production-ready from day one.
---
