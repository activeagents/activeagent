# frozen_string_literal: true

module Providers
  # Example agent using a model Ollama serves from its cloud.
  #
  # `cloud: true` sends requests to https://ollama.com/v1 and expects an API
  # key, read from OLLAMA_API_KEY (created at https://ollama.com/settings/keys).
  # The model is named as the cloud lists it; through a local server signed
  # in to the cloud it would be "gpt-oss:120b-cloud" with no key at all.
  #
  # @example Basic usage
  #   response = Providers::OllamaCloudAgent.ask(message: "Hello").generate_now
  #   response.message.content  #=> "Hi! How can I help you today?"
  # region agent
  class OllamaCloudAgent < ApplicationAgent
    generate_with :ollama, cloud: true, model: "gpt-oss:120b"

    # @return [ActiveAgent::Generation]
    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
