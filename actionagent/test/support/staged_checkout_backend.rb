# frozen_string_literal: true

# The mock backend, plus the read-only verbs over a checkout a test staged
# with .stage_checkout. Nothing runs a checkout, so a session nobody staged
# has no changes. Register it under a name and point sandbox_service at it:
#
#   ActionAgent.sandbox_backends = { "staged" => StagedCheckoutBackend.name }
#   ActionAgent.sandbox_service = :staged
class StagedCheckoutBackend < ActionAgent::MockSandboxBackend
  @checkouts = {}
  @checkouts_lock = Mutex.new

  class << self
    # Records the checkout +session_id+ reads as: the commit it was cloned
    # at, that commit's files (+base+) and the working tree's (+working+).
    # Each maps a path to its content, or to { content:, mode: } for a mode
    # other than "100644" (a symlink's content is its target path).
    def stage_checkout(session_id, base_commit:, base: {}, working: {})
      checkout = { base_commit: base_commit, base: normalize_files(base), working: normalize_files(working) }
      @checkouts_lock.synchronize { @checkouts[session_id.to_s] = checkout }
    end

    def staged_checkout(session_id)
      @checkouts_lock.synchronize { @checkouts[session_id.to_s] }
    end

    def reset_checkouts!
      @checkouts_lock.synchronize { @checkouts.clear }
    end

    private

    def normalize_files(files)
      files.to_h do |path, entry|
        entry = { content: entry } unless entry.is_a?(Hash)
        [ path.to_s, { content: entry.fetch(:content).to_s.b, mode: entry[:mode] || "100644" } ]
      end
    end
  end

  # The staged checkout's changes, in the shape
  # SandboxOrchestrator#changed_files describes.
  def changed_files(session)
    checkout = self.class.staged_checkout(session.session_id)
    return { base_commit: nil, files: [] } if checkout.nil?

    base = checkout[:base]
    working = checkout[:working]
    files = (base.keys | working.keys).sort.filter_map do |path|
      before = base[path]
      after = working[path]
      next if before == after

      if after.nil?
        { path: path, status: "deleted", mode: nil, base_mode: before[:mode], size: nil }
      else
        { path: path, status: before ? "modified" : "added", mode: after[:mode], base_mode: before&.dig(:mode), size: after[:content].bytesize }
      end
    end

    { base_commit: checkout[:base_commit], files: files }
  end

  def read_file(session, path, base: false)
    checkout = self.class.staged_checkout(session.session_id)
    checkout&.dig(base ? :base : :working, path, :content)&.dup
  end
end
