# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/_base_provider"

# require_gem! is the one place a provider declares which versions of its
# client gem it supports, so its error has to say which of three things went
# wrong: the gem is missing, a version outside that range is loaded, or a
# differently-named gem already owns the client constant.
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

  test "checks every bound and gives an installable Gemfile declaration for a version range" do
    loaded = Gem.loaded_specs.fetch("minitest").version

    with_gem_loader(:unsupported, [ "minitest", [ ">= 99", "< 100" ], "minitest" ]) do
      error = assert_raises(LoadError) { require_gem!(:unsupported, "lib/example_provider.rb") }

      assert_equal "ExampleProvider supports the 'minitest' gem >= 99, < 100, but #{loaded} is loaded. " \
                   "Add `gem \"minitest\", \">= 99\", \"< 100\"` to your Gemfile and run `bundle update minitest`.",
                   error.message
    end
  end

  test "names the conflicting gem when a different gem already defines the constant" do
    conflict = { gem: "ruby-openai", constant: "OpenAI" }

    with_gem_loader(:conflict, [ "openai", ">= 0", "activeagent_absent_gem" ]) do
      stub(:gem_conflict_for, conflict) do
        error = assert_raises(LoadError) { require_gem!(:conflict, "lib/openai_provider.rb") }

        assert_equal "OpenaiProvider needs the 'openai' gem, but this bundle has 'ruby-openai'. " \
                     "Both define OpenAI, so the two cannot be installed together — " \
                     "replace `gem \"ruby-openai\"` with `gem \"openai\"` in your Gemfile and run `bundle install`.",
                     error.message
      end
    end
  end

  test "falls back to the generic message when nothing conflicts" do
    with_gem_loader(:conflict, [ "openai", ">= 0", "activeagent_absent_gem" ]) do
      stub(:gem_conflict_for, nil) do
        error = assert_raises(LoadError) { require_gem!(:conflict, "lib/openai_provider.rb") }

        assert_equal "The 'openai' gem is required for OpenaiProvider. " \
                     "Please add it to your Gemfile and run `bundle install`.", error.message
      end
    end
  end

  test "reports an unsupported version ahead of a conflict" do
    loaded = Gem.loaded_specs.fetch("minitest").version

    with_gem_loader(:unsupported, [ "minitest", "~> 99.0", "minitest" ]) do
      stub(:gem_conflict_for, { gem: "ruby-openai", constant: "OpenAI" }) do
        error = assert_raises(LoadError) { require_gem!(:unsupported, "lib/example_provider.rb") }

        assert_equal "ExampleProvider supports the 'minitest' gem ~> 99.0, but #{loaded} is loaded. " \
                     "Add `gem \"minitest\", \"~> 99.0\"` to your Gemfile and run `bundle update minitest`.",
                     error.message
      end
    end
  end

  private

  # Temporarily registers a loader for +key+. Restores whatever was there
  # before rather than deleting, so a test reusing a real provider's key
  # cannot strip it out of GEM_LOADERS for the rest of the run.
  def with_gem_loader(key, loader)
    previous = GEM_LOADERS[key]
    had_previous = GEM_LOADERS.key?(key)
    GEM_LOADERS[key] = loader
    yield
  ensure
    had_previous ? GEM_LOADERS[key] = previous : GEM_LOADERS.delete(key)
  end
end
