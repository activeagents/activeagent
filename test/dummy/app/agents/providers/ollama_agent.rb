class Providers::OllamaAgent < ApplicationAgent
  generate_with :ollama,
                model: "gemma3:latest",
                instructions: "You are a helpful AI assistant."

  def ask
    prompt(message: params[:message])
  end
end
