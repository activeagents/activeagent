# frozen_string_literal: true
require "test_helper"

class ActivePromptAssetPipelineTest < ActiveSupport::TestCase
  def assets_enabled?
    Rails.application.config.respond_to?(:assets) && Rails.application.config.assets
  end

  test "adds engine assets path to host app (if assets enabled)" do
    skip "Assets not enabled in host app" unless assets_enabled?
    paths = Rails.application.config.assets.paths.map(&:to_s)
    expected = ActivePrompt::Engine.root.join("app", "assets").to_s
    assert_includes paths, expected
  end

  test "adds engine assets to precompile list (if assets enabled)" do
    skip "Assets not enabled in host app" unless assets_enabled?
    precompile = Array(Rails.application.config.assets.precompile).map(&:to_s)
    assert_includes precompile, "active_prompt/application.js"
    assert_includes precompile, "active_prompt/application.css"
  end
end
