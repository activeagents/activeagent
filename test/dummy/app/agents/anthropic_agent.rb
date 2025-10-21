class AnthropicAgent < ActiveAgent::Base
  generate_with :anthropic, model: "claude-sonnet-4-5-20250929", instructions: "You're a basic Anthropic agent."
end
