# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/_base_provider"

# Covers the gem-dependency loading errors raised by require_gem! in
# _base_provider.rb: each failure mode (gem missing, incompatible version,
# installed-but-broken require) must be reported truthfully with the
# provider, gem, and version requirement spelled out.
class RequireGemTest < ActiveSupport::TestCase
  TEST_LOADERS = {
    missing_gem:    [ "nonexistent_gem_xyz", ">= 1.0",  "nonexistent_gem_xyz" ],
    wrong_version:  [ "minitest",            ">= 999",  "minitest" ],
    broken_require: [ "minitest",            ">= 5.0",  "nonexistent_require_target_xyz" ],
    loadable:       [ "minitest",            ">= 5.0",  "minitest" ]
  }.freeze

  setup    { GEM_LOADERS.merge!(TEST_LOADERS) }
  teardown { TEST_LOADERS.each_key { |key| GEM_LOADERS.delete(key) } }

  test "missing gem reports provider, gem, and requirement with the activation failure as cause" do
    error = assert_raises(LoadError) do
      require_gem!(:missing_gem, "fake_provider.rb")
    end

    assert_includes error.message, "The Fake provider requires the 'nonexistent_gem_xyz' gem (>= 1.0)"
    assert_includes error.message, "Gemfile"
    assert_kind_of Gem::LoadError, error.cause
  end

  test "incompatible gem version keeps the RubyGems explanation instead of claiming the gem is missing" do
    error = assert_raises(LoadError) do
      require_gem!(:wrong_version, "fake_provider.rb")
    end

    assert_includes error.message, "'minitest' gem (>= 999)"
    assert_includes error.message, error.cause.message
    assert_kind_of Gem::LoadError, error.cause
  end

  test "installed gem that fails to require is reported as installed, not missing" do
    error = assert_raises(LoadError) do
      require_gem!(:broken_require, "fake_provider.rb")
    end

    assert_includes error.message, "The 'minitest' gem is installed"
    assert_includes error.message, "nonexistent_require_target_xyz"
    refute_includes error.message, "Add it to your Gemfile"
    assert_kind_of LoadError, error.cause
  end

  test "satisfied dependency loads without raising" do
    assert_nothing_raised do
      require_gem!(:loadable, "fake_provider.rb")
    end
  end

  test "namespaced _base.rb files report their directory's provider name" do
    error = assert_raises(LoadError) do
      require_gem!(:missing_gem, "lib/active_agent/providers/open_ai/_base.rb")
    end

    assert_includes error.message, "The OpenAI provider requires"
    refute_includes error.message, "Base provider"
  end

  test "provider files report a clean display name without the _provider suffix" do
    error = assert_raises(LoadError) do
      require_gem!(:missing_gem, "lib/active_agent/providers/ollama_provider.rb")
    end

    assert_includes error.message, "The Ollama provider requires"
  end

  test "ruby_llm-style names use their canonical capitalization" do
    error = assert_raises(LoadError) do
      require_gem!(:missing_gem, "lib/active_agent/providers/ruby_llm_provider.rb")
    end

    assert_includes error.message, "The RubyLLM provider requires"
  end
end
