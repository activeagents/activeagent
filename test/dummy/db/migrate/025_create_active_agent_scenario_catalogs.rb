# frozen_string_literal: true

# Scenario catalogs: the YAML catalogs of evaluation scenarios an owner keeps
# in the dashboard, each a set of products (an agent or a project under test)
# with named sets of scenarios. A catalog remembers the document it was
# imported from and its digest, so a re-import of the same file changes
# nothing, and a set remembers the evaluation it was last materialized as.
#
# Table names follow ActionAgent.table_name_prefix, and JSON columns are
# jsonb on PostgreSQL and json elsewhere, the same way as
# create_active_agent_dashboard_tables.
class CreateActiveAgentScenarioCatalogs < ActiveRecord::Migration[7.2]
  def change
    prefix = ActionAgent.table_name_prefix

    create_table "#{prefix}scenario_catalogs" do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      # upload: pasted or uploaded YAML; repository: read from a connected
      # repository at a ref; api: built through the API or MCP tools.
      t.string :source_kind, null: false, default: "upload"
      # For a repository: "owner/name@ref:path".
      t.string :source_path
      # SHA-256 of the canonical document, and the document itself.
      t.string :digest
      t.text :document
      # When the document was last written to Active Storage, and the digest
      # it carried then.
      t.datetime :synced_at
      t.string :synced_digest
      t.column :metadata, json_type, **json_default({})
      t.bigint :account_id
      t.bigint :user_id
      t.timestamps
      t.index :key
      t.index :account_id
      t.index :user_id
    end

    create_table "#{prefix}scenario_products" do |t|
      t.bigint :scenario_catalog_id, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      # What the product's sets run against: a dashboard agent, a project
      # (whose sandbox the replays reach), or neither yet. agent_name keeps
      # the document's `agent:` reference for an agent that is not here.
      t.bigint :agent_id
      t.bigint :project_id
      t.string :agent_name
      t.integer :position
      t.column :metadata, json_type, **json_default({})
      t.timestamps
      t.index [ :scenario_catalog_id, :key ], unique: true
      t.index :agent_id
      t.index :project_id
    end

    create_table "#{prefix}scenario_sets" do |t|
      t.bigint :scenario_product_id, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      # { kind, model }: the judge of the evaluation the set becomes.
      t.column :judge, json_type, **json_default({})
      t.column :criteria, json_type, **json_default([])
      t.column :metadata, json_type, **json_default({})
      # The evaluation this set was last materialized as, if any.
      t.bigint :evaluation_id
      t.integer :position
      t.timestamps
      t.index [ :scenario_product_id, :key ], unique: true
      t.index :evaluation_id
    end

    create_table "#{prefix}catalog_scenarios" do |t|
      t.bigint :scenario_set_id, null: false
      t.string :key, null: false
      t.text :prompt, null: false
      t.text :notes
      t.column :expectations, json_type, **json_default({})
      t.column :tags, json_type, **json_default([])
      t.column :params, json_type, **json_default({})
      t.boolean :production_only, null: false, default: false
      t.boolean :enabled, null: false, default: true
      t.integer :position
      t.timestamps
      t.index [ :scenario_set_id, :key ], unique: true
    end
  end

  private

  def json_type
    @json_type ||= postgres? ? :jsonb : :json
  end

  # MySQL rejects a default on a JSON column outright, so the column is
  # created without one there.
  def json_default(value, null: nil)
    return {} unless postgres?

    null.nil? ? { default: value } : { default: value, null: null }
  end

  def postgres?
    connection.adapter_name.to_s.downcase.include?("postgres")
  end
end
