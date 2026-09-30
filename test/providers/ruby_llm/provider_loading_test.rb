# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/_base_provider"

class RubyLLMProviderLoadingTest < ActiveSupport::TestCase
  PROVIDER_PATH = File.expand_path("../../../lib/active_agent/providers/ruby_llm_provider.rb", __dir__)

  test "loads RubyLLMProvider via ruby_llm_provider path" do
    require "active_agent/providers/ruby_llm_provider"

    assert defined?(ActiveAgent::Providers::RubyLLMProvider)
    assert defined?(ActiveAgent::Providers::RubyLLM::Options)
  end

  test "loads RubyLLMProvider via rubyllm_provider path" do
    require "active_agent/providers/rubyllm_provider"

    assert defined?(ActiveAgent::Providers::RubyLLMProvider)
  end

  test "provider concern loads the RubyLLM service with the gem's acronym registered" do
    already_registered = "RubyLLM".underscore == "rubyllm"

    with_rubyllm_acronym do
      assert_equal "rubyllm", "RubyLLM".underscore

      klass = ActiveAgent::Base.provider_load("RubyLLM")
      assert_equal ActiveAgent::Providers::RubyLLMProvider, klass
    end

    unless already_registered
      assert_equal "ruby_llm", "RubyLLM".underscore, "acronym leaked out of with_rubyllm_acronym"
    end
  end

  test "provider concern loads the RubyLLM service without the acronym" do
    skip "the ruby_llm railtie registered its acronym in this process" if "RubyLLM".underscore == "rubyllm"

    assert_equal "ruby_llm", "RubyLLM".underscore

    klass = ActiveAgent::Base.provider_load("RubyLLM")
    assert_equal ActiveAgent::Providers::RubyLLMProvider, klass
  end

  test "supports ruby_llm 1.16 and 2.x but refuses older and future major versions" do
    requirement = Gem::Requirement.new(GEM_LOADERS.fetch(:ruby_llm)[1])

    assert_not requirement.satisfied_by?(Gem::Version.new("1.2.0"))
    assert_not requirement.satisfied_by?(Gem::Version.new("1.15.0"))
    assert requirement.satisfied_by?(Gem::Version.new("1.16.0"))
    assert requirement.satisfied_by?(Gem::Version.new("2.0.0"))
    assert_not requirement.satisfied_by?(Gem::Version.new("3.0.0"))
  end

  # A Rails app's Bundler.require loads ruby_llm at boot, before any agent
  # asks for the provider.
  test "checks the ruby_llm version when the app has already loaded the gem" do
    require "ruby_llm"
    original = GEM_LOADERS.fetch(:ruby_llm)
    GEM_LOADERS[:ruby_llm] = [ "ruby_llm", "~> 99.0", "ruby_llm" ]

    error = assert_raises(LoadError) { load PROVIDER_PATH }
    assert_match "supports the 'ruby_llm' gem ~> 99.0", error.message
  ensure
    GEM_LOADERS[:ruby_llm] = original
  end

  test "service name remap handles Rubyllm and RubyLlm variations" do
    remaps = ActiveAgent::Provider::PROVIDER_SERVICE_NAMES_REMAPS

    assert_equal "RubyLLM", remaps["Rubyllm"]
    assert_equal "RubyLLM", remaps["RubyLlm"]
  end

  private

  # Registers the RubyLLM acronym the way the ruby_llm gem's railtie does.
  # Edge Rails freezes every Inflections instance after boot, so the acronym
  # goes on an unfrozen dup swapped in for the duration (dup support is what
  # Inflections#initialize_dup exists for), and the original instance --
  # frozen or not -- is restored afterwards.
  def with_rubyllm_acronym
    original = ActiveSupport::Inflector.inflections(:en)
    swap_en_inflections(original.dup)

    ActiveSupport::Inflector.inflections(:en) do |inflect|
      inflect.acronym "RubyLLM"
    end

    yield
  ensure
    swap_en_inflections(original) if original
  end

  # Installs an :en Inflections instance in the slot this Rails version
  # reads from: a dedicated @__en_instance__ where defined (8.1+), the
  # @__instance__ map otherwise (7.2).
  def swap_en_inflections(instance)
    klass = ActiveSupport::Inflector::Inflections

    if klass.instance_variable_defined?(:@__en_instance__)
      klass.instance_variable_set(:@__en_instance__, instance)
    else
      klass.instance_variable_get(:@__instance__)[:en] = instance
    end
  end
end
