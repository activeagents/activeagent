# frozen_string_literal: true

require "active_agent/evals"
require "tempfile"

document = {
  "catalog" => "support",
  "products" => [ { "key" => "triage", "sets" => [ {
    "key" => "smoke", "scenarios" => [ { "key" => "hello", "prompt" => "Say hello." } ]
  } ] } ]
}

catalog = ActiveAgent::Evals::Catalog.new(document)
from_array = ActiveAgent::Evals::Catalog.new([ document ])
raise "Hash and document-array inputs differ" unless catalog.to_h == from_array.to_h

parsed = ActiveAgent::Evals::Catalog.parse(catalog.to_yaml)
raise "YAML round-trip changed the document" unless parsed.to_h == catalog.to_h
raise "YAML round-trip changed the digest" unless parsed.digest == catalog.digest
raise "scenario was lost" unless parsed.scenarios.map(&:key) == [ "hello" ]

Tempfile.create([ "standalone-catalog", ".yml" ]) do |file|
  file.write(catalog.to_yaml)
  file.flush
  loaded = ActiveAgent::Evals::Catalog.load(file.path)
  raise "file loading changed the digest" unless loaded.digest == catalog.digest
end

raise "Rails should not be loaded" if defined?(Rails)
raise "the framework should not be loaded" if defined?(ActiveAgent::Base)
raise "Active Record should not be loaded" if defined?(ActiveRecord::Base)
raise "RubyLLM should remain opt-in" if defined?(RubyLLM)

puts "ok"
