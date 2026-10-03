# frozen_string_literal: true

module ActionAgent
  module Api
    # The project's install pull request (see ProjectInstallPullRequest): its
    # status, the preview of exactly what it would publish, publishing it and
    # updating its branch later, and the patch to download where publishing
    # is not available.
    #
    # Everything is read from the project's live sandbox. A request made
    # while none is live boots one (Project#ensure_sandbox!) and answers 202,
    # to be asked again once it serves. Publishing is an explicit request
    # that asks ActionAgent.permission_checker about :publish_pull_request,
    # as DraftPullRequestJob asks again before it writes.
    class ProjectInstallPullRequestsController < BaseController
      before_action :require_owner!
      before_action :set_project

      rescue_from DraftPullRequestPublisher::Refused, with: :refused
      rescue_from Project::ConfirmationRequired, with: :confirmation_required
      rescue_from Project::BootRefused, SandboxOrchestrator::UnsupportedBackendError, with: :boot_refused

      # GET /api/projects/:project_id/install_pull_request
      # The install pull request, its state read again from GitHub at most
      # once a minute. Once GitHub reports it merged, the project counts as
      # installed (Project#install_merged!).
      def show
        record = @project.install_pull_request
        if record
          DraftPullRequest.where(id: record.id).fail_stalled!
          record.reload
          DraftPullRequestPublisher.refresh_status!(record) unless record.in_progress?
          @project.install_merged! if record.state == "merged"
        end

        render json: { pull_request: record&.summary, publishing: publishing_status, allowlist: allowlist_json,
                       project: @project.reload.summary }
      end

      # POST /api/projects/:project_id/install_pull_request/preview
      # Every file the sandbox changed or the project generates, each with why
      # it is refused or with its exact diff.
      def preview
        return unless live_sandbox!

        preview = install.publisher(@sandbox).preview(allowlist: install.allowlist)
        preview[:suggested_branch] = ProjectInstallPullRequest::DEFAULT_BRANCH
        render json: { preview: preview, publishing: publishing_status }
      end

      # POST /api/projects/:project_id/install_pull_request
      #
      #   { title:, body:, branch:, files: [{ path:, digest: }] }
      #       opens the install pull request as a draft, with the files
      #   { update: true, files:, message: }
      #       publishes the files as a new commit on its branch, from the
      #       project's sandbox now, which may be a later one than the
      #       sandbox it was opened from
      #   { open: true } or { regular: true }
      #       opens a draft, or a regular, pull request for its branch when
      #       the branch was published without one
      #
      # Answers 202 with the queued record.
      def create
        return unless live_sandbox!
        return open_branch(regular: boolean_param(:regular)) if boolean_param(:open) || boolean_param(:regular)

        on_branch = false
        if boolean_param(:update)
          record = update_record or return
          on_branch = record.new_record? && @sandbox.repository_ref == record.branch
        else
          return unless openable!

          record = @sandbox.draft_pull_requests.new(
            operation: "create", repository: @sandbox.repository, branch: string_param(:branch).to_s.strip.presence ||
              ProjectInstallPullRequest::DEFAULT_BRANCH,
            title: string_param(:title).to_s.strip.presence || "Install ActiveAgent", body: string_param(:body)
          )
          refusal = DraftPullRequestPublisher.branch_refusal(record.branch)
          raise DraftPullRequestPublisher::Refused.new(refusal, code: "invalid_branch") if refusal
        end
        assign_owner(record)
        return unless authorize_action!(:publish_pull_request, record)

        queue(record, on_branch: on_branch)
      end

      # GET /api/projects/:project_id/install_pull_request/patch?paths[]=…
      # The files named, or every publishable one, each within the project's
      # allowlist.
      def patch
        return unless live_sandbox!

        paths = params[:paths]
        paths = nil unless paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) }
        paths ||= install.publisher(@sandbox).changes(allowlist: install.allowlist).publishable.map(&:path)
        data = install.publisher(@sandbox).patch(paths: paths, title: string_param(:title) || "Install ActiveAgent", allowlist: install.allowlist)
        send_data data, type: "text/x-diff", disposition: "attachment", filename: "#{@project.repository.tr('/', '-')}-install.patch"
      end

      private

      def set_project
        @project = owned(Project).find(params[:project_id])
      end

      def install
        @install ||= ProjectInstallPullRequest.new(@project, user: current_user)
      end

      # The project's sandbox when it serves; otherwise boots one, renders
      # 202 and answers false.
      def live_sandbox!
        sandbox = @project.current_sandbox_session
        if sandbox && (sandbox.ready? || sandbox.running?) && sandbox.active?
          @sandbox = sandbox
          return true
        end

        unless ActionAgent.execution_enabled?
          render json: { error: "The project's sandbox is not running, and agent execution is disabled on this dashboard" },
            status: :forbidden
          return false
        end
        enforce_execution_quota!
        return false if performed?

        before = @project.current_sandbox_session_id
        booting = @project.ensure_sandbox!(confirm: ActiveModel::Type::Boolean.new.cast(params[:confirm]) == true, confirmed_by: current_user)
        record_execution_usage if booting.id != before
        render json: { booting: true, code: "sandbox_booting", project: @project.reload.summary,
                       error: "The project's sandbox is booting. Publishing reads its checkout, so ask again once it is ready" },
          status: :accepted
        false
      end

      # Whether a new install pull request may be opened: not while one is
      # open, or its branch is published without one.
      def openable!
        current = @project.install_pull_request
        return true if current.nil? || (current.head_commit.blank? && !current.in_progress?) || current.state.in?(%w[closed merged])

        error = if current.branch_only?
          "The install branch is published without a pull request. Open a pull request for it instead"
        else
          "The project has an install pull request already. Update it instead"
        end
        render json: { error: error, code: "already_opened", pull_request: current.summary }, status: :conflict
        false
      end

      # The record an update publishes: the install pull request itself when
      # the sandbox it was published from is the one live now, and otherwise
      # a record of the live sandbox for the same pull request. A sandbox of
      # the pull request's branch starts from the commit it checked out, so
      # the update goes on top of the branch as that sandbox saw it.
      def update_record
        current = @project.install_pull_request
        unless current&.opened? && current.state.in?([ nil, "open" ])
          render json: { error: "The project has no open install pull request to update", code: "not_opened" }, status: :unprocessable_entity
          return nil
        end

        message = string_param(:message).to_s.strip.presence || DraftPullRequest::DEFAULT_UPDATE_MESSAGE
        return current.tap { current.assign_attributes(operation: "update", commit_message: message) } if current.sandbox_session_id == @sandbox.id

        @sandbox.draft_pull_requests.new(
          current.attributes.slice(*%w[repository base_branch branch title body number url state draft head_commit compare_url])
            .merge("operation" => "update", "commit_message" => message, "status" => "queued")
        )
      end

      # Opens a pull request for the install branch, which was published
      # without one.
      def open_branch(regular:)
        record = @project.install_pull_request
        unless record&.branch_only? && !record.in_progress?
          return render json: { error: "The install branch is not waiting to be opened as a pull request", code: "nothing_published" },
            status: :unprocessable_entity
        end

        record.assign_attributes(operation: regular ? "open_regular" : "open_draft")
        assign_owner(record)
        return unless authorize_action!(:publish_pull_request, record)

        queue(record, files: false)
      end

      # Checks the files against the preview and queues the publish, one at a
      # time per sandbox, then makes the record the project's install pull
      # request. A choice that leaves out a file the branch's boots need
      # (ProjectInstallPullRequest#missing_required_paths) is refused.
      # +on_branch+ is a record of a sandbox that checked out the pull
      # request's branch, whose checkout commit is the head it updates.
      def queue(record, on_branch: false, files: true)
        publisher = install.publisher(@sandbox)
        refusal = publisher.read_refusal
        raise refusal if refusal

        credential = publisher.credential
        unless credential.available?
          return render json: { error: credential.refusal, code: "no_credential", patch_available: true }, status: :unprocessable_entity
        end

        if files
          selection = selection_param
          missing = install.missing_required_paths(publisher, selection.keys)
          if missing.any?
            raise DraftPullRequestPublisher::Refused.new("Every boot of the branch needs #{missing.to_sentence}, which the sandbox " \
              "changed: choose #{missing.one? ? "it" : "them"} too", code: "incomplete_install")
          end

          changes = publisher.changes(allowlist: install.allowlist, paths: selection.keys)
          chosen = publisher.select!(changes, selection)
          record.base_commit = changes.base_commit
          record.head_commit = changes.base_commit if on_branch
          record.files = chosen.map { |file| { "path" => file.path, "status" => file.status, "mode" => file.mode, "digest" => file.digest } }
        end
        record.assign_attributes(status: "queued", credential_kind: credential.kind, error_code: nil, error_message: nil)
        return render json: { error: record.errors.full_messages.to_sentence }, status: :unprocessable_entity unless record.valid?

        busy = nil
        @sandbox.with_lock do
          @sandbox.draft_pull_requests.fail_stalled!
          busy = @sandbox.draft_pull_requests.where(status: %w[queued publishing]).first
          unless busy
            record.save!
            @project.update!(settings: @project.settings.merge("install_pull_request_id" => record.id))
          end
        end
        if busy
          return render json: { error: "A publish from this sandbox is already #{busy.status}", pull_request: busy.summary }, status: :conflict
        end

        DraftPullRequestJob.perform_later(record.id)
        render json: { pull_request: record.summary, project: @project.reload.summary }, status: :accepted
      end

      def assign_owner(record)
        record.user_id = current_user.id if ActionAgent.user_class.present? && current_user.respond_to?(:id)
        record.account_id = @sandbox.account_id if @sandbox.has_attribute?(:account_id) && @sandbox.account_id
      end

      def publishing_status
        sandbox = @project.current_sandbox_session
        live = sandbox && (sandbox.ready? || sandbox.running?) && sandbox.active?
        return { supported: true, available: false, live: false, refusal: "The project's sandbox is not running", patch_available: false } unless live

        publisher = install.publisher(sandbox)
        refusal = publisher.read_refusal
        credential = refusal ? nil : publisher.credential
        {
          supported: refusal&.code != "unsupported",
          available: refusal.nil? && credential.available?,
          live: true,
          refusal: refusal&.message || credential&.refusal,
          refusal_code: refusal&.code || (credential&.available? == false ? "no_credential" : nil),
          credential: credential&.kind,
          patch_available: refusal.nil?
        }
      end

      # The allowlist as the dialog shows it: paths, and a description of the
      # migration pattern.
      def allowlist_json
        install.allowlist.map do |entry|
          entry.is_a?(Regexp) ? "db/migrate/<timestamp>_<a migration action_agent:install emits>.rb" : entry
        end
      end

      def selection_param
        files = params[:files]
        files = files.map { |file| file.respond_to?(:permit) ? file.permit(:path, :digest).to_h : file } if files.is_a?(Array)
        unless files.is_a?(Array) && files.all? { |file| file.is_a?(Hash) && file["path"].is_a?(String) && file["digest"].is_a?(String) }
          raise DraftPullRequestPublisher::Refused.new("files must be a list of { path, digest } from the preview", code: "nothing_selected")
        end

        files.to_h { |file| [ file["path"], file["digest"] ] }
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
        render json: { error: error.message, code: error.code }, status: status
      end

      def confirmation_required(exception)
        render json: { error: exception.message, code: "confirmation_required", confirmation: exception.message }, status: :conflict
      end

      def boot_refused(exception)
        render json: { error: exception.message, code: "boot_refused" }, status: :unprocessable_entity
      end
    end
  end
end
