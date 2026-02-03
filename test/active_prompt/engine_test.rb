# frozen_string_literal: true
require "test_helper"

class ActivePromptEngineTest < ActiveSupport::TestCase
  test "engine constant is defined" do
    assert defined?(ActivePrompt::Engine), "ActivePrompt::Engine should be defined"
  end

  test "engine isolates namespace" do
    assert ActivePrompt::Engine.isolated?, "Engine should isolate the ActivePrompt namespace"
  end

  test "version is present and semantic" do
    assert defined?(ActivePrompt::VERSION), "ActivePrompt::VERSION should be defined"
    assert_match(/\A\d+\.\d+\.\d+\z/, ActivePrompt::VERSION)
  end
end
