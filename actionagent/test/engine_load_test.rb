# frozen_string_literal: true

require "test_helper"

# The engine's class body reads Zeitwerk's inflector. Rails requires Zeitwerk
# only when the application sets up its autoloaders, which is after
# Bundler.require has loaded this gem. Until then the constant exists only
# if something else loaded it first, and in a host application that
# something is Action Cable's engine: `rails/all` includes it, this dummy app
# requires it, and an app generated with `--skip-action-cable` (or any
# API-only host) does neither, and used to die at boot with
# `uninitialized constant ActionAgent::Engine::Zeitwerk`. The engine
# requires Zeitwerk itself now.
#
# That order cannot be reproduced in this process, which loaded everything
# long ago, so the test boots a fresh Ruby on the same bundle and loads the
# engine right after `rails`, with nothing in between.
class EngineLoadTest < ActiveSupport::TestCase
  SCRIPT = <<~RUBY
    require "bundler/setup"
    require "rails"
    # On a Rails that loads Zeitwerk itself there is nothing to prove.
    (puts "zeitwerk-preloaded"; exit) if defined?(Zeitwerk)
    require "action_agent"
    puts ActionAgent::Engine::DEFAULT_SPELLINGS.fetch("McpCatalog")
  RUBY

  test "the engine loads before Rails has required Zeitwerk" do
    output = IO.popen([ RbConfig.ruby, "-e", SCRIPT ], err: [ :child, :out ], &:read)
    status = $?

    assert_predicate status, :success?, output
    skip "this Rails requires Zeitwerk on `require \"rails\"`; the order under test cannot occur" if output.include?("zeitwerk-preloaded")
    assert_equal "MCPCatalog", output.strip
  end
end
