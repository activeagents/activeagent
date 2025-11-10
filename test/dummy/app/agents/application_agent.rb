class ApplicationAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini"
  embed_with :openai, model: "text-embedding-3-small"
end
