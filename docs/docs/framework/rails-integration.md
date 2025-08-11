---
title: Rails Integration
---
# {{ $frontmatter.title }}
Active Agent integrates seamlessly with Rails, leveraging its powerful features to enhance AI-driven applications. This guide covers the key aspects of integrating Active Agent into your Rails application.

## Active Agent compresses the complexity of AI interactions
Active Agent keeps things simple, no multi-step workflows or unnecessary complexity. It integrates directly into your Rails app with clear separation of concerns, making AI features easy to implement and maintain. With less than 10 lines of code, you can ship an AI feature.

## User facing interactions
Active Agent is designed to work seamlessly with Rails applications. It can be easily integrated into your existing Rails app without any additional configuration. 

You can pass messages to the agent from Action Controller, and the agent render a prompt context, generate a response using the configured generation provider, then handle the response using its own `after_generation`. 

```ruby
class MessagesController < ApplicationController
  def create
    @agent = TravelAgent.with(messages: params[:messages]).generate_later
    render json: @agent.response
  end
end
```

## Agent facing interactions
Your Rails app probably already has feature sets for business logic abstracted into models, services, and jobs, so you can leverage these to initiate agent interactions. Whether you want to process a new record to use AI to extract structured data, or you want AI to interact with third-party APIs, or interact base on the current state of your application, you can use Active Agent to handle these interactions.

```ruby
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai
end
```