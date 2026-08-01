source "https://rubygems.org"

gem "debug" unless ENV["CI"] == "true"
gem "rubocop-rails-omakase"

# Until activeagents-telemetry is published to RubyGems, resolve the gemspec
# dependency from GitHub. Remove this line after the first gem push.
gem "activeagents-telemetry", github: "activeagents/activeagents-telemetry"

gemspec
