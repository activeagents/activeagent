# frozen_string_literal: true

require "test_helper"
require "generators/active_prompt/install/install_generator"

class ActivePrompt::Generators::InstallGeneratorTest < Rails::Generators::TestCase
  tests ActivePrompt::Generators::InstallGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "source_root points to engine root" do
    assert_equal ActivePrompt::Engine.root.to_s, ActivePrompt::Generators::InstallGenerator.source_root
  end
end
