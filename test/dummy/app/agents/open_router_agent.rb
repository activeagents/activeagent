class OpenRouterAgent < ApplicationAgent
  layout "agent"
  generate_with :open_router, model: "qwen/qwen3-30b-a3b:free", instructions: "You're a basic Open Router agent.", stream: false
end
