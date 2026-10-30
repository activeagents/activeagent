# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Ollama options tests"
  return
end

require_relative "../../../lib/active_agent/providers/ollama_provider"

module Providers
  module Ollama
    # Where the provider sends requests and how it signs them: a host given
    # outright, `cloud: true`, OLLAMA_HOST, or the local server; a key given
    # outright, OLLAMA_API_KEY, or the placeholder a local server ignores.
    class OptionsTest < ActiveSupport::TestCase
      ENV_NAMES = %w[OLLAMA_HOST OLLAMA_API_KEY OLLAMA_ACCESS_TOKEN].freeze
      Options = ActiveAgent::Providers::Ollama::Options

      test "defaults to the local server with the placeholder key" do
        with_env do
          options = Options.new

          assert_equal "http://127.0.0.1:11434/v1", options.base_url
          assert_equal "ollama", options.api_key
          assert_not options.cloud?
          assert_equal({ base_url: "http://127.0.0.1:11434/v1", api_key: "ollama" }, options.serialize)
        end
      end

      test "a host given outright is completed to its /v1 endpoint and wins over OLLAMA_HOST" do
        with_env("OLLAMA_HOST" => "https://ollama.com") do
          assert_equal "http://mini.local:11434/v1", Options.new(host: "http://mini.local:11434").base_url
          assert_equal "http://mini.local:11434/v1", Options.new(base_url: "http://mini.local:11434/").base_url
          assert_equal "http://mini.local:11434/v1", Options.new(uri_base: "mini.local").base_url
          assert_equal "http://mini.local:11434/v1", Options.new("host" => "http://mini.local:11434/v1").base_url
          assert_equal "https://ai.example.com/ollama/v1", Options.new(host: "https://ai.example.com/ollama/v1").base_url
          assert_not Options.new(host: "http://mini.local:11434").cloud?
        end
      end

      test "OLLAMA_HOST names the server the way the ollama command reads it" do
        with_env("OLLAMA_HOST" => "0.0.0.0") { assert_equal "http://0.0.0.0:11434/v1", Options.new.base_url }
        with_env("OLLAMA_HOST" => "http://localhost") { assert_equal "http://localhost:11434/v1", Options.new.base_url }
        with_env("OLLAMA_HOST" => "http://mini.local:8080/") { assert_equal "http://mini.local:8080/v1", Options.new.base_url }
        with_env("OLLAMA_HOST" => "https://ollama.com") do
          options = Options.new

          assert_equal "https://ollama.com/v1", options.base_url
          assert options.cloud?
        end
      end

      test "cloud: true sends requests to Ollama Cloud and is not a client option" do
        with_env("OLLAMA_API_KEY" => "sk-cloud") do
          options = Options.new(cloud: true)

          assert options.cloud?
          assert_equal "https://ollama.com/v1", options.base_url
          assert_equal "sk-cloud", options.api_key
          assert_equal({ base_url: "https://ollama.com/v1", api_key: "sk-cloud" }, options.serialize)
        end
      end

      test "cloud: true keeps a host given outright, for a proxy in front of the cloud" do
        with_env do
          options = Options.new(cloud: true, host: "https://proxy.example.com/ollama/v1", api_key: "sk-cloud")

          assert_equal "https://proxy.example.com/ollama/v1", options.base_url
          assert options.cloud?
          assert_equal({ base_url: "https://proxy.example.com/ollama/v1", api_key: "sk-cloud" }, options.serialize)
        end
      end

      test "the key is the one given, else OLLAMA_API_KEY, else OLLAMA_ACCESS_TOKEN" do
        with_env("OLLAMA_API_KEY" => "sk-env", "OLLAMA_ACCESS_TOKEN" => "sk-token") do
          assert_equal "sk-given", Options.new(api_key: "sk-given").api_key
          assert_equal "sk-given", Options.new(access_token: "sk-given").api_key
          assert_equal "sk-env", Options.new.api_key
        end
        with_env("OLLAMA_ACCESS_TOKEN" => "sk-token") { assert_equal "sk-token", Options.new.api_key }
      end

      test "Ollama Cloud needs a real key; a local server does not" do
        with_env do
          error = assert_raises(ActiveAgent::Providers::Errors::AuthenticationFailed) { Options.new(cloud: true).require_cloud_api_key! }
          assert_match(/OLLAMA_API_KEY/, error.message)
          assert_equal "Ollama", error.provider_tag

          assert_raises(ActiveAgent::Providers::Errors::AuthenticationFailed) do
            Options.new(host: "https://ollama.com", api_key: "ollama").require_cloud_api_key!
          end
          assert_nothing_raised { Options.new(cloud: true, api_key: "sk-cloud").require_cloud_api_key! }
          assert_nothing_raised { Options.new.require_cloud_api_key! }
          assert_nothing_raised { Options.new(host: "http://mini.local:11434").require_cloud_api_key! }
        end
      end

      private

      # Clears every Ollama variable, applies +values+, and restores the
      # environment afterwards.
      def with_env(values = {})
        names = ENV_NAMES | values.keys
        previous = names.to_h { |name| [ name, ENV[name] ] }
        names.each { |name| ENV.delete(name) }
        values.each { |name, value| ENV[name] = value }
        yield
      ensure
        previous.each { |name, value| ENV[name] = value }
      end
    end
  end
end
