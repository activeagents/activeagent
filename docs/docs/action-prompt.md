---
title: Action Prompt
---
# {{ $frontmatter.title }}
Action Prompt is a core component of Active Agent that provides a structured way to manage prompts, render formatted message content through action views, and handle responses.

Active Agent implements base actions that can be used by any agent that inherits from `ActiveAgent::Base`. 

The primary action is the `prompt_context` which provides a common interface to render prompts with context messages.



 with It allows developers to define actions that can be used to interact with agents and generate responses based on user input. 

Action Prompt leverages Action View templates to render messages and provides a consistent interface for generating content.