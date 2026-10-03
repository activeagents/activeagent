# frozen_string_literal: true

module ActionAgent
  module Api
    # Opening a pull request from one of the caller's checkout sandboxes
    # (Settings -> Integrations -> Open draft PR): the preview of what would
    # be published, the publish itself, the pull request it opened, and the
    # patch to download where publishing is not available. See
    # DraftPullRequestPublisher for how changes are read, filtered and
    # written.
    #
    # Publishing is an explicit request from a signed-in user: it asks
    # ActionAgent.permission_checker about :publish_pull_request, and
    # DraftPullRequestJob asks again before it writes. Preview, status and
    # patch find the sandbox the way its other endpoints do.
    class DraftPullRequestsController < BaseController
      before_action :require_owner!
      before_action :set_sandbox

      rescue_from DraftPullRequestPublisher::Refused, with: :refused

      # GET /api/sandboxes/:sandbox_id/pull_request — the latest pull request
      # opened from this sandbox (its state read again from GitHub at most
      # once a minute), and whether publishing is available.
      def show
        @sandbox.draft_pull_requests.fail_stalled!
        record = @sandbox.draft_pull_requests.recent.first
        DraftPullRequestPublisher.refresh_status!(record) if record && !record.in_progress?

        render json: { pull_request: record&.summary, publishing: publishing_status }
      end

      # POST /api/sandboxes/:sandbox_id/pull_request/preview { allowlist: [patterns] }
      def preview
        render json: { preview: publisher.preview(allowlist: allowlist_param), publishing: publishing_status }
      end

      # POST /api/sandboxes/:sandbox_id/pull_request
      #
      #   { title:, body:, branch:, files: [{ path:, digest: }], allowlist: }
      #       publishes the files as a new branch and opens a draft pull
      #       request; each digest is the one the preview reported
      #   { update: true, files:, message:, allowlist: }
      #       publishes the files as a new commit on the branch of the latest
      #       pull request, with +message+ as the commit's message; the pull
      #       request's title and description stay as they are
      #   { open: true }
      #       opens a draft pull request for the latest branch that was
      #       published without one
      #   { regular: true }
      #       opens a regular pull request for that branch instead
      #
      # Answers 202 with the queued record, which GET reports on.
      def create
        return open_branch(regular: true) if boolean_param(:regular)
        return open_branch(regular: false) if boolean_param(:open)
        return update_latest if boolean_param(:update)

        record = @sandbox.draft_pull_requests.new(
          operation: "create", repository: @sandbox.repository, branch: string_param(:branch).to_s.strip,
          title: string_param(:title).to_s.strip, body: string_param(:body)
        )
        assign_owner(record)
        return unless authorize_action!(:publish_pull_request, record)

        branch_refusal = DraftPullRequestPublisher.branch_refusal(record.branch)
        raise DraftPullRequestPublisher::Refused.new(branch_refusal, code: "invalid_branch") if branch_refusal

        queue(record, allowlist: allowlist_param)
      end

      # GET /api/sandboxes/:sandbox_id/pull_request/patch?paths[]=…&title=…
      # The chosen files (every publishable one when none are named) as a
      # patch for `git am` or `git apply`.
      def patch
        paths = params[:paths]
        paths = nil unless paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) }
        data = publisher.patch(paths: paths, title: string_param(:title), body: string_param(:body))

        send_data data, type: "text/x-diff", disposition: "attachment",
          filename: "#{@sandbox.repository.tr('/', '-')}-#{@sandbox.session_id.first(8)}.patch"
      end

      private

      # A checkout runs on its account's GitHub access, so in a multi-tenant
      # install it is found within the caller's current account, as
      # CodeSessionsController finds it.
      def set_sandbox
        scope = owned(SandboxSession)
        scope = scope.where(account_id: current_account.id) if current_account
        @sandbox = scope.find_by!(session_id: params[:sandbox_id])
      end

      def publisher
        @publisher ||= DraftPullRequestPublisher.new(@sandbox, user: current_user)
      end

      # A new commit goes only onto the branch of a pull request that is open
      # on GitHub: a branch without one is opened first (see #open_branch).
      def update_latest
        record = @sandbox.draft_pull_requests.recent.where.not(head_commit: nil).first
        if record.nil?
          return render json: { error: "Nothing was published from this sandbox yet", code: "nothing_published" }, status: :unprocessable_entity
        end
        unless record.opened?
          return render json: { error: "The branch #{record.branch} has no pull request yet. Open one for it first", code: "not_opened" },
            status: :unprocessable_entity
        end
        if record.state.in?(%w[closed merged])
          return render json: { error: "The pull request is #{record.state}. Open a new one instead", code: "pull_request_closed" },
            status: :unprocessable_entity
        end

        record.assign_attributes(operation: "update",
          commit_message: string_param(:message).to_s.strip.presence || DraftPullRequest::DEFAULT_UPDATE_MESSAGE)
        assign_owner(record)
        return unless authorize_action!(:publish_pull_request, record)

        queue(record, allowlist: allowlist_param)
      end

      # Opens a pull request for the branch of the latest publish, which was
      # pushed without one: a draft, or with +regular+ a regular one.
      def open_branch(regular:)
        record = @sandbox.draft_pull_requests.recent.first
        unless record&.branch_only?
          return render json: { error: "No branch of this sandbox is waiting to be opened as a pull request", code: "nothing_published" },
            status: :unprocessable_entity
        end

        record.assign_attributes(operation: regular ? "open_regular" : "open_draft")
        assign_owner(record)
        return unless authorize_action!(:publish_pull_request, record)

        queue(record, files: false)
      end

      # Checks the request against the sandbox as it is now, then queues the
      # publish: one at a time per sandbox, under its row lock. A record that
      # is itself queued or publishing is busy too.
      def queue(record, allowlist: nil, files: true)
        refusal = publisher.read_refusal
        raise refusal if refusal

        credential = publisher.credential
        unless credential.available?
          return render json: { error: credential.refusal, code: "no_credential", patch_available: true }, status: :unprocessable_entity
        end

        if files
          selection = selection_param
          changes = publisher.changes(allowlist: allowlist, paths: selection.keys)
          chosen = publisher.select!(changes, selection)
          record.base_commit = changes.base_commit
          record.files = chosen.map { |file| { "path" => file.path, "status" => file.status, "mode" => file.mode, "digest" => file.digest } }
        end
        record.assign_attributes(status: "queued", credential_kind: credential.kind, error_code: nil, error_message: nil)
        return render json: { error: record.errors.full_messages.to_sentence }, status: :unprocessable_entity unless record.valid?

        busy = nil
        @sandbox.with_lock do
          @sandbox.draft_pull_requests.fail_stalled!
          busy = @sandbox.draft_pull_requests.where(status: %w[queued publishing]).first
          record.save! unless busy
        end
        if busy
          return render json: { error: "A publish from this sandbox is already #{busy.status}", pull_request: busy.summary },
            status: :conflict
        end

        DraftPullRequestJob.perform_later(record.id)
        render json: { pull_request: record.summary }, status: :accepted
      end

      # The user who publishes, and the owner: the sandbox's account where
      # the account owns records.
      def assign_owner(record)
        record.user_id = current_user.id if ActionAgent.user_class.present? && current_user.respond_to?(:id)
        record.account_id = @sandbox.account_id if @sandbox.has_attribute?(:account_id) && @sandbox.account_id
      end

      def publishing_status
        refusal = publisher.read_refusal
        credential = refusal ? nil : publisher.credential
        {
          supported: refusal&.code != "unsupported",
          available: refusal.nil? && credential.available?,
          refusal: refusal&.message || credential&.refusal,
          refusal_code: refusal&.code || (credential&.available? == false ? "no_credential" : nil),
          credential: credential&.kind,
          # A patch needs only the live checkout.
          patch_available: refusal.nil?
        }
      end

      # [{ path:, digest: }] as { path => digest }.
      def selection_param
        files = params[:files]
        files = files.map { |file| file.respond_to?(:permit) ? file.permit(:path, :digest).to_h : file } if files.is_a?(Array)
        unless files.is_a?(Array) && files.all? { |file| file.is_a?(Hash) && file["path"].is_a?(String) && file["digest"].is_a?(String) }
          raise DraftPullRequestPublisher::Refused.new("files must be a list of { path, digest } from the preview", code: "nothing_selected")
        end

        files.to_h { |file| [ file["path"], file["digest"] ] }
      end

      def allowlist_param
        allowlist = params[:allowlist]
        return nil if allowlist.nil?
        unless allowlist.is_a?(Array) && allowlist.all? { |pattern| pattern.is_a?(String) && pattern.present? }
          raise DraftPullRequestPublisher::Refused.new("allowlist must be a list of path patterns", code: "not_publishable")
        end

        allowlist
      end

      def string_param(name)
        value = params[name]
        value.is_a?(String) ? value : nil
      end

      def boolean_param(name)
        ActiveModel::Type::Boolean.new.cast(params[name]) == true
      end

      def refused(error)
        status = error.code == "changed_since_preview" ? :conflict : :unprocessable_entity
        render json: { error: error.message, code: error.code, patch_available: patch_offered?(error) }, status: status
      end

      # A patch of the same files fails the same way when they were too
      # many or too large.
      def patch_offered?(error)
        !error.code.in?(%w[unsupported not_live unreadable too_large]) && publisher.read_refusal.nil?
      end
    end
  end
end
