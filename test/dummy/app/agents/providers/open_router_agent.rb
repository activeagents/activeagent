class Providers::OpenRouterAgent < ApplicationAgent
  generate_with :open_router,
                model: "qwen/qwen3-30b-a3b:free",
                instructions: "You are a helpful AI assistant."

  def ask
    prompt(message: params[:message])
  end
end
