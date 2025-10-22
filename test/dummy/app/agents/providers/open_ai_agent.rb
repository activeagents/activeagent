class Providers::OpenAIAgent < ApplicationAgent
  generate_with :openai,
                model: "gpt-4o-mini",
                instructions: "You are a helpful AI assistant."

  def ask
    prompt(message: params[:message])
  end
end
