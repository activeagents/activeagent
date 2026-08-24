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

  # Registers the RubyLLM acronym the way the ruby_llm gem's railtie does,
  # and removes it again afterwards. Where the :en Inflections instance is
  # stored varies across Rails versions (an @__instance__ map entry on 7.2,
  # a dedicated @__en_instance__ on 8.1), so this mutates the live instance
  # in both directions rather than swapping it out.
  def with_rubyllm_acronym
    inflections = nil
    had_acronym = nil

    ActiveSupport::Inflector.inflections(:en) do |inflect|
      inflections = inflect
      had_acronym = inflect.acronyms.key?("rubyllm")
      inflect.acronym "RubyLLM"
    end

    yield
  ensure
    if inflections && !had_acronym
      inflections.acronyms.delete("rubyllm")
      inflections.send(:define_acronym_regex_patterns)
    end
  end
end
