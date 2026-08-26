# frozen_string_literal: true

require "test_helper"

# The require_gem! guard in ruby_llm_provider.rb only checks that the
# ruby_llm gem's namespace exists, so the loading paths can be exercised
# without the gem installed.
module ::RubyLLM; end unless defined?(::RubyLLM)

class RubyLLMProviderLoadingTest < ActiveSupport::TestCase
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
