require "test_helper"
require "generators/active_agent/json_schema/json_schema_generator"

class JsonSchemaGeneratorTest < Rails::Generators::TestCase
  tests ActiveAgent::Generators::JsonSchemaGenerator
  destination File.expand_path("../tmp", __dir__)
  setup :prepare_destination

  def test_creates_json_view_template
    run_generator %w[Report analyze]

    assert_file "app/views/report_agent/analyze.json.jbuilder" do |content|
      assert_match(/json\.name .*ReportAgent#analyze/, content)
    end
  end
end
