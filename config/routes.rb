# frozen_string_literal: true

ActivePrompt::Engine.routes.draw do
  get "health", to: "health#show", as: :health
end
