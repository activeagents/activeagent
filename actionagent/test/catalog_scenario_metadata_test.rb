# frozen_string_literal: true

require "test_helper"

class CatalogScenarioMetadataTest < ActiveSupport::TestCase
  EXTRAS = {
    "priority" => "high", "weight" => 0, "reviewed" => false, "nullable" => nil,
    "empty_list" => [], "empty_object" => {}, "empty_text" => "",
    "details" => { "flags" => [ false, nil, 0 ] }, "metadata" => { "source" => "fixture" }
  }.freeze

  def setup
    ActionAgent::ScenarioCatalog.destroy_all
    @storage = ActionAgent.active_storage
    ActionAgent.active_storage = :auto
  end

  def teardown
    ActionAgent.active_storage = @storage
  end

  def document(extras = EXTRAS)
    {
      "catalog" => "support",
      "products" => [ { "key" => "triage", "sets" => [ {
        "key" => "smoke", "scenarios" => [
          { "key" => "hello", "prompt" => "Say hello." }.merge(extras),
          { "key" => "goodbye", "prompt" => "Say goodbye.", "priority" => "normal" }
        ]
      } ] } ]
    }
  end

  def importer(input = document, **options)
    ActionAgent::ScenarioCatalogImport.new(owner: nil, document: input.to_yaml, **options)
  end

  def exported_scenario(catalog, **selection)
    YAML.safe_load(catalog.export_yaml(**selection)).dig("products", 0, "sets", 0, "scenarios", 0)
  end

  test "extension fields survive database reload and every export selection" do
    catalog = importer.call.reload
    scenario = catalog.scenarios.find_by!(key: "hello")

    assert_equal EXTRAS, exported_scenario(catalog).slice(*EXTRAS.keys)
    assert_equal EXTRAS, scenario.reload.metadata
    assert_equal EXTRAS, scenario.to_scenario.metadata
    [ { product_ids: [ catalog.products.sole.id ] }, { set_ids: [ scenario.set.id ] },
      { scenario_ids: [ scenario.id ] } ].each do |selection|
      assert_equal EXTRAS, exported_scenario(catalog, **selection).slice(*EXTRAS.keys)
    end
    assert_equal catalog.digest, ActiveAgent::Evals::Catalog.parse(catalog.export_yaml).digest
  end

  test "an extension-only update appears in preview and updates the stored document and digest" do
    catalog = importer.call
    original_digest = catalog.digest
    scenario = catalog.scenarios.find_by!(key: "hello")
    changed = document(EXTRAS.merge("priority" => "low"))
    preview = importer(changed).preview

    assert_includes preview[:changes], { level: "scenario", path: "triage/smoke/hello", action: "update" }
    assert_equal "high", scenario.reload.metadata["priority"], "preview must not write"
    importer(changed).call

    assert_equal "low", scenario.reload.metadata["priority"]
    assert_not_equal original_digest, catalog.reload.digest
    assert_equal "low", YAML.safe_load(catalog.document).dig("products", 0, "sets", 0, "scenarios", 0, "priority")
    assert_equal catalog.digest, ActiveAgent::Evals::Catalog.parse(catalog.export_yaml).digest
  end

  test "editing a standard field refreshes the document without losing extensions, including after storage restore" do
    catalog = importer.call
    scenario = catalog.scenarios.find_by!(key: "hello")
    scenario.update!(prompt: "Hello again.")
    catalog.refresh_document!
    catalog.sync_to_storage!

    assert_equal EXTRAS, exported_scenario(catalog).slice(*EXTRAS.keys)
    assert_equal "Hello again.", exported_scenario(catalog)["prompt"]
    assert catalog.synced?
    catalog.scenarios.destroy_all
    catalog.restore_from_storage!

    restored = catalog.reload.scenarios.find_by!(key: "hello")
    assert_equal EXTRAS, restored.metadata
    assert_equal "Hello again.", restored.prompt
  end

  test "merge preserves omitted scenarios and replaces the supplied scenario's extensions" do
    catalog = importer.call
    partial = document({ "priority" => "low" })
    partial["products"][0]["sets"][0]["scenarios"].pop
    importer(partial, mode: "merge").call

    assert_equal 2, catalog.reload.scenario_count
    assert_equal({ "priority" => "low" }, catalog.scenarios.find_by!(key: "hello").metadata)
    assert_equal({ "priority" => "normal" }, catalog.scenarios.find_by!(key: "goodbye").metadata)
    assert_equal catalog.digest, ActiveAgent::Evals::Catalog.parse(catalog.export_yaml).digest
  end

  test "replace removes an extension omitted from the new document" do
    catalog = importer.call
    scenario = catalog.scenarios.find_by!(key: "hello")
    importer(document({})).call

    assert_empty scenario.reload.metadata
    assert_not_includes exported_scenario(catalog).keys, "priority"
  end

  test "nil metadata from an upgraded row reads as an empty object and cannot override canonical fields" do
    catalog = importer.call
    scenario = catalog.scenarios.find_by!(key: "hello")
    scenario.update_column(:metadata, nil)
    assert_empty scenario.reload.metadata
    scenario.update!(metadata: { "key" => "forged", "prompt" => "Wrong", "tools" => [ "wrong" ],
                                "expectations" => { "tools" => [ "wrong" ] }, "priority" => "high" })
    exported = exported_scenario(catalog)

    assert_equal "hello", exported["key"]
    assert_equal "Say hello.", exported["prompt"]
    assert_equal "high", exported["priority"]
    assert_empty exported.keys & %w[tools expectations]
  end
end
