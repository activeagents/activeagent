class ApplicationAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini", instructions: "You are a helpful assistant."
end

