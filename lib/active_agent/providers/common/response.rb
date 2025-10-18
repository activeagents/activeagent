# frozen_string_literal: true

require_relative "responses/prompt"
require_relative "responses/embed"

module ActiveAgent
  module Providers
    module Common
      PromptResponse = Responses::Prompt
      EmbedResponse  = Responses::Embed
    end
  end
end
