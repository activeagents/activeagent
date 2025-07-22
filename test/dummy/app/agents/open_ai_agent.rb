class OpenAIAgent < ApplicationAgent
  layout "agent"
  generate_with :openai, model: "gpt-4o-mini", instructions: "You're a basic OpenAI agent.", stream: false
end
