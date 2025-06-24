require "test_helper"
require "generators/test_unit/install_generator"

class TestUnit::Generators::InstallGeneratorTest < Rails::Generators::TestCase
  tests TestUnit::Generators::InstallGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "runs without error" do
    run_generator [ "user" ]

    # Currently no files are created by the TestUnit install generator
    # This test ensures it runs without error
    assert_no_file "test/agents"
  end

  test "can be extended in the future" do
    # This test documents the intent that this generator can be extended
    # to create test-specific files during installation
    assert_respond_to TestUnit::Generators::InstallGenerator, :new
  end
end
