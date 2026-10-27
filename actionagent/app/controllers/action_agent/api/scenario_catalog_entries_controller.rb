# frozen_string_literal: true

module ActionAgent
  module Api
    # Editing a scenario catalog in the dashboard, one entry at a time: its
    # products, their sets, and the sets' scenarios. Each change is checked
    # as the YAML importer checks a document (the records' validations, then
    # the catalog's document rebuilt and parsed), rewrites the catalog's
    # document and digest, and writes it to Active Storage when the host has
    # it, so an edit and an import leave the same thing behind.
    #
    # Every change needs :replace_scenarios on the catalog, as an import does.
    # A key left blank is made from the name (or a scenario's prompt).
    class ScenarioCatalogEntriesController < BaseController
      before_action :require_owner!
      before_action :set_catalog
      before_action -> { authorize_action!(:replace_scenarios, @catalog) }

      rescue_from ActiveRecord::RecordInvalid do |error|
        render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
      end
      rescue_from ActiveAgent::Evals::Catalog::InvalidDocument do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end

      # POST /api/scenario_catalogs/:id/products
      # { product: { key, name, description, agent_id, agent_name, project_id } }
      def create_product
        attributes = product_attributes
        attributes[:key] = ScenarioCatalog.key_for(attributes[:name], @catalog.products.pluck(:key)) if attributes[:key].blank?
        attributes[:name] = attributes[:key] if attributes[:name].blank?
        product = change { @catalog.products.create!(attributes.merge(position: next_position(@catalog.products))) }
        render json: { product: product.summary, catalog: full }, status: :created
      end

      # PATCH /api/scenario_catalogs/:id/products/:product_id
      def update_product
        product = find_product
        change { product.update!(product_attributes.compact_blank.merge(product_links)) }
        render json: { product: product.reload.summary, catalog: full }
      end

      # DELETE /api/scenario_catalogs/:id/products/:product_id
      # The evaluations its sets became stay, with their runs.
      def destroy_product
        product = find_product
        change { product.destroy! }
        render json: { catalog: full }
      end

      # POST /api/scenario_catalogs/:id/products/:product_id/sets
      # { set: { key, name, description, judge: { kind, model } } }
      def create_set
        product = find_product
        attributes = set_attributes
        attributes[:key] = ScenarioCatalog.key_for(attributes[:name], product.sets.pluck(:key)) if attributes[:key].blank?
        attributes[:name] = attributes[:key] if attributes[:name].blank?
        set = change { product.sets.create!(attributes.merge(position: next_position(product.sets))) }
        render json: { set: set.summary, catalog: full }, status: :created
      end

      # PATCH /api/scenario_catalogs/:id/sets/:set_id
      def update_set
        set = find_set
        change { set.update!(set_attributes.compact_blank) }
        render json: { set: set.reload.summary, catalog: full }
      end

      # DELETE /api/scenario_catalogs/:id/sets/:set_id
      def destroy_set
        set = find_set
        change { set.destroy! }
        render json: { catalog: full }
      end

      # POST /api/scenario_catalogs/:id/sets/:set_id/scenarios
      # { scenario: { key, prompt, notes, expect: { tools, contains, not_contains }, tags, production_only, enabled } }
      def create_scenario
        set = find_set
        attributes = scenario_attributes
        attributes[:key] = ScenarioCatalog.key_for(attributes[:prompt].to_s.split.first(6).join(" "), set.scenarios.pluck(:key)) if attributes[:key].blank?
        if @catalog.scenario_count >= ScenarioCatalog::MAX_SCENARIOS
          return render json: { errors: [ "A catalog holds at most #{ScenarioCatalog::MAX_SCENARIOS} scenarios" ] }, status: :unprocessable_entity
        end

        scenario = change { set.scenarios.create!(attributes.merge(position: next_position(set.scenarios))) }
        render json: { scenario: scenario.summary, catalog: full }, status: :created
      end

      # PATCH /api/scenario_catalogs/:id/sets/:set_id/scenarios/:scenario_id
      def update_scenario
        scenario = find_set.scenarios.find(params[:scenario_id])
        change { scenario.update!(scenario_attributes.except(*blank_identity(scenario_attributes))) }
        render json: { scenario: scenario.reload.summary, catalog: full }
      end

      # DELETE /api/scenario_catalogs/:id/sets/:set_id/scenarios/:scenario_id
      def destroy_scenario
        scenario = find_set.scenarios.find(params[:scenario_id])
        change { scenario.destroy! }
        render json: { catalog: full }
      end

      private

      def set_catalog
        @catalog = owned(ScenarioCatalog).find(params[:id])
      end

      def find_product
        @catalog.products.find(params[:product_id])
      end

      def find_set
        ScenarioSet.where(scenario_product_id: @catalog.products.select(:id)).find(params[:set_id])
      end

      # Runs +block+ and rebuilds the catalog's document in one transaction,
      # so a change the document cannot hold is rolled back; then writes the
      # document to storage. Returns the block's value.
      def change
        result = ScenarioCatalog.transaction do
          value = yield
          @catalog.reload.refresh_document!
          value
        end
        @catalog.sync_to_storage!
        result
      end

      def full
        ScenarioCatalogSerializer.full(@catalog.reload)
      end

      def next_position(relation)
        (relation.maximum(:position) || -1) + 1
      end

      def product_attributes
        params.require(:product).permit(:key, :name, :description, :agent_name).to_h.symbolize_keys.merge(product_links)
      end

      # The agent and project a product names by id, among the owner's own.
      # An empty id clears it.
      def product_links
        source = params[:product] || {}
        links = {}
        if source.key?(:agent_id)
          links[:agent] = source[:agent_id].present? ? owner_agents.find(source[:agent_id]) : nil
        end
        if source.key?(:project_id)
          links[:project] = source[:project_id].present? ? owned(Project).find(source[:project_id]) : nil
        end
        links
      end

      def set_attributes
        source = params.require(:set)
        attributes = source.permit(:key, :name, :description).to_h.symbolize_keys
        if source.key?(:judge)
          judge = source[:judge].respond_to?(:permit) ? source[:judge].permit(:kind, :model).to_h.compact_blank : {}
          attributes[:judge] = judge
        end
        attributes
      end

      def scenario_attributes
        source = params.require(:scenario)
        attributes = source.permit(:key, :prompt, :notes, :production_only, :enabled).to_h.symbolize_keys
        expect = source[:expect] || source[:expectations]
        if expect.respond_to?(:permit)
          attributes[:expectations] = Exploration::EXPECTATION_KEYS.each_with_object({}) do |name, hash|
            values = Array(expect[name]).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?)
            hash[name] = values if values.any?
          end
        end
        attributes[:tags] = Array(source[:tags]).flat_map { |tag| tag.to_s.split(",") }.map(&:strip).reject(&:blank?) if source.key?(:tags)
        attributes
      end

      # An update leaves the key and prompt alone when they arrive blank,
      # rather than failing presence.
      def blank_identity(attributes)
        %i[key prompt].select { |name| attributes.key?(name) && attributes[name].blank? }
      end
    end
  end
end
