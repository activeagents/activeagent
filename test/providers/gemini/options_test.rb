# frozen_string_literal: true

require "test_helper"

GEMINI_OPTIONS_OPENAI_AVAILABLE = begin
  require "openai"
  true
rescue LoadError
  warn "OpenAI gem not available, skipping Gemini options tests"
  false
end

require_relative "../../../lib/active_agent/providers/gemini_provider" if GEMINI_OPTIONS_OPENAI_AVAILABLE

class GeminiOptionsTest < ActiveSupport::TestCase
  setup do
    skip "OpenAI gem not available" unless GEMINI_OPTIONS_OPENAI_AVAILABLE
    @valid_options = {
      api_key: "test-api-key"
    }
  end

  test "validates presence of api_key" do
    original_keys = [
      ENV["GEMINI_API_KEY"],
      ENV["GOOGLE_API_KEY"]
    ]
    ENV.delete("GEMINI_API_KEY")
    ENV.delete("GOOGLE_API_KEY")

    options = ActiveAgent::Providers::Gemini::Options.new({})

    assert_not options.valid?
    assert_includes options.errors[:api_key], "can't be blank"
  ensure
    ENV["GEMINI_API_KEY"] = original_keys[0]
    ENV["GOOGLE_API_KEY"] = original_keys[1]
  end

  test "resolves api_key from GEMINI_API_KEY environment variable" do
    original_keys = [
      ENV["GEMINI_API_KEY"],
      ENV["GOOGLE_API_KEY"]
    ]
    ENV["GEMINI_API_KEY"] = "env-gemini-key"
    ENV.delete("GOOGLE_API_KEY")

    options = ActiveAgent::Providers::Gemini::Options.new({})

    assert_equal "env-gemini-key", options.api_key
  ensure
    ENV["GEMINI_API_KEY"] = original_keys[0]
    ENV["GOOGLE_API_KEY"] = original_keys[1]
  end

  test "resolves api_key from GOOGLE_API_KEY environment variable" do
    original_keys = [
      ENV["GEMINI_API_KEY"],
      ENV["GOOGLE_API_KEY"]
    ]
    ENV.delete("GEMINI_API_KEY")
    ENV["GOOGLE_API_KEY"] = "env-google-key"

    options = ActiveAgent::Providers::Gemini::Options.new({})

    assert_equal "env-google-key", options.api_key
  ensure
    ENV["GEMINI_API_KEY"] = original_keys[0]
    ENV["GOOGLE_API_KEY"] = original_keys[1]
  end

  test "prefers GEMINI_API_KEY over GOOGLE_API_KEY" do
    original_keys = [
      ENV["GEMINI_API_KEY"],
      ENV["GOOGLE_API_KEY"]
    ]
    ENV["GEMINI_API_KEY"] = "gemini-key"
    ENV["GOOGLE_API_KEY"] = "google-key"

    options = ActiveAgent::Providers::Gemini::Options.new({})

    assert_equal "gemini-key", options.api_key
  ensure
    ENV["GEMINI_API_KEY"] = original_keys[0]
    ENV["GOOGLE_API_KEY"] = original_keys[1]
  end

  test "prefers explicit api_key over environment variables" do
    original_key = ENV["GEMINI_API_KEY"]
    ENV["GEMINI_API_KEY"] = "env-key"

    options = ActiveAgent::Providers::Gemini::Options.new(@valid_options)

    assert_equal "test-api-key", options.api_key
  ensure
    ENV["GEMINI_API_KEY"] = original_key
  end

  test "accepts access_token as alias for api_key" do
    options = ActiveAgent::Providers::Gemini::Options.new(
      access_token: "token-via-access-token"
    )

    assert_equal "token-via-access-token", options.api_key
  end

  test "organization_id returns nil" do
    options = ActiveAgent::Providers::Gemini::Options.new(@valid_options)

    assert_nil options.organization
  end

  test "project_id returns nil" do
    options = ActiveAgent::Providers::Gemini::Options.new(@valid_options)

    assert_nil options.project
  end
end
