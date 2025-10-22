---
title: Action Prompt
---
# {{ $frontmatter.title }}
Action Prompt is a core component of Active Agent that provides a structured way to manage prompts, render formatted message content through action views, and handle responses.

Active Agent implements base methods that can be used by any agent that inherits from `ActiveAgent::Base`. 

For production applications, **custom actions** are the recommended approach for organizing agent behaviors. For testing and quick prototyping, `Agent.prompt(...)` provides a direct interface to create prompts with messages. Both actions and `Agent.prompt(...)` can work without view templates when passing messages directly.

Action Prompt leverages Action View templates to render messages and provides a consistent interface for generating content.