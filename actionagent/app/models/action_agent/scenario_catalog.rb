# frozen_string_literal: true

module ActionAgent
  # A catalog of evaluation scenarios kept in the dashboard: the products an
  # owner evaluates, each with named sets of scenarios, as
  # ActiveAgent::Evals::Catalog reads and writes them.
  #
  # The catalog is imported from a YAML document (pasted, uploaded, read from
  # a connected repository at a ref, or built through the API), keeps the
  # canonical document and its digest, and writes the document to Active
  # Storage when the host has it (see ActionAgent.active_storage), so the
  # scenarios live in the database, in a file a person can version, and in
  # the host's storage, never only in code. A set runs by becoming an
  # evaluation of the agent under test (ScenarioSet#materialize!), so every
  # run's results, traces and recordings are the evaluation's.
  class ScenarioCatalog < ApplicationRecord
    include Ownable
    owned_by :account, :user

    SOURCE_KINDS = %w[upload repository api].freeze
    KEY_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9_.\/-]*\z/
    # Bounds an import: the document's bytes and the scenarios it holds.
    MAX_BYTES = 2.megabytes
    MAX_SCENARIOS = 2000

    has_many :products, -> { order(:position, :id) }, class_name: "ActionAgent::ScenarioProduct",
      foreign_key: :scenario_catalog_id, inverse_of: :catalog, dependent: :destroy

    # The document as last imported or exported, per ActionAgent.active_storage.
    has_one_attached :document_file, **ActionAgent.attachment_options if ActionAgent.active_storage_macros?

    validates :key, presence: true, format: { with: KEY_FORMAT }, length: { maximum: 120 },
      uniqueness: { scope: [ :account_id, :user_id ] }
    validates :name, presence: true, length: { maximum: 200 }
    validates :source_kind, inclusion: { in: SOURCE_KINDS }

    scope :ordered, -> { order(:name, :id) }

    # Whether the document can be written to Active Storage here.
    def self.attachments_available?
      ActionAgent.active_storage_available? && method_defined?(:document_file)
    end

    def metadata
      value = self[:metadata]
      value.is_a?(Hash) ? value : {}
    end

    def sets
      ScenarioSet.where(scenario_product_id: products.select(:id))
    end

    def scenarios
      CatalogScenario.where(scenario_set_id: sets.select(:id))
    end

    def scenario_count
      scenarios.count
    end

    # The catalog as the framework reads it, built from the records.
    # @return [ActiveAgent::Evals::Catalog]
    def to_catalog
      ActiveAgent::Evals::Catalog.new([ to_document ], name: key)
    end

    # The canonical YAML of the records.
    def export_yaml
      to_catalog.to_yaml
    end

    # Rewrites the stored document and digest from the records, after a
    # change made through the API rather than an import.
    def refresh_document!
      catalog = to_catalog
      update!(document: catalog.to_yaml, digest: catalog.digest)
    end

    # Writes the document to Active Storage when the host has it, unless
    # the attached file already carries this digest.
    # @return [Boolean] whether a file is attached now
    def sync_to_storage!
      return false unless self.class.attachments_available?
      return true if document_file.attached? && synced_digest == digest

      document_file.attach(io: StringIO.new(document.to_s), filename: "#{key.tr('/', '-')}.yml", content_type: "application/x-yaml")
      update!(synced_at: Time.current, synced_digest: digest)
      true
    end

    # Replaces the records with the attached document, for a database
    # restored behind its storage.
    # @return [ScenarioCatalog]
    def restore_from_storage!
      raise ActiveRecord::RecordNotFound, "no document is attached to catalog #{key}" unless self.class.attachments_available? && document_file.attached?

      ScenarioCatalogImport.new(owner: owner, document: document_file.download, catalog: self, source_kind: source_kind, source_path: source_path).call
    end

    def synced?
      synced_digest.present? && synced_digest == digest
    end

    def summary
      {
        id: id,
        key: key,
        name: name,
        description: description,
        source_kind: source_kind,
        source_path: source_path,
        digest: digest,
        synced: synced?,
        synced_at: synced_at,
        storage_available: self.class.attachments_available?,
        product_count: products.size,
        scenario_count: scenario_count,
        updated_at: updated_at
      }
    end

    private

    def to_document
      {
        "catalog" => key,
        "name" => name,
        "description" => description,
        "products" => products.includes(sets: :scenarios).map(&:to_document)
      }.merge(metadata).compact
    end
  end
end
