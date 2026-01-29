# OpenRouter, just copying OpenAI
require_relative "open_router_provider"

# Zeitwerk expects OpenrouterProvider from this file name.
module ActiveAgent
  module Providers
    OpenrouterProvider = OpenRouterProvider
  end
end
