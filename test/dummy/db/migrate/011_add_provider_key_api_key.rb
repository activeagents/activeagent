# frozen_string_literal: true

# Optional Bearer key for a host-based provider (a remote Ollama behind an
# authenticating proxy, or Ollama Cloud), stored beside its host URL. Emitted
# for an install whose dashboard tables predate it; the create-table
# migration carries the column for a fresh install. Guarded, so it is safe
# to re-run.
class AddProviderKeyApiKey < ActiveRecord::Migration[7.2]
  def up
    return unless table_exists?(table)
    return if column_exists?(table, :api_key)

    add_column table, :api_key, :string
  end

  def down
    remove_column table, :api_key if table_exists?(table) && column_exists?(table, :api_key)
  end

  private

  def table
    "#{ActionAgent.table_name_prefix}provider_keys"
  end
end
