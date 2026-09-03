source "https://rubygems.org"

gem "debug" unless ENV["CI"] == "true"
gem "rubocop-rails-omakase"

gemspec

# The evaluation core and the dashboard engine, sibling gems in this repo.
gemspec path: "evals", name: "activeagents-evals"
gemspec path: "actionagent", name: "actionagent"
