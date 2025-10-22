---
title: Overview
cards:
  - title: Agents
    link: /framework/agents
    icon: <img src="/activeagent.png" />
    details: Agents are Controllers with a common Generation API with enhanced memory and tooling.
  - title: Actions
    icon: 🦾
    link: /actions/actions
    details: Actions organize agent behaviors. Optionally use Action View templates for complex formatting.
  - title: Prompts
    icon: 📝
    link: /actions/prompts
    details: Prompts contain the runtime context, messages, and configuration for AI generation.
  - title: Providers
    icon: 🏭
    link: /framework/providers
    details: Providers establish a common interface for different AI service providers.
  - title: Queued Generation
    icon: ⏳
    details: Queued Generation manages asynchronous prompt generation and response cycles with Active Job.
  - title: Streaming
    link: /agents/callbacks#streaming
    icon: 📡
    details: Streaming allows for real-time dynamic UI updates based on user & agent interactions, enhancing user experience and responsiveness in AI-driven applications.
  - title: Callbacks
    icon: 🔄
    details: Callbacks enable contextual prompting using retrieval before_action or persistence after_generation.
  - title: Generative UI
    link: /agents/generative-ui
    icon: 🖼️
    details: Generative UI allows for dynamic and interactive user interfaces that adapt based on AI-generated interactions and content, enhancing user engagement and experience.
---

<FeatureCards :cards="$frontmatter.cards" />
