class ApplicationAgent < ActiveAgent::Base
  layout "agent"

  generate_with :openai, model: "gpt-4o-mini", instructions: "You're just a basic agent", stream: true
end
