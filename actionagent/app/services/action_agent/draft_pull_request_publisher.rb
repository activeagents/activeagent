# frozen_string_literal: true

require "digest"

module ActionAgent
  # Used to open a pull request from a checkout sandbox's changes, through
  # GitHub's Git Data API from the dashboard's own process.
  #
  # No git process ever holds the token it writes with. The sandbox backend
  # only lists and reads files (SandboxOrchestrator#changed_files and
  # #read_file), and the token is minted when the publish runs, limited to
  # the one repository: an installation token with contents and pull request
  # write, or the OAuth connection's token when its own user publishes and
  # its scopes allow writing.
  #
  # A preview, a publish and a patch all read the changes the same way:
  #
  #   1. read: the backend's changed files since the checkout commit, with
  #      their content now and in that commit
  #   2. filter: a path outside the caller's allowlist or under .github/, a
  #      symlink, a submodule, or a file over MAX_FILE_BYTES is refused
  #   3. scan: a file holding one of the sandbox's secrets, or anything shaped
  #      like a GitHub token, is refused
  #
  # A refused file is named with the reason and never published. A publish
  # then writes blobs, a tree on the checkout commit's tree, a commit with the
  # checkout commit as its parent, a branch that did not exist, and a draft
  # pull request (see DraftPullRequest for its operations).
  class DraftPullRequestPublisher
    # A publish, preview or patch that cannot go ahead. +code+ is a word the
    # dashboard acts on:
    #
    #   unsupported            the backend or sandbox cannot be read
    #   not_live               the sandbox is not ready or running
    #   unreadable             the backend failed to read the changes
    #   nothing_selected       no file was chosen
    #   not_publishable        a chosen file is refused (see FILE_REFUSALS)
    #   secret                 a chosen file holds a secret
    #   changed_since_preview  a chosen file differs from its preview
    #   too_large              the chosen files exceed MAX_TOTAL_BYTES
    #   invalid_branch         the branch name is not one git allows
    #   branch_exists          the branch already exists on GitHub
    #   branch_moved           the branch to update has commits the dashboard
    #                          did not publish, or is gone
    #   no_credential          nothing can write to the repository
    #   write_refused          GitHub refused a write (403, 404) or the token
    #   github_error           GitHub failed otherwise
    class Refused < StandardError
      attr_reader :code

      def initialize(message, code:)
        super(message)
        @code = code
      end
    end

    MAX_FILE_BYTES = 1024 * 1024
    MAX_TOTAL_BYTES = 10 * 1024 * 1024
    MAX_FILES = 300
    MAX_BRANCH_LENGTH = 200
    WRITE_PERMISSIONS = { contents: "write", pull_requests: "write" }.freeze
    STATUS_PERMISSIONS = { pull_requests: "read" }.freeze
    PUBLISHABLE_MODES = %w[100644 100755].freeze
    # Why a changed file is refused, as the dialog words it.
    FILE_REFUSALS = {
      "excluded" => "files under .github/ are never published",
      "not_allowed" => "not in the files chosen to publish",
      "symlink" => "symlinks are not published",
      "submodule" => "submodules are not published",
      "unsupported_mode" => "only regular files are published",
      "too_large" => "larger than #{MAX_FILE_BYTES / 1024 / 1024} MB",
      "unreadable" => "could not be read",
      "secret" => "contains a secret of this sandbox or a GitHub token",
      "over_total" => "the files before it already hold more than one publish can carry"
    }.freeze

    # A changed file, its content now and in the checkout commit, and why it
    # is refused (a FILE_REFUSALS key), or nil when it may be published.
    ChangedFile = Struct.new(:path, :status, :mode, :base_mode, :size, :content, :base_content, :refusal, keyword_init: true) do
      def publishable? = refusal.nil?
      def deleted? = status == "deleted"

      # What the dialog previewed of this file. A publish is refused when
      # the file no longer matches it.
      def digest
        Digest::SHA256.hexdigest("#{status}\0#{mode}\0".b + content.to_s.b)
      end

      # This file as SandboxPatch takes a change.
      def to_change
        { path: path, status: status, mode: mode, base_mode: base_mode, content: content, base_content: base_content }
      end
    end

    # The changes of a sandbox: the commit it checked out, and its files.
    Changes = Struct.new(:base_commit, :files, keyword_init: true) do
      def publishable = files.select(&:publishable?)
    end

    # How a publish writes to the repository: through an installation
    # ("app") or the OAuth connection ("oauth"); or +refusal+, why neither
    # can.
    Credential = Struct.new(:kind, :installation, :connection, :repository_id, :refusal, keyword_init: true) do
      def available? = refusal.nil?
    end

    class << self
      # Why +name+ cannot be a branch, or nil: the rules of
      # git-check-ref-format, and at most MAX_BRANCH_LENGTH characters.
      def branch_refusal(name)
        return "Name the branch" unless name.is_a?(String) && name.present?
        return "A branch name is at most #{MAX_BRANCH_LENGTH} characters" if name.length > MAX_BRANCH_LENGTH

        valid = name.ascii_only? &&
          !name.match?(%r{[\x00-\x20\x7f~^:?*\[\\]|\.\.|@\{|//|\A[/-]|/\z|\.\z|\A@\z}) &&
          name.split("/").none? { |part| part.start_with?(".") || part.end_with?(".lock") }
        valid ? nil : "#{name.inspect} is not a valid branch name"
      end

      # Reads +record+'s pull request again when it was last read at least
      # DraftPullRequest::STATUS_REFRESH_INTERVAL ago, with a token that can
      # read pull requests and nothing else. A failure keeps what was known.
      #
      # @return [DraftPullRequest] +record+
      def refresh_status!(record)
        return record unless record.claim_status_refresh!

        client = status_client(record)
        return record if client.nil?

        pull = client.pull_request(record.repository, record.number)
        record.update_columns(state: pull_state(pull), draft: pull["draft"] == true)
        record
      rescue GithubClient::Error => e
        Rails.logger.warn("[ActionAgent] could not refresh pull request #{record.repository}##{record.number}: #{e.message}")
        record
      end

      def pull_state(pull)
        pull["merged"] == true || pull["merged_at"].present? ? "merged" : pull["state"].to_s
      end

      private

      def status_client(record)
        sandbox = record.sandbox_session
        if record.credential_kind == "app"
          installation = sandbox&.checkout_installation
          repo = installation&.repository(record.repository)
          return nil unless ActionAgent.github_app_configured? && repo && installation.usable?

          GithubClient.new(installation.mint_token!(permissions: STATUS_PERMISSIONS, repository_ids: [ repo["id"] ]))
        else
          sandbox&.github_connection&.client
        end
      end
    end

    attr_reader :sandbox

    # +user+ is who publishes: the OAuth connection writes only for the user
    # who connected it.
    def initialize(sandbox, user: nil, orchestrator: nil)
      @sandbox = sandbox
      @user = user
      @orchestrator = orchestrator || SandboxOrchestrator.new
    end

    def repository
      sandbox.repository
    end

    # Why the sandbox's changes cannot be read now, or nil.
    #
    # @return [Refused, nil]
    def read_refusal
      return Refused.new("Pull requests are opened from checkout sandboxes only", code: "unsupported") unless sandbox.app_runtime?
      unless @orchestrator.supports?(:changed_files) && @orchestrator.supports?(:read_file)
        return Refused.new("The #{@orchestrator.backend_name} sandbox backend cannot read a sandbox's files", code: "unsupported")
      end
      unless @orchestrator.reads_checkouts?
        return Refused.new("The #{@orchestrator.backend_name} sandbox backend cannot read the commit a checkout was cloned at",
          code: "unsupported")
      end
      return nil if (sandbox.ready? || sandbox.running?) && sandbox.active?

      state = sandbox.ready? || sandbox.running? ? "expired" : sandbox.status
      Refused.new("The sandbox is #{state}. Publishing reads its live checkout, so start a new sandbox to publish", code: "not_live")
    end

    # Every file the sandbox changed, each read, filtered and scanned.
    # +allowlist+ holds the patterns a path must match to be published
    # (File.fnmatch patterns, where "dir/**" matches everything under dir);
    # nil allows every path.
    #
    # @raise [Refused]
    # @return [Changes]
    def changes(allowlist: nil)
      refusal = read_refusal
      raise refusal if refusal

      listing = @orchestrator.changed_files(sandbox)
      base_commit = listing[:base_commit]
      raise Refused.new("The sandbox did not record the commit it checked out", code: "unsupported") unless commit_id?(base_commit)

      files = Array(listing[:files]).map do |entry|
        file = ChangedFile.new(
          path: entry[:path].to_s, status: entry[:status].to_s, mode: entry[:mode], base_mode: entry[:base_mode], size: entry[:size]
        )
        file.refusal = path_refusal(file.path, allowlist) || kind_refusal(file)
        file
      end
      candidates = files.count(&:publishable?)
      if candidates > MAX_FILES
        raise Refused.new("The sandbox changed #{candidates} files that could be published; at most #{MAX_FILES} can be published at once",
          code: "too_large")
      end

      secrets = scan_values
      budget = MAX_TOTAL_BYTES * 2
      files = files.filter_map do |file|
        next file unless file.publishable?

        if budget.negative?
          file.refusal = "over_total"
          next file
        end
        read_contents(file, secrets)&.tap { budget -= file.content.to_s.bytesize + file.base_content.to_s.bytesize }
      end
      Changes.new(base_commit: base_commit, files: files)
    rescue Refused
      raise
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] could not read the changes of sandbox #{sandbox.session_id}: #{e.class}: #{e.message}")
      raise Refused.new("The sandbox's changes could not be read: #{e.message}", code: "unreadable")
    end

    # What the dialog shows before a publish: every changed file with its
    # refusal, and for each one that may be published its diff and digest.
    def preview(allowlist: nil)
      changes = self.changes(allowlist: allowlist)
      files = changes.files.map do |file|
        entry = {
          path: file.path, status: file.status, mode: file.mode, base_mode: file.base_mode,
          size: file.content&.bytesize || file.size,
          refusal: file.refusal, refusal_message: file.refusal && FILE_REFUSALS[file.refusal]
        }
        next entry unless file.publishable?

        binary = SandboxPatch.binary?(file.content) || SandboxPatch.binary?(file.base_content)
        entry.merge(
          binary: binary,
          digest: file.digest,
          diff: binary ? nil : SandboxPatch.file_diff(file.to_change).force_encoding(Encoding::UTF_8).scrub
        )
      end

      {
        repository: repository,
        base_commit: changes.base_commit,
        files: files,
        suggested_branch: "activeagent/sandbox-#{sandbox.session_id.to_s.first(8)}",
        limits: { max_file_bytes: MAX_FILE_BYTES, max_total_bytes: MAX_TOTAL_BYTES, max_files: MAX_FILES }
      }
    end

    # The files of +changes+ that +selection+ ({ path => digest }, as the
    # preview reported them) chose.
    #
    # @raise [Refused] when nothing is chosen, a chosen file is refused or
    #   changed since the preview, or the files exceed MAX_TOTAL_BYTES
    # @return [Array<ChangedFile>]
    def select!(changes, selection)
      raise Refused.new("Choose at least one file to publish", code: "nothing_selected") if selection.blank?

      by_path = changes.files.index_by(&:path)
      files = selection.map do |path, digest|
        file = by_path[path]
        raise Refused.new("#{path} has no changes any more. Reload the preview", code: "changed_since_preview") if file.nil?

        unless file.publishable?
          code = file.refusal == "secret" ? "secret" : "not_publishable"
          raise Refused.new("#{path} cannot be published: #{FILE_REFUSALS[file.refusal]}", code: code)
        end
        raise Refused.new("#{path} changed since the preview. Reload it", code: "changed_since_preview") unless digest == file.digest

        file
      end
      total = files.sum { |file| file.content.to_s.bytesize }
      if total > MAX_TOTAL_BYTES
        raise Refused.new("The chosen files hold #{total} bytes; at most #{MAX_TOTAL_BYTES} can be published at once", code: "too_large")
      end

      files
    end

    # A patch of the publishable files named by +paths+ (all of them when
    # nil), for `git am` or `git apply`. Built from the backend's reads,
    # with no GitHub token.
    #
    # @raise [Refused] when a named file is refused or unchanged
    # @return [String] binary-encoded
    def patch(paths: nil, title: nil, body: nil)
      changes = self.changes
      files = if paths.nil?
        changes.publishable
      else
        unknown = paths - changes.files.map(&:path)
        raise Refused.new("#{unknown.first} has no changes in this sandbox", code: "changed_since_preview") if unknown.any?

        select!(changes, changes.files.select { |file| paths.include?(file.path) }.to_h { |file| [ file.path, file.digest ] })
      end
      raise Refused.new("The sandbox has no changes that can be published", code: "nothing_selected") if files.empty?

      SandboxPatch.format_patch(files.map(&:to_change), subject: title.presence || "Changes from a sandbox of #{repository}",
        body: body, base_commit: changes.base_commit)
    end

    # How a publish by the user would write to the repository: the
    # installation the sandbox checked out through, when the App is
    # configured and the installation can write; otherwise the OAuth
    # connection, when the user is the one who connected it and its scopes
    # allow writing to the repository.
    #
    # @return [Credential]
    def credential
      installation = writing_installation
      if installation
        return Credential.new(kind: "app", installation: installation, repository_id: installation.repository(repository)["id"])
      end

      connection = sandbox.github_connection
      if connection.nil? || connection.repository(repository).nil?
        return Credential.new(refusal: "No GitHub App installation or OAuth connection of this workspace can write to #{repository}")
      end

      refusal = oauth_refusal(connection)
      refusal ? Credential.new(refusal: refusal) : Credential.new(kind: "oauth", connection: connection)
    end

    # Runs +record+'s publish and records on it how it went: published,
    # draft_refused, or failed with an error code (see Refused). With
    # +allow_non_draft+, a pull request GitHub refuses to open as a draft is
    # opened as a regular one.
    #
    # @return [DraftPullRequest] +record+
    def publish!(record, allow_non_draft: false)
      record.update!(status: "publishing", error_code: nil, error_message: nil)
      refusal = read_refusal
      raise refusal if refusal

      credential = self.credential
      raise Refused.new(credential.refusal, code: "no_credential") unless credential.available?

      client = writing_client(credential)
      record.update!(credential_kind: credential.kind, base_branch: record.base_branch || base_branch(client))
      if record.operation == "open_regular"
        open_pull_request!(record, client, draft: false)
      else
        push!(record, client)
        record.operation == "create" ? open_pull_request!(record, client, draft: true, allow_non_draft: allow_non_draft) : record.update!(status: "published")
      end
      record
    rescue Refused => e
      record.update!(status: "failed", error_code: e.code, error_message: e.message)
      record
    rescue GithubClient::InstallationUnavailable => e
      record.update!(status: "failed", error_code: "no_credential",
        error_message: "#{e.message}: reinstall the GitHub App, or Check again in Settings -> Integrations")
      record
    rescue GithubClient::Unauthorized
      record.update!(status: "failed", error_code: "no_credential",
        error_message: "GitHub rejected the token. Reconnect GitHub in Settings -> Integrations")
      record
    rescue GithubClient::Error => e
      code = e.status.in?([ 403, 404 ]) ? "write_refused" : "github_error"
      record.update!(status: "failed", error_code: code, error_message: "GitHub refused the publish: #{e.message}")
      record
    end

    private

    # +file+ with its contents read and scanned, or nil when it no longer
    # differs from the checkout commit.
    def read_contents(file, secrets)
      return file.tap { file.refusal = "too_large" } if file.size.to_i > MAX_FILE_BYTES

      begin
        file.content = @orchestrator.read_file(sandbox, file.path) unless file.deleted?
        file.base_content = @orchestrator.read_file(sandbox, file.path, base: true) unless file.status == "added"
      rescue StandardError => e
        Rails.logger.info("[ActionAgent] could not read #{file.path} from sandbox #{sandbox.session_id}: #{e.message}")
        return file.tap { file.refusal = "unreadable" }
      end
      # Gone or reverted since it was listed.
      return nil if file.deleted? ? file.base_content.nil? : file.content.nil?
      return nil if file.status == "modified" && file.content == file.base_content && file.mode == (file.base_mode || file.mode)

      if [ file.content, file.base_content ].any? { |content| content.to_s.bytesize > MAX_FILE_BYTES }
        file.refusal = "too_large"
      elsif secret?(file.content, secrets)
        file.refusal = "secret"
      end
      file
    end

    def path_refusal(path, allowlist)
      return "excluded" if path.split("/").first.to_s.casecmp?(".github")
      return nil if allowlist.nil?

      flags = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB
      allowlist.any? { |pattern| File.fnmatch?(glob(pattern), path, flags) } ? nil : "not_allowed"
    end

    # +pattern+ as File.fnmatch reads it, with a trailing "/**" matching
    # everything under the directory: "app/**" -> "app/**/*".
    def glob(pattern)
      pattern.end_with?("/**") ? "#{pattern}/*" : pattern
    end

    def kind_refusal(file)
      modes = [ file.mode, file.base_mode ].compact
      return "symlink" if modes.include?("120000")
      return "submodule" if modes.include?("160000")
      return "unsupported_mode" unless file.deleted? || PUBLISHABLE_MODES.include?(file.mode)

      nil
    end

    # The values a published file must not contain: everything the
    # sandbox's own output is scrubbed of, and the OAuth connection's token.
    def scan_values
      values = sandbox.secret_values
      values << sandbox.github_connection&.access_token
      values.compact.map(&:to_s).select { |value| value.length >= SecretScrubber::MIN_SECRET_LENGTH }.map(&:b).uniq
    end

    def secret?(content, secrets)
      return false if content.nil?

      content = content.b
      secrets.any? { |secret| content.include?(secret) } || content.match?(SecretScrubber::GITHUB_TOKEN)
    end

    def writing_installation
      return nil unless ActionAgent.github_app_configured?

      installation = sandbox.checkout_installation
      return nil unless installation&.usable? && installation.repository(repository)

      granted = installation.permissions
      return installation if granted.empty?

      WRITE_PERMISSIONS.all? { |name, level| granted[name.to_s] == level } ? installation : nil
    end

    # Why the OAuth connection cannot publish for the user, or nil. Where
    # the host has a user model, only the user who connected it may; a
    # connection made before the dashboard recorded that user must be
    # connected again.
    def oauth_refusal(connection)
      if ActionAgent.user_class.present?
        if connection.user_id.nil?
          return "The OAuth connection does not record who connected it. Reconnect GitHub in Settings -> Integrations to publish with it"
        end
        unless @user.respond_to?(:id) && @user.id.to_s == connection.user_id.to_s
          return "Only the user who connected GitHub (@#{connection.login}) can publish through the OAuth connection"
        end
      end

      scopes = connection.scopes.to_s.split(/[\s,]+/).reject(&:blank?)
      return nil if scopes.include?("repo")
      return nil if scopes.include?("public_repo") && connection.repository(repository)["private"] == false

      "The OAuth connection's scopes (#{scopes.join(', ').presence || 'none'}) do not allow writing to #{repository}. " \
        "Reconnect GitHub with the repo scope"
    end

    def writing_client(credential)
      return credential.connection.client if credential.kind == "oauth"

      GithubClient.new(credential.installation.mint_token!(permissions: WRITE_PERMISSIONS, repository_ids: [ credential.repository_id ]))
    rescue GithubClient::InstallationUnavailable
      raise
    rescue GithubClient::Error => e
      raise unless e.status == 422

      raise Refused.new("The GitHub App installation cannot write to #{repository}: #{e.message}", code: "write_refused")
    end

    # The branch the sandbox checked out, or the repository's default branch
    # when it checked out a tag or a commit.
    def base_branch(client)
      ref = sandbox.repository_ref
      return ref if ref.present? && client.branch_head(repository, ref)

      repo = sandbox.checkout_installation&.repository(repository) || sandbox.github_connection&.repository(repository)
      repo&.dig("default_branch").presence || "main"
    end

    # Writes the chosen files as a commit and points the branch at it: a new
    # branch for a create, a fast-forward for an update.
    def push!(record, client)
      changes = self.changes
      unless changes.base_commit == record.base_commit
        raise Refused.new("The sandbox's checkout commit is not the one previewed. Reload the preview", code: "changed_since_preview")
      end

      files = select!(changes, record.files.to_h { |file| [ file["path"], file["digest"] ] })
      parent = expected_parent!(record, client)
      base_tree = begin
        client.commit_tree(record.repository, record.base_commit)
      rescue GithubClient::Error => e
        raise unless e.status.in?([ 404, 422 ])

        raise Refused.new("GitHub has no commit #{record.base_commit}, which the sandbox checked out", code: "github_error")
      end

      entries = files.map do |file|
        sha = file.deleted? ? nil : client.create_blob(record.repository, file.content)
        { path: file.path, mode: file.mode || "100644", sha: sha }
      end
      tree = client.create_tree(record.repository, base_tree: base_tree, entries: entries)
      commit = client.create_commit(record.repository, message: commit_message(record), tree: tree, parents: [ parent ])
      point_branch!(record, client, commit)
      record.update!(head_commit: commit)
    end

    # The commit the new one goes on top of: the checkout commit for a new
    # branch, which must not exist yet, or the branch's head for an update,
    # which must be the commit this record last published.
    def expected_parent!(record, client)
      head = client.branch_head(record.repository, record.branch)
      if record.operation == "create"
        raise Refused.new("A branch named #{record.branch} already exists on GitHub. Choose another name", code: "branch_exists") if head
        return record.base_commit
      end

      if head.nil?
        raise Refused.new("The branch #{record.branch} no longer exists on GitHub", code: "branch_moved")
      elsif head != record.head_commit
        raise Refused.new("The branch #{record.branch} has commits that were not published from this sandbox, so it was not updated",
          code: "branch_moved")
      end
      head
    end

    def point_branch!(record, client, commit)
      if record.operation == "create"
        client.create_branch(record.repository, record.branch, commit)
      else
        client.fast_forward_branch(record.repository, record.branch, commit)
      end
    rescue GithubClient::Error => e
      raise unless e.status == 422

      if record.operation == "create"
        raise Refused.new("A branch named #{record.branch} already exists on GitHub. Choose another name", code: "branch_exists")
      end
      raise Refused.new("The branch #{record.branch} moved while it was updated, so it was not updated", code: "branch_moved")
    end

    def open_pull_request!(record, client, draft:, allow_non_draft: false)
      pull = client.create_pull_request(record.repository, title: record.title, body: record.body, head: record.branch,
        base: record.base_branch, draft: draft)
      record.update!(
        status: "published", number: pull["number"], url: pull["html_url"], state: self.class.pull_state(pull),
        draft: pull["draft"] == true, last_checked_at: Time.current, compare_url: nil, error_code: nil, error_message: nil
      )
    rescue GithubClient::Error => e
      raise unless draft && e.status == 422 && e.message.match?(/draft/i)
      return open_pull_request!(record, client, draft: false) if allow_non_draft

      record.update!(
        status: "draft_refused", compare_url: compare_url(record), error_code: "draft_refused",
        error_message: "GitHub does not open draft pull requests in #{record.repository}. The branch #{record.branch} is published: " \
          "open it as a regular pull request, or compare it on GitHub"
      )
    end

    def commit_message(record)
      [ record.title, record.body.presence ].compact.join("\n\n")
    end

    def compare_url(record)
      encode = ->(ref) { ref.split("/").map { |part| ERB::Util.url_encode(part) }.join("/") }
      "#{GithubClient::WEB}/#{record.repository}/compare/#{encode.call(record.base_branch)}...#{encode.call(record.branch)}?expand=1"
    end

    def commit_id?(value)
      value.is_a?(String) && value.match?(GithubClient::OBJECT_ID)
    end
  end
end
