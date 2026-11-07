# frozen_string_literal: true

require "test_helper"

# A catalog product's named criteria lists (`criteria: { name => [...] }`)
# kept by the dashboard: stored on import, emitted by the export, compared
# by the import preview, and layered by name and criterion key in merge mode.
class CatalogProductCriteriaTest < ActiveSupport::TestCase
  # Makes ScenarioProduct report no criteria column while +hidden+ is set,
  # as an install that has not run add_catalog_product_criteria does.
  module WithoutCriteriaColumn
    mattr_accessor :hidden, default: false

    def has_attribute?(name)
      return false if WithoutCriteriaColumn.hidden && name.to_s == "criteria"

      super
    end
  end
  ActionAgent::ScenarioProduct.prepend(WithoutCriteriaColumn)

  LISTS = {
    "shared" => [ { "key" => "answered", "type" => "response_present" } ],
    "strict" => [
      { "key" => "answered", "type" => "response_present" },
      { "key" => "polite", "type" => "not_contains", "config" => { "pattern" => "unfortunately" } }
    ]
  }.freeze

  SET_CRITERIA = [ { "key" => "answered", "type" => "response_present" } ].freeze

  def setup
    ActionAgent::ScenarioCatalog.destroy_all
    @storage = ActionAgent.active_storage
    ActionAgent.active_storage = :auto
  end

  def teardown
    ActionAgent.active_storage = @storage
  end

  def document(lists = LISTS)
    {
      "catalog" => "support_desk",
      "products" => [ {
        "key" => "triage", "name" => "Triage", "criteria" => lists,
        "sets" => [ {
          "key" => "smoke", "criteria" => SET_CRITERIA,
          "scenarios" => [ { "key" => "order_1", "prompt" => "Where is order 1?" } ]
        } ]
      }.compact ]
    }
  end

  def import(input = document, **options)
    ActionAgent::ScenarioCatalogImport.new(owner: nil, document: input.to_yaml, **options).call
  end

  def preview(input = document, **options)
    ActionAgent::ScenarioCatalogImport.new(owner: nil, document: input.to_yaml, **options).preview
  end

  def product_actions(result)
    result[:changes].select { |change| change[:level] == "product" }.to_h { |change| [ change[:path], change[:action] ] }
  end

  test "a product's named lists survive the database and export as the document imported them" do
    parsed = ActiveAgent::Evals::Catalog.parse(document.to_yaml)
    catalog = import.reload

    assert_equal LISTS, catalog.products.sole.criteria
    assert_equal parsed.to_h, catalog.to_catalog.to_h
    exported = ActiveAgent::Evals::Catalog.parse(catalog.export_yaml)
    assert_equal parsed.to_h, exported.to_h
    assert_equal parsed.digest, exported.digest
    assert_equal catalog.digest, exported.digest
    assert_equal LISTS, YAML.safe_load(catalog.export_yaml(product_ids: [ catalog.products.sole.id ])).dig("products", 0, "criteria")
    assert_equal LISTS, YAML.safe_load(catalog.export_yaml(set_ids: [ catalog.sets.sole.id ])).dig("products", 0, "criteria")
  end

  test "the lists reach a suite of the stored product, alongside the set's own criteria" do
    catalog = import.reload
    suite = catalog.to_catalog.suite_for(:triage)

    assert_equal %w[answered polite], suite.criteria(:shared, :strict).map { |criterion| criterion["key"] }
    assert_equal SET_CRITERIA, catalog.sets.sole.criteria
    assert_equal SET_CRITERIA, catalog.to_catalog.set(:triage, :smoke).criteria
  end

  test "re-importing the same document previews no change and adds no records" do
    import
    result = preview

    assert_equal "unchanged", result.dig(:catalog, :action)
    assert_empty result[:changes]
    assert_equal({ "unchanged" => 3 }, result[:counts])
    import
    assert_equal 1, ActionAgent::ScenarioProduct.count
  end

  test "a changed or removed list previews as an update and replaces the stored lists" do
    import
    changed = LISTS.merge("strict" => [ { "key" => "answered", "type" => "response_present" } ])

    assert_equal({ "triage" => "update" }, product_actions(preview(document(changed))))
    assert_equal changed, import(document(changed)).products.sole.reload.criteria

    only_shared = LISTS.slice("shared")
    assert_equal({ "triage" => "update" }, product_actions(preview(document(only_shared))))
    assert_equal only_shared, import(document(only_shared)).products.sole.reload.criteria

    catalog = import(document(nil))
    assert_equal({}, catalog.products.sole.reload.criteria)
    assert_nil YAML.safe_load(catalog.export_yaml).dig("products", 0).fetch("criteria", nil)
  end

  test "merge mode takes the document's lists as it takes a set's criteria, and a narrowed export merges back unchanged" do
    catalog = import
    set_export = catalog.export_yaml(set_ids: [ catalog.sets.sole.id ])
    merged = ActionAgent::ScenarioCatalogImport.new(owner: nil, document: set_export, mode: "merge")

    assert_empty merged.preview[:changes].reject { |change| change[:action] == "unchanged" }
    assert_equal LISTS, merged.call.products.sole.reload.criteria

    overlay = { "terse" => [ { "key" => "detailed", "type" => "min_length", "config" => { "chars" => 40 } } ] }
    assert_equal({ "triage" => "update" }, product_actions(preview(document(overlay), mode: "merge")))
    assert_equal overlay, import(document(overlay), mode: "merge").products.sole.reload.criteria
    assert_equal SET_CRITERIA, catalog.sets.sole.reload.criteria

    assert_equal({ "triage" => "update" }, product_actions(preview(document(nil), mode: "merge")))
    assert_equal({}, import(document(nil), mode: "merge").products.sole.reload.criteria, "the preview's update is what the import does")
  end

  test "a bare criteria list on a product is stored as the default list" do
    catalog = import(document(SET_CRITERIA))

    assert_equal({ "default" => SET_CRITERIA }, catalog.products.sole.reload.criteria)
    assert_equal catalog.digest, ActiveAgent::Evals::Catalog.parse(catalog.export_yaml).digest
  end

  test "a catalog without product criteria imports, exports and previews as before" do
    catalog = import(document(nil)).reload
    exported = YAML.safe_load(catalog.export_yaml)

    assert_not exported.dig("products", 0).key?("criteria")
    assert_equal ActiveAgent::Evals::Catalog.parse(document(nil).to_yaml).digest, catalog.digest
    assert_empty preview(document(nil))[:changes]
  end

  test "before the migration runs, a catalog imports and exports without the lists" do
    WithoutCriteriaColumn.hidden = true
    catalog = import.reload
    product = catalog.products.sole

    assert_equal({}, product.criteria)
    assert_nil product.read_attribute_before_type_cast(:criteria), "the import writes no lists"
    assert_not YAML.safe_load(catalog.export_yaml).dig("products", 0).key?("criteria")
    assert_equal "Where is order 1?", catalog.scenarios.sole.prompt
  ensure
    WithoutCriteriaColumn.hidden = false
  end

  test "a stored value that is not a mapping of lists reads as no lists" do
    catalog = import
    product = catalog.products.sole
    [ nil, [], "shared", { "shared" => "answered" }, { "shared" => [ "answered" ] } ].each do |stored|
      product.update_column(:criteria, stored)
      product.reload
      assert_equal({}, product.criteria, stored.inspect)
      assert_not product.to_document.key?("criteria"), stored.inspect
    end
  end
end
