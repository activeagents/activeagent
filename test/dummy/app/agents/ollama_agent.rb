class OllamaAgent < ApplicationAgent
  layout "agent"
  generate_with :ollama, model: "gemma3:latest", instructions: "You're a basic Ollama agent.", stream: false
end
