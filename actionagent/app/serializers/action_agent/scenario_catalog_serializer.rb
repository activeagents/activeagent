# frozen_string_literal: true

module ActionAgent
  # JSON for the catalogs API: a catalog's summary for the index, and the
  # whole tree (products, sets, scenarios) for one catalog.
  module ScenarioCatalogSerializer
    module_function

    def summary(catalog)
      catalog.summary
    end

    def full(catalog)
      products = catalog.products.includes(:agent, :project, sets: [ :scenarios, { evaluation: :evaluation_runs } ])
      catalog.summary.merge(
        metadata: catalog.metadata,
        products: products.map do |product|
          product.summary.merge(sets: product.sets.map { |set| set.summary.merge(scenarios: set.scenarios.map(&:summary)) })
        end
      )
    end
  end
end
