---
title: Action Prompt
---
# {{ $frontmatter.title }}
Action Prompt is a core component of Active Agent that provides a structured way to manage prompts, render formatted message content through action views, and handle responses.

Active Agent implements base methods that can be used by any agent that inherits from `ActiveAgent::Base`. 

The primary method is `Agent.prompt(...)` which provides a direct interface to create prompts with messages, and custom actions which use view templates for more complex formatting.

Action Prompt leverages Action View templates to render messages and provides a consistent interface for generating content.