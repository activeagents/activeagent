# app/agents/action_agent.rb
class ActionAgent < ActiveAgent::Base
  def search
    prompt do |p|
      p.text "Searching for results..."
      p.html "<h1>Search Results</h1>"
      p.json({results: [1, 2, 3]})
    end
  end

  def greet(name)
    prompt(template_name: "greet", name: name)
  end
end
