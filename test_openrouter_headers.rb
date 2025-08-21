#!/usr/bin/env ruby
# Simple test script to verify OpenRouter headers are set correctly

require "bundler/setup"
require "active_agent"
require "active_agent/generation_provider/open_router_provider"

# Test configuration
config = {
  "api_key" => "test_key",
  "model" => "openai/gpt-4o",
  "app_name" => "MyTestApp",
  "site_url" => "https://myapp.example.com"
}

# Initialize provider
provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(config)

# Get the client
client = provider.instance_variable_get(:@client)

# Check headers
puts "=== OpenRouter Client Configuration ==="
puts "Base URI: #{client.instance_variable_get(:@uri_base)}"
puts "\nExtra Headers:"
extra_headers = client.instance_variable_get(:@extra_headers)
extra_headers.each do |key, value|
  puts "  #{key}: #{value}"
end

puts "\n=== Test Results ==="
if extra_headers["X-Title"] == "MyTestApp"
  puts "✓ X-Title header is correctly set"
else
  puts "✗ X-Title header is not set correctly"
end

if extra_headers["HTTP-Referer"] == "https://myapp.example.com"
  puts "✓ HTTP-Referer header is correctly set"
else
  puts "✗ HTTP-Referer header is not set correctly"
end

puts "\n=== Testing Default Values ==="
# Test with no app_name/site_url
minimal_config = {
  "api_key" => "test_key",
  "model" => "openai/gpt-4o"
}

provider2 = ActiveAgent::GenerationProvider::OpenRouterProvider.new(minimal_config)
client2 = provider2.instance_variable_get(:@client)
extra_headers2 = client2.instance_variable_get(:@extra_headers)

puts "When no app_name/site_url provided:"
puts "  X-Title: #{extra_headers2["X-Title"] || "(not set)"}"
puts "  HTTP-Referer: #{extra_headers2["HTTP-Referer"] || "(not set)"}"