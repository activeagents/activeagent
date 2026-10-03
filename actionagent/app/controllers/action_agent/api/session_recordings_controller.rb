# frozen_string_literal: true

module ActionAgent
  module Api
    class SessionRecordingsController < BaseController
      # Every action authenticates. Recordings carry a replayable timeline of
      # a real browser session — including values typed into forms — so the
      # lander-analytics exemption that used to cover start_user_session,
      # record_action, complete_session and demo published exactly the data
      # that most needs a login. A marketing site that wants to record its
      # own visitors should do so against its own endpoint, not one the
      # engine exposes on every host that mounts it.

      before_action :require_dashboard_capture!, only: [ :create, :create_events ]
      before_action :require_owner!, only: :create
      before_action :set_recording, only: [ :show, :actions, :snapshot, :export, :handoff, :timeline, :events, :create_events ]

      SENSITIVE_STATE_KEYS = SessionRecording::SENSITIVE_STATE_KEYS

      # Recording event rows one page of #events returns at most, and the
      # event bytes after which a page ends early.
      EVENTS_PAGE_LIMIT = 100
      EVENTS_PAGE_BYTES = 4.megabytes

      # GET /api/session_recordings
      # List recordings with optional filters
      def index
        # Recordings the caller can reach, plus the shared demo. Ownership is
        # a real column rather than a JSON metadata key, so this works on
        # every adapter.
        recordings = reachable_recordings.or(SessionRecording.where(name: "lander_demo")).recent

        # Filter by status
        recordings = recordings.where(status: params[:status]) if params[:status].present?

        # Filter by agent
        if params[:agent_id].present?
          recordings = recordings.joins(:agent_run)
                                 .where(agent_runs: { agent_id: params[:agent_id] })
        end

        # Filter by sandbox session
        if params[:sandbox_session_id].present?
          recordings = recordings.where(sandbox_session_id: params[:sandbox_session_id])
        end

        # Pagination
        page = integer_param(:page, default: 1)
        per_page = [ integer_param(:per_page, default: 20), 100 ].min
        offset = (page - 1) * per_page

        total = recordings.count
        recordings = recordings.offset(offset).limit(per_page)

        render json: {
          recordings: recordings.map { |r| recording_summary(r) },
          pagination: {
            page: page,
            per_page: per_page,
            total: total,
            total_pages: (total.to_f / per_page).ceil
          }
        }
      end

      # GET /api/session_recordings/recent
      # Get recent recordings for the current user
      def recent
        recordings = reachable_recordings.recent.limit(10)

        render json: {
          recordings: recordings.map { |r| recording_summary(r) }
        }
      end

      # GET /api/session_recordings/:id
      # Get full recording details for playback
      def show
        render json: {
          recording: recording_detail(@recording)
        }
      end

      # GET /api/session_recordings/:id/actions
      # Get the action timeline for playback
      def actions
        actions = @recording.recording_actions.ordered

        # Support pagination for large recordings
        if params[:after_sequence].present?
          actions = actions.where("sequence > ?", integer_param(:after_sequence, default: 0))
        end

        limit = [ integer_param(:limit, default: 100), 500 ].min
        actions = actions.limit(limit)

        render json: {
          actions: actions.map(&:as_json_for_api),
          has_more: actions.count == limit,
          total_actions: @recording.action_count
        }
      end

      # GET /api/session_recordings/:id/timeline
      # The recording's browser lane with the message, llm and tool lanes of
      # its conversation or run (SessionTimeline).
      def timeline
        render json: RecordingEvent.generate_json(timeline: SessionTimeline.for_recording(@recording, timeline_scope).as_json)
      end

      # GET /api/session_recordings/:id/events
      # The recording's events in time order, a page of rows at a time, with
      # their payloads. rrweb only unless +kind+ names others (comma
      # separated). +after+ is the id of the last row already read.
      def events
        kinds = params[:kind].to_s.split(",").map(&:strip) & RecordingEvent::KINDS
        rows = @recording.recording_events.where(kind: kinds.presence || "rrweb").chronological
        if params[:after].present?
          cursor = @recording.recording_events.find_by(id: integer_param(:after))
          return render(json: { error: "Unknown cursor" }, status: :unprocessable_entity) unless cursor

          rows = rows.where(after_row(cursor))
        end
        limit = clamped_param(:limit, default: 20, min: 1, max: EVENTS_PAGE_LIMIT)
        fetched = rows.limit(limit + 1).to_a
        page = page_of_rows(fetched, limit)

        render json: RecordingEvent.generate_json(
          events: page.map { |row| event_row_json(row) },
          has_more: fetched.size > page.size,
          next_after: page.last&.id
        )
      end

      # POST /api/session_recordings
      # Starts the caller's recording of one visit to conversation
      # +agent_context_id+ in the Run Agent workbench (`source: "dashboard"`),
      # which the dashboard posts its rrweb batches to (201).
      #
      # Each visit gets a recording of its own. An rrweb stream replays only
      # against the full snapshot it began with, so two tabs on one
      # conversation need two recordings. The recording caps
      # (ActionAgent.recording_limits) then bound one visit.
      #
      # 400 without a conversation id, 404 for a conversation of an agent the
      # caller cannot reach. 401 when recordings have owners and the caller
      # resolves to none, since the caller could not reach the recording
      # afterwards.
      def create
        context_id = integer_param(:agent_context_id)
        return render(json: { error: "agent_context_id is required" }, status: :bad_request) if context_id.nil?

        context = AgentContext.for_agents(owner_agents).find(context_id)
        owner = recording_owner
        if owner.nil? && SessionRecording.owner_association
          return render(json: { error: "Sign in to record this conversation" }, status: :unauthorized)
        end

        recording = SessionRecording.start!(agent_context: context, source: "dashboard", owner: owner)
        render json: { recording: dashboard_recording_json(recording) }, status: :created
      end

      # POST /api/session_recordings/:id/events
      # A batch of browser events (RecordingEventIngest) from a dashboard
      # session, with the owner's credentials masked in it. A recorder holding
      # the recording's ingest token posts to the same path, and is answered
      # by RecordingEventIngestController.
      #
      # 503 when the credentials cannot be read: the batch is not stored
      # without them masked.
      def create_events
        secrets =
          begin
            owner_credentials
          rescue StandardError => e
            Rails.logger.warn("[ActionAgent] credential lookup for a recording batch failed: #{e.class}: #{e.message}")
            return render(json: { error: "The batch could not be checked for credentials", code: "credential_check_failed" },
              status: :service_unavailable)
          end

        result = RecordingEventIngest.call(@recording, request.raw_post, secrets: secrets)
        render json: result.body, status: result.status
      end

      # GET /api/session_recordings/:id/snapshot/:action_id
      # Get a specific snapshot (screenshot or DOM)
      def snapshot
        action = @recording.recording_actions.find(params[:action_id])

        snapshot_type = params[:type] || "screenshot"

        case snapshot_type
        when "screenshot"
          url = action.screenshot_url
          render json: { url: url, type: "screenshot" }
        when "dom"
          content = action.dom_snapshot_content
          render json: { content: content, type: "dom" }
        else
          render json: { error: "Unknown snapshot type" }, status: :bad_request
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Action not found" }, status: :not_found
      end

      # POST /api/session_recordings/:id/export
      # Export recording as VCR cassette
      def export
        format = params[:format] || "json"

        cassette = build_cassette(@recording, format)

        render json: {
          cassette: cassette,
          filename: "#{@recording.name}_recording.#{format}"
        }
      end

      # POST /api/session_recordings/start_user_session
      # Start a new user takeover session for analytics
      def start_user_session
        recording = SessionRecording.start_user_session!(
          visitor_id: params[:visitor_id] || generate_visitor_id,
          parent_demo_id: params[:parent_demo_id],
          page_url: params[:page_url],
          owner: current_owner
        )

        # Set user agent from request. String keys: the stored metadata is
        # string-keyed, and merging symbols wrote a second "user_agent" that
        # json 3.0 refuses to encode.
        recording.update!(
          metadata: recording.metadata.merge(
            "user_agent" => request.user_agent,
            "ip_hash" => Digest::SHA256.hexdigest(request.remote_ip.to_s)[0..16]
          )
        )

        # Record the handoff action
        recording.record_action!(
          action_type: "handoff",
          value: "User took over from agent demo",
          metadata: {
            source: "lander_demo",
            step: params[:step] || 4
          }
        )

        render json: {
          recording_id: recording.id,
          visitor_id: recording.metadata["visitor_id"],
          message: "User session started"
        }, status: :created
      end

      # POST /api/session_recordings/:id/record_action
      # Record a user action in an active session
      def record_action
        recording = SessionRecording.find(params[:id])
        return not_found unless can_manage_recording?(recording)

        unless recording.recording?
          render json: { error: "Recording already completed" }, status: :unprocessable_entity
          return
        end

        action = recording.record_action!(
          action_type: params[:action_type],
          selector: params[:selector],
          value: params[:value],
          metadata: params[:metadata]&.to_unsafe_h || {}
        )

        render json: {
          action_id: action.id,
          sequence: action.sequence,
          timestamp_ms: action.timestamp_ms
        }
      end

      # POST /api/session_recordings/:id/complete
      # Complete a user session recording
      def complete_session
        recording = SessionRecording.find(params[:id])
        return not_found unless can_manage_recording?(recording)

        unless recording.recording?
          render json: { error: "Recording already completed" }, status: :unprocessable_entity
          return
        end

        # Record the completion action
        recording.record_action!(
          action_type: "completion",
          value: params[:completion_type] || "session_end",
          metadata: {
            email_submitted: params[:email_submitted],
            success: params[:success]
          }
        )

        recording.complete!

        render json: {
          recording_id: recording.id,
          status: recording.status,
          action_count: recording.action_count,
          duration_ms: recording.duration_ms
        }
      end

      # POST /api/session_recordings/:id/handoff
      # Get handoff state to continue where agent left off
      def handoff
        handoff_state = @recording.metadata["handoff_state"]

        unless handoff_state
          render json: { error: "No handoff state available" }, status: :unprocessable_entity
          return
        end

        # Create a new recording for the user's continuation. It records the
        # caller's own session, so it is owned by the caller — through the
        # owner column the list reads, not a metadata key it never consults.
        continuation = SessionRecording.new(
          sandbox_session: @recording.sandbox_session,
          agent_run: @recording.agent_run,
          name: "#{@recording.name}_continuation",
          status: :recording,
          metadata: {
            parent_recording_id: @recording.id,
            handoff_from: @recording.action_count,
            started_at: Time.current.iso8601,
            user_id: current_user&.id
          }
        )
        continuation.owner = current_owner || @recording.owner
        continuation.save!

        render json: {
          handoff_state: handoff_state,
          continuation_recording_id: continuation.id,
          parent_recording: recording_summary(@recording),
          message: "Ready to continue from action #{@recording.action_count}"
        }
      end

      # DELETE /api/session_recordings/:id
      def destroy
        @recording = SessionRecording.find(params[:id])

        # Only allow deletion of own recordings (or any if admin)
        unless can_manage_recording?(@recording)
          render json: { error: "Not authorized" }, status: :forbidden
          return
        end
        return unless authorize_action!(:manage_recordings, @recording)

        @recording.destroy!
        render json: { message: "Recording deleted" }
      end

      private

      # Scoped through can_manage_recording? rather than owned(): nothing in
      # the engine writes user_id/account_id onto a recording, so an
      # ownership scope would hide it from the person who made it. 404 rather
      # than 403 so ids stay unenumerable.
      def set_recording
        @recording = SessionRecording.find(params[:id])
        return if can_manage_recording?(@recording)

        not_found
      end

      # Refuses the workbench's recordings and every batch a dashboard session
      # posts when the host turned capture off.
      def require_dashboard_capture!
        return if ActionAgent.capture_dashboard_sessions?

        render json: { error: "Session capture is turned off on this dashboard", code: "capture_disabled" }, status: :forbidden
      end

      # Whom a recording the caller starts belongs to: the record #owned
      # scopes SessionRecording by, so the caller finds it again.
      def recording_owner
        case SessionRecording.owner_association
        when :user then current_user
        when :account then current_account
        end
      end

      def dashboard_recording_json(recording)
        {
          id: recording.id,
          agent_context_id: recording.agent_context_id,
          source: recording.source,
          status: recording.status
        }
      end

      def can_manage_recording?(recording)
        # An install with no owner model owns everything it can see.
        return true if SessionRecording.owner_association.nil?
        return true if owned(SessionRecording).exists?(id: recording.id)

        # Recordings made inside a sandbox belong to whoever opened it.
        session = recording.sandbox_session
        return true if session && session.owner.present? && session.owner == current_owner

        false
      end

      # The rows that sort after +row+ in RecordingEvent.chronological order.
      def after_row(row)
        table = RecordingEvent.arel_table
        later_in_batch = table[:batch_index].gt(row.batch_index)
          .or(table[:batch_index].eq(row.batch_index).and(table[:id].gt(row.id)))
        table[:occurred_from].gt(row.occurred_from)
          .or(table[:occurred_from].eq(row.occurred_from).and(later_in_batch))
      end

      # The first +limit+ of +rows+, ending early once EVENTS_PAGE_BYTES of
      # events are in the page. Always at least one row.
      def page_of_rows(rows, limit)
        bytes = 0
        rows.first(limit).take_while do |row|
          fits = bytes.zero? || bytes + row.byte_size <= EVENTS_PAGE_BYTES
          bytes += row.byte_size
          fits
        end
      end

      # rrweb events are returned as recorded, since a DOM attribute may carry
      # any name and a stripped snapshot would not replay. Other kinds lose
      # SessionRecording::SENSITIVE_STATE_KEYS, as they do in a timeline.
      def event_row_json(row)
        {
          id: row.id,
          kind: row.kind,
          occurred_from: row.occurred_from.utc.iso8601(3),
          occurred_to: row.occurred_to.utc.iso8601(3),
          clock_offset_ms: row.clock_offset_ms,
          event_count: row.event_count,
          events: row.kind == "rrweb" ? row.events : SessionRecording.without_sensitive_state(row.events)
        }
      end

      def recording_summary(recording)
        {
          id: recording.id,
          name: recording.name,
          status: recording.status,
          action_count: recording.action_count,
          duration_ms: recording.duration_ms,
          created_at: recording.created_at.iso8601,
          thumbnail_url: first_screenshot_url(recording),
          agent_name: recording.agent_run&.agent&.name,
          sandbox_type: recording.sandbox_session&.sandbox_type
        }
      end

      def recording_detail(recording)
        {
          id: recording.id,
          name: recording.name,
          status: recording.status,
          action_count: recording.action_count,
          duration_ms: recording.duration_ms,
          metadata: safe_metadata(recording.metadata),
          created_at: recording.created_at.iso8601,
          updated_at: recording.updated_at.iso8601,
          timeline: recording.timeline,
          handoff_state: safe_handoff_state(recording.metadata["handoff_state"]),
          agent: recording.agent_run&.agent&.slice(:id, :name),
          sandbox_session: recording.sandbox_session&.summary
        }
      end

      def first_screenshot_url(recording)
        action = recording.recording_actions.with_screenshots.first
        action&.screenshot_url(expires_in: 1.hour)
      end

      # Strips the browser state at the top level and inside handoff_state,
      # which the model stores nested (a recording's metadata carries the
      # handoff as one key), so a show response never ships a session cookie.
      def safe_metadata(metadata)
        safe = (metadata || {}).except(*SENSITIVE_STATE_KEYS)
        return safe unless safe["handoff_state"].is_a?(Hash)

        safe.merge("handoff_state" => safe_handoff_state(safe["handoff_state"]))
      end

      def safe_handoff_state(handoff_state)
        return handoff_state unless handoff_state.is_a?(Hash)

        handoff_state.except(*SENSITIVE_STATE_KEYS)
      end

      def generate_visitor_id
        # Generate a stable visitor ID based on IP and user agent
        fingerprint = "#{request.remote_ip}:#{request.user_agent}"
        "v_#{Digest::SHA256.hexdigest(fingerprint)[0..16]}"
      end

      def build_cassette(recording, format)
        cassette = {
          name: recording.name,
          recorded_at: recording.created_at.iso8601,
          duration_ms: recording.duration_ms,
          action_count: recording.action_count,
          actions: recording.recording_actions.ordered.map do |action|
            {
              type: action.action_type,
              sequence: action.sequence,
              timestamp_ms: action.timestamp_ms,
              selector: action.selector,
              # Redacted like /actions: the export used to ship the cleartext
              # the action list had masked.
              value: action.redacted_value,
              metadata: action.safe_metadata
            }
          end
        }

        # Include screenshots as base64 if requested
        if params[:include_screenshots] == "true"
          cassette[:actions].each_with_index do |action_data, i|
            action = recording.recording_actions.find_by(sequence: action_data[:sequence])
            if action&.screenshot_key
              snapshot = RecordingSnapshot.find_by(storage_key: action.screenshot_key)
              if snapshot&.file&.attached?
                action_data[:screenshot_base64] = Base64.encode64(snapshot.file.download)
              end
            end
          end
        end

        cassette
      end
    end
  end
end
