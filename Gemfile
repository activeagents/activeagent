source "https://rubygems.org"

gem "debug" unless ENV["CI"] == "true"
gem "rubocop-rails-omakase"
# json 3.0 (released 2026-09-07) made the options to JSON.parse
# keyword-only; the released Rails (7.2 through 8.1.3.1) still passes them
# positionally, so every boot aborts in db:migrate. Rails main has adapted,
# which is why railsmain.gemfile carries no pin.
gem "json", "< 3"

gemspec

# The dashboard engine, a sibling gem in this repo.
gemspec path: "actionagent", name: "actionagent"
