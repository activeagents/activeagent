class Providers::AnthropicAgent < ApplicationAgent
  generate_with :anthropic,
                model: "claude-sonnet-4-5-20250929",
                instructions: "You are a helpful AI assistant."

  def ask
    prompt(message: params[:message])
  end
end
