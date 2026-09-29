# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/_base_provider"

# require_gem! is the one place a provider declares which versions of its
# client gem it supports, so its error has to say which of two things went
# wrong: the gem is missing, or a version outside that range is loaded.
class RequireGemTest < ActiveSupport::TestCase
  test "names the missing gem and asks for it in the Gemfile" do
    with_gem_loader(:missing, [ "activeagent_absent_gem", ">= 0", "activeagent_absent_gem" ]) do
      error = assert_raises(LoadError) { require_gem!(:missing, "lib/example_provider.rb") }

      assert_equal "The 'activeagent_absent_gem' gem is required for ExampleProvider. " \
                   "Please add it to your Gemfile and run `bundle install`.", error.message
    end
  end

  test "names the supported range and the loaded version when the loaded gem is outside it" do
    loaded = Gem.loaded_specs.fetch("minitest").version

    with_gem_loader(:unsupported, [ "minitest", "~> 99.0", "minitest" ]) do
      error = assert_raises(LoadError) { require_gem!(:unsupported, "lib/example_provider.rb") }

      assert_equal "ExampleProvider supports the 'minitest' gem ~> 99.0, but #{loaded} is loaded. " \
                   "Add `gem \"minitest\", \"~> 99.0\"` to your Gemfile and run `bundle update minitest`.",
                   error.message
    end
  end

  private

  def with_gem_loader(key, loader)
    GEM_LOADERS[key] = loader
    yield
  ensure
    GEM_LOADERS.delete(key)
  end
end
