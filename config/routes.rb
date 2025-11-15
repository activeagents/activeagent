# frozen_string_literal: true

ActivePrompt::Engine.routes.draw do
  get "health", to: proc { [200, { "Content-Type" => "text/plain" }, ["ok"]] }, as: :health
end
