source "https://rubygems.org"

gemspec

gem "ruby-openai", "~> 8.1.0"
gem "anthropic", "~> 0.3.0"

group :test do
  gem "rspec"
end

group :development, :test do
  gem "standard", require: false
  gem "rubocop-rails-omakase", require: false
  gem "puma"

  gem "sqlite3"
end
