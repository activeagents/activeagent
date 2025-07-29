require "test_helper"
require "generators/erb/install_generator"

class Erb::Generators::InstallGeneratorTest < Rails::Generators::TestCase
  tests Erb::Generators::InstallGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "creates agent layout files" do
    run_generator

    assert_file "app/views/layouts/agent.text.erb" do |content|
      assert_match(/<%= yield %>/, content)
    end
  end

  test "creates layout files with correct format and ERB syntax" do
    run_generator [ "--formats=html" ]

    assert_file "app/views/layouts/agent.html.erb" do |content|
      assert_match(/<%= yield %>/, content)
    end
  end
end
