---
title: Overview
cards:
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
    icon: ⏳
    details: Queued Generation manages asynchronous prompt generation and response cycles with Active Job.
  - title: Streaming
    link: /docs/active-agent/callbacks#streaming
    icon: 📡
    details: Streaming allows for real-time dynamic UI updates based on user & agent interactions, enhancing user experience and responsiveness in AI-driven applications.
  - title: Callbacks
    icon: 🔄
    details: Callbacks enable contextual prompting using retrieval before_action or persistence after_generation.
  - title: Generative UI
    link: /docs/active-agent/generative-ui
    icon: 🖼️
    details: Generative UI allows for dynamic and interactive user interfaces that adapt based on AI-generated interactions and content, enhancing user engagement and experience.
---

<FeatureCards :cards="$frontmatter.cards" />