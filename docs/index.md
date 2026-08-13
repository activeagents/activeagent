---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Active Agent"
  text: "Build AI in Rails"
  tagline: "Now Agents are Controllers \nMakes code tons of fun!"
  actions:
    - theme: brand
      text: Getting Started
      link: /getting_started
    - theme: alt
      text: Docs
      link: /framework
    - theme: alt
      text: GitHub
      link: https://github.com/activeagents/activeagent
  image:
    light: /activeagent-logo.svg
    dark: /activeagent-logo-dark.svg
    alt: ActiveAgent

features:
  - title: Agents
    link: /agents
    icon: <img src="/activeagent-logo.svg" />
    details: Controllers for AI. Define actions, use callbacks, render views. Rails conventions for LLM interactions.
  - title: Tool Calling
    icon: 🔧
    link: /actions/tools
    details: AI calls Ruby methods to fetch data and make decisions. Works like RPC for agents.
  - title: Structured Output
    icon: 📊
    link: /actions/structured_output
    details: Extract typed data with JSON schemas. Validated responses for forms and APIs.
  - title: Providers
    icon: 🏭
    link: /providers
    details: OpenAI, Anthropic, Ollama, OpenRouter. Switch providers with one line of code.
  - title: Streaming
    icon: 📡
    link: /agents/streaming
    details: Real-time response streaming with callbacks for dynamic UIs and live updates.
  - title: Embeddings
    icon: 🎯
    link: /actions/embeddings
    details: Generate vectors for semantic search, RAG, and clustering applications.
  - title: Testing
    icon: 🧪
    link: /framework/testing
    details: Test with fixtures and VCR cassettes. Mock providers for fast tests.
  - title: Dashboard
    icon: 📈
    link: /framework/dashboard
    details: Mount the engine for traces, metrics, the agent builder, conversations and evaluations.
  - title: Background Jobs
    link: /agents/generation
    icon: ⏳
    details: Process generations async with Active Job. Scale AI operations in the background.
  - title: Error Handling
    icon: 🛡️
    link: /agents/error_handling
    details: Automatic retries with exponential backoff. Graceful degradation for production.
---
