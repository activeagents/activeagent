# frozen_string_literal: true

module ActionAgent
  # JSON for one of an agent's versions: what GET /api/agents/:id/versions
  # lists and the MCP facade's agents_versions returns.
  module AgentVersionSerializer
    module_function

    # +include_diff+ adds `diff`, what the version changed from the one
    # before it ({ key => { from:, to: } }), when there is one.
    def call(version, include_diff: false)
      json = {
        id: version.id,
        version_number: version.version_number,
        change_summary: version.change_summary,
        created_by: version.created_by,
        created_at: version.created_at,
        is_latest: version.latest?,
        release: version.release?,
        release_digest: version.release_digest,
        revision: version.revision
      }
      if include_diff && (previous = version.previous)
        json[:diff] = version.diff(previous)
      end
      json
    end
  end
end
