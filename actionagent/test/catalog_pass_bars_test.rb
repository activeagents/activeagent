# frozen_string_literal: true

require "test_helper"

# A catalog product's and set's `pass` bars (PassThresholds) kept by the
# dashboard: stored on import, emitted by the export, compared by the import
# preview, and read back by the stored catalog's pass_thresholds.
class CatalogPassBarsTest < ActiveSupport::TestCase
  # Makes ScenarioProduct and ScenarioSet report no pass column while
  # +hidden+ is set, as an install that has not run add_catalog_pass_bars does.
  module WithoutPassColumn
    mattr_accessor :hidden, default: false

    def has_attribute?(name)
      return false if WithoutPassColumn.hidden && name.to_s == "pass"

      super
    end
  end
  ActionAgent::ScenarioProduct.prepend(WithoutPassColumn)
  ActionAgent::ScenarioSet.prepend(WithoutPassColumn)

  def setup
    ActionAgent::ScenarioCatalog.destroy_all
    @storage = ActionAgent.active_storage
    ActionAgent.active_storage = :auto
  end

  def teardown
    ActionAgent.active_storage = @storage
  end

  def document(product_pass: { "min_pass_rate" => 0.8 }, critical: { "min_pass_rate" => 1.0 }, informational: { "gated" => false })
    {
      "catalog" => "order_suite",
      "products" => [ {
        "key" => "checkout", "pass" => product_pass,
        "sets" => [
          { "key" => "critical", "pass" => critical,
            "scenarios" => [ { "key" => "cannot_charge_twice", "prompt" => "Check duplicate charge." } ] },
          { "key" => "informational", "pass" => informational,
            "scenarios" => [ { "key" => "shipping_eta", "prompt" => "Check shipping ETA." } ] }
        ].map(&:compact)
      }.compact ]
    }
  end

  def import(input = document, **options)
    ActionAgent::ScenarioCatalogImport.new(owner: nil, document: input.to_yaml, **options).call
  end

  def preview(input = document, **options)
    ActionAgent::ScenarioCatalogImport.new(owner: nil, document: input.to_yaml, **options).preview
  end

  def actions(result)
    result[:changes].reject { |change| %w[unchanged keep].include?(change[:action]) }.to_h { |change| [ change[:path], change[:action] ] }
  end

  test "the stored catalog gates a product's sets with the bars the document declared" do
    parsed = ActiveAgent::Evals::Catalog.parse(document.to_yaml)
    catalog = import.reload

    assert_equal parsed.pass_thresholds(:checkout).to_h, catalog.to_catalog.pass_thresholds(:checkout).to_h
    assert_equal parsed.pass_thresholds(:checkout, :critical).to_h, catalog.to_catalog.pass_thresholds(:checkout, :critical).to_h
    thresholds = catalog.to_catalog.pass_thresholds(:checkout)
    assert_equal 0.8, thresholds.min_pass_rate("informational")
    assert_equal 1.0, thresholds.min_pass_rate("critical")
    assert thresholds.gated?("critical")
    assert_not thresholds.gated?("informational")
  end

  test "the bars survive the database and export as the document imported them" do
    parsed = ActiveAgent::Evals::Catalog.parse(document.to_yaml)
    catalog = import.reload
    product = catalog.products.sole

    assert_equal({ "min_pass_rate" => 0.8 }, product.pass)
    assert_equal({ "critical" => { "min_pass_rate" => 1.0 }, "informational" => { "gated" => false } },
      product.sets.to_h { |set| [ set.key, set.pass ] })
    assert_equal parsed.to_h, catalog.to_catalog.to_h
    exported = ActiveAgent::Evals::Catalog.parse(catalog.export_yaml)
    assert_equal parsed.to_h, exported.to_h
    assert_equal catalog.digest, exported.digest
    critical = product.sets.find_by!(key: "critical")
    narrowed = YAML.safe_load(catalog.export_yaml(set_ids: [ critical.id ]))
    assert_equal({ "min_pass_rate" => 0.8 }, narrowed.dig("products", 0, "pass"))
    assert_equal({ "min_pass_rate" => 1.0 }, narrowed.dig("products", 0, "sets", 0, "pass"))
  end

  test "re-importing the same document previews no change" do
    import
    result = preview

    assert_equal "unchanged", result.dig(:catalog, :action)
    assert_empty result[:changes]
    assert_equal({ "unchanged" => 5 }, result[:counts])
  end

  test "a changed or removed bar previews as an update and replaces the stored bars" do
    import
    stricter = document(product_pass: { "min_pass_rate" => 0.9, "threshold" => 0.7 }, informational: nil)

    assert_equal({ "checkout" => "update", "checkout/informational" => "update" }, actions(preview(stricter)))
    catalog = import(stricter)
    assert_equal({ "min_pass_rate" => 0.9, "threshold" => 0.7 }, catalog.products.sole.reload.pass)
    assert_equal({}, catalog.sets.find_by!(key: "informational").pass)
    assert_not YAML.safe_load(catalog.export_yaml).dig("products", 0, "sets", 1).key?("pass")
    assert catalog.to_catalog.pass_thresholds(:checkout).gated?("informational")
  end

  test "merge mode takes the document's bars, and a narrowed export merges back unchanged" do
    catalog = import
    critical = catalog.sets.find_by!(key: "critical")
    merged = ActionAgent::ScenarioCatalogImport.new(owner: nil, document: catalog.export_yaml(set_ids: [ critical.id ]), mode: "merge")

    assert_empty actions(merged.preview)
    merged.call
    assert_equal({ "min_pass_rate" => 1.0 }, critical.reload.pass)
    assert_equal({ "gated" => false }, catalog.sets.find_by!(key: "informational").pass)

    relaxed = document(critical: { "min_pass_rate" => 0.5 })
    relaxed["products"][0]["sets"].pop
    assert_equal({ "checkout/critical" => "update" }, actions(preview(relaxed, mode: "merge")))
    import(relaxed, mode: "merge")
    assert_equal({ "min_pass_rate" => 0.5 }, critical.reload.pass)
    assert_equal({ "gated" => false }, catalog.sets.find_by!(key: "informational").pass)

    bare = document(product_pass: nil, critical: nil, informational: nil)
    assert_equal({ "checkout" => "update", "checkout/critical" => "update", "checkout/informational" => "update" },
      actions(preview(bare, mode: "merge")))
    import(bare, mode: "merge")
    assert_equal({}, catalog.products.sole.reload.pass, "the preview's update is what the import does")
    assert_equal({}, critical.reload.pass)
    assert_equal({}, catalog.sets.find_by!(key: "informational").pass)
  end

  test "a catalog without bars imports, exports and previews as before" do
    bare = document(product_pass: nil, critical: nil, informational: nil)
    catalog = import(bare).reload
    exported = YAML.safe_load(catalog.export_yaml)

    assert_not exported.dig("products", 0).key?("pass")
    assert(exported.dig("products", 0, "sets").none? { |set| set.key?("pass") })
    assert_equal ActiveAgent::Evals::Catalog.parse(bare.to_yaml).digest, catalog.digest
    assert_empty preview(bare)[:changes]
    assert_equal ActiveAgent::Evals::PassThresholds.default.to_h, catalog.to_catalog.pass_thresholds(:checkout).to_h
  end

  test "before the migration runs, a catalog imports and exports without the bars" do
    WithoutPassColumn.hidden = true
    catalog = import.reload

    assert_equal({}, catalog.products.sole.pass)
    assert_nil catalog.products.sole.read_attribute_before_type_cast(:pass), "the import writes no product bars"
    assert(catalog.sets.all? { |set| set.read_attribute_before_type_cast(:pass).nil? }, "the import writes no set bars")
    assert_not YAML.safe_load(catalog.export_yaml).dig("products", 0).key?("pass")
    assert_equal 2, catalog.scenarios.count
  ensure
    WithoutPassColumn.hidden = false
  end

  test "a stored value that is not a mapping reads as no bars" do
    catalog = import
    product = catalog.products.sole
    set = catalog.sets.find_by!(key: "critical")
    [ nil, [], "0.8", 0.8 ].each do |stored|
      product.update_column(:pass, stored)
      set.update_column(:pass, stored)
      assert_equal({}, product.reload.pass, stored.inspect)
      assert_equal({}, set.reload.pass, stored.inspect)
      assert_not product.to_document.key?("pass"), stored.inspect
      assert_not set.to_document.key?("pass"), stored.inspect
    end
  end
end
