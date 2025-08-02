class ApplicationAgent < ActiveAgent::Base
  layout "agent"

  generate_with :openai, model: "gpt-4o-mini"
end
