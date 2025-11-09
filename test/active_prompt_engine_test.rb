# frozen_string_literal: true

require "test_helper"
require "active_prompt"

class ActivePromptEngineTest < ActiveSupport::TestCase
  test "ActivePrompt module loads with version" do
    assert defined?(ActivePrompt), "ActivePrompt should be defined"
    assert_kind_of String, ActivePrompt::VERSION
    refute_empty ActivePrompt::VERSION
  end

  test "engine is defined and inherits from Rails::Engine" do
    assert defined?(ActivePrompt::Engine), "ActivePrompt::Engine should be defined"
    assert ActivePrompt::Engine < Rails::Engine
  end

  test "engine namespace is isolated" do
    assert_equal ActivePrompt, ActivePrompt::Engine.railtie_namespace
  end
end
