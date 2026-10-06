# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/_base_provider"

# require_gem! is the one place a provider declares which versions of its
# client gem it supports, so its error has to say which of four things went
# wrong: the gem is missing, a version outside that range is loaded, a
# differently-named gem already owns the client constant, or something else
# already defines that constant.
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

  test "names ruby-openai when that gem is activated" do
    error = openai_load_error(activated: [ "ruby-openai" ])

    assert_equal "OpenaiProvider needs the 'openai' gem, but this bundle has 'ruby-openai'. " \
                 "Both define OpenAI, so the two cannot be installed together — " \
                 "replace `gem \"ruby-openai\"` with `gem \"openai\"` in your Gemfile and run `bundle install`.",
                 error.message
  end

  test "names ruby-openai when OpenAI is defined by a file inside that gem" do
    error = openai_load_error(source: [ "/usr/local/bundle/gems/ruby-openai-8.3.0/lib/openai/http_headers.rb", 1 ])

    assert_equal "OpenaiProvider needs the 'openai' gem, but this bundle has 'ruby-openai'. " \
                 "Both define OpenAI, so the two cannot be installed together — " \
                 "replace `gem \"ruby-openai\"` with `gem \"openai\"` in your Gemfile and run `bundle install`.",
                 error.message
  end

  test "names the application file that already defines OpenAI" do
    error = openai_load_error(source: [ "/srv/app/lib/open_ai.rb", 1 ])

    assert_equal "OpenaiProvider needs the 'openai' gem, which defines OpenAI, " \
                 "but OpenAI is already defined in /srv/app/lib/open_ai.rb. " \
                 "Rename or remove that definition, then add `gem \"openai\"` to your Gemfile and run `bundle install`.",
                 error.message
  end

  test "falls back to the generic message when nothing defines OpenAI" do
    error = openai_load_error(source: nil)

    assert_equal "The 'openai' gem is required for OpenaiProvider. " \
                 "Please add it to your Gemfile and run `bundle install`.", error.message
  end

  test "does not mistake an application directory named after ruby-openai for the gem" do
    error = openai_load_error(source: [ "/home/dev/ruby-openai-demo/lib/open_ai.rb", 1 ])

    assert_equal "OpenaiProvider needs the 'openai' gem, which defines OpenAI, " \
                 "but OpenAI is already defined in /home/dev/ruby-openai-demo/lib/open_ai.rb. " \
                 "Rename or remove that definition, then add `gem \"openai\"` to your Gemfile and run `bundle install`.",
                 error.message
  end

  test "names the file a pending autoload of OpenAI will load" do
    error = openai_load_error(source: [ "/usr/local/bundle/gems/zeitwerk-2.8.3/lib/zeitwerk/cref.rb", 47 ],
                              autoload: "/srv/app/app/lib/open_ai.rb")

    assert_equal "OpenaiProvider needs the 'openai' gem, which defines OpenAI, " \
                 "but OpenAI is already defined in /srv/app/app/lib/open_ai.rb. " \
                 "Rename or remove that definition, then add `gem \"openai\"` to your Gemfile and run `bundle install`.",
                 error.message
  end

  test "says OpenAI is defined elsewhere when Ruby cannot tell where" do
    error = openai_load_error(source: [])

    assert_equal "OpenaiProvider needs the 'openai' gem, which defines OpenAI, " \
                 "but OpenAI is already defined elsewhere. " \
                 "Rename or remove that definition, then add `gem \"openai\"` to your Gemfile and run `bundle install`.",
                 error.message
  end

  test "does not report OpenAI when the openai gem defined it before its require failed" do
    error = openai_load_error(activated: [ "openai" ],
                              source: [ "/usr/local/bundle/gems/openai-0.98.0/lib/openai/version.rb", 3 ])

    assert_equal "The 'openai' gem is required for OpenaiProvider. " \
                 "Please add it to your Gemfile and run `bundle install`.", error.message
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

  # Returns the LoadError require_gem! raises for the real :openai type when
  # requiring the gem fails. Of the two gems that define OpenAI, only
  # +activated+ count as activated. +source+ and +autoload+ stand in for what
  # Object.const_source_location and Object.autoload? report for OpenAI:
  # +source+ is nil when the constant is undefined and [] when Ruby cannot
  # tell where it was defined.
  def openai_load_error(activated: [], source: nil, autoload: nil)
    loaded_specs = Gem.loaded_specs.except("openai", "ruby-openai")
    activated.each { |name| loaded_specs[name] = Gem::Specification.new(name, "1.0.0") }

    with_gem_loader(:openai, [ "openai", ">= 0", "activeagent_absent_gem" ]) do
      Gem.stub(:loaded_specs, loaded_specs) do
        Object.stub(:const_source_location, source) do
          Object.stub(:autoload?, autoload) do
            assert_raises(LoadError) { require_gem!(:openai, "lib/openai_provider.rb") }
          end
        end
      end
    end
  end
end
