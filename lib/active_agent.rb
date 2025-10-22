# frozen_string_literal: true

require "yaml"
require "abstract_controller"
require "active_agent/configuration"
require "active_agent/version"
require "active_agent/deprecator"
require "active_agent/railtie" if defined?(Rails)
require "active_agent/log_subscriber"

require "active_support"
require "active_support/rails"
require "active_support/core_ext/class"
require "active_support/core_ext/module/attr_internal"
require "active_support/core_ext/string/inflections"
require "active_support/lazy_load_hooks"

# ActiveAgent is a framework for building AI agents with Rails-like conventions.
#
# It provides a structured approach to interacting with Large Language Models (LLMs)
# by offering a familiar interface inspired by ActionMailer. ActiveAgent handles
# prompt management, tool integration, streaming responses, and provider abstraction.
#
# = Core Concepts
#
# * **Agents**: Classes that inherit from {ActiveAgent::Base} and define prompts as methods
# * **Prompts**: Methods that return {Generation} objects for LLM interactions
# * **Tools**: Ruby methods that can be called by LLMs during generation
# * **Providers**: Abstraction layer for different LLM services (OpenAI, Anthropic, etc.)
# * **Streaming**: Real-time response handling via Server-Sent Events
#
# @example Creating a simple agent
#   class GreetingAgent < ActiveAgent::Base
#     generate_with :openai
#
#     def welcome(name:)
#       @name = name
#     end
#   end
#
#   # app/views/greeting_agent/welcome.md.erb
#   # Hello <%= @name %>! How can I help you today?
#
#   generation = GreetingAgent.welcome(name: "Alice")
#   response = generation.generate_now
#
# @example Using tools
#   class WeatherAgent < ActiveAgent::Base
#     generate_with :anthropic
#
#     tool def get_weather(location:)
#       # Call weather API
#       { temperature: 72, condition: "sunny" }
#     end
#
#     def forecast(location:)
#       @location = location
#     end
#   end
#
# @example Streaming responses
#   class ChatAgent < ActiveAgent::Base
#     generate_with :openai
#
#     def chat(message:)
#       @message = message
#     end
#   end
#
#   ChatAgent.chat(message: "Tell me a story").generate do |stream|
#     stream.on_text_delta { |delta| print delta }
#     stream.on_tool_call { |name, args| puts "Calling #{name}" }
#   end
#
# @see ActiveAgent::Base
# @see ActiveAgent::Configuration
# @see https://github.com/quiltt/activeagent ActiveAgent on GitHub
module ActiveAgent
  extend ActiveSupport::Autoload

  # Eager autoload critical components.
  #
  # These components are loaded immediately when {eager_load!} is called,
  # typically during Rails initialization in production environments.
  eager_autoload do
    autoload :Collector
  end

  # Lazy autoload remaining components.
  #
  # These components are loaded on-demand when first referenced.
  autoload :Base
  autoload :Callbacks, "active_agent/concerns/callbacks"
  autoload :Streaming, "active_agent/concerns/streaming"
  autoload :InlinePreviewInterceptor
  autoload :Generation
  autoload :Queueing, "active_agent/concerns/queueing"
  autoload :Parameterized, "active_agent/concerns/parameterized"
  autoload :Preview, "active_agent/concerns/preview"
  autoload :Previews, "active_agent/concerns/preview"
  autoload :GenerationJob
  autoload :Observers, "active_agent/concerns/observers"
  autoload :Provider, "active_agent/concerns/provider"
  autoload :Rescue, "active_agent/concerns/rescue"
  autoload :Tooling, "active_agent/concerns/tooling"
  autoload :View, "active_agent/concerns/view"

  class << self
    # Eagerly loads all ActiveAgent components and descendant agent classes.
    #
    # This method is called during Rails initialization in production mode
    # to load all code upfront, improving request performance and catching
    # load-time errors early.
    #
    # @return [void]
    #
    # @example Manual eager loading
    #   ActiveAgent.eager_load!
    #
    # @note In Rails applications, this is automatically called when
    #   +config.eager_load+ is true (default in production).
    def eager_load!
      super

      Base.descendants.each do |agent|
        agent.eager_load! unless agent.abstract?
      end
    end
  end
end

# Autoload MIME type support for content type handling.
#
# ActiveAgent uses ActionDispatch's MIME type system for handling
# different content types in prompts and responses.
autoload :Mime, "action_dispatch/http/mime_type"

# Configure ActionView integration when loaded.
#
# Sets up default formats and MIME type implementation for rendering
# agent prompt templates. This ensures proper content type handling
# for various template formats (.md.erb, .txt.erb, etc.).
ActiveSupport.on_load(:action_view) do
  ActionView::Base.default_formats ||= Mime::SET.symbols
  ActionView::Template.mime_types_implementation = Mime
  ActionView::LookupContext::DetailsKey.clear
end
