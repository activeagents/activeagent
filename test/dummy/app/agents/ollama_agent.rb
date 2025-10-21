class OllamaAgent < ApplicationAgent
  generate_with :ollama, model: "gemma3:latest", instructions: "You're a basic Ollama agent."
end
