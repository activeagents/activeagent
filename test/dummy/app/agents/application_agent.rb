class ApplicationAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini"
end
