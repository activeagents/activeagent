class OpenAIAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini", instructions: "You're a basic OpenAI agent."
end
