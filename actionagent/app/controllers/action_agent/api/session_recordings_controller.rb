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

      before_action :set_recording, only: [ :show, :actions, :snapshot, :export, :handoff ]

      # GET /api/session_recordings
      # List recordings with optional filters
      def index
        # Recordings the caller owns, plus the shared demo. Ownership is a
        # real column rather than a JSON metadata key, so this works on
        # every adapter.
        recordings = owned(SessionRecording).or(SessionRecording.where(name: "lander_demo")).recent

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
        page = (params[:page] || 1).to_i
        per_page = [ (params[:per_page] || 20).to_i, 100 ].min
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
        recordings = owned(SessionRecording).recent.limit(10)

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
          actions = actions.where("sequence > ?", params[:after_sequence].to_i)
        end

        limit = [ params[:limit]&.to_i || 100, 500 ].min
        actions = actions.limit(limit)

        render json: {
          actions: actions.map(&:as_json_for_api),
          has_more: actions.count == limit,
          total_actions: @recording.action_count
        }
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
          page_url: params[:page_url]
        )

        # Set user agent from request
        recording.update!(
          metadata: recording.metadata.merge(
            user_agent: request.user_agent,
            ip_hash: Digest::SHA256.hexdigest(request.remote_ip.to_s)[0..16]
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

        # Create a new recording for the user's continuation
        continuation = SessionRecording.create!(
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

      def can_manage_recording?(recording)
        # An install with no owner model owns everything it can see.
        return true if SessionRecording.owner_association.nil?
        return true if owned(SessionRecording).exists?(id: recording.id)

        # Recordings made inside a sandbox belong to whoever opened it.
        session = recording.sandbox_session
        return true if session && session.owner.present? && session.owner == current_owner

        false
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
          handoff_state: recording.metadata["handoff_state"],
          agent: recording.agent_run&.agent&.slice(:id, :name),
          sandbox_session: recording.sandbox_session&.summary
        }
      end

      def first_screenshot_url(recording)
        action = recording.recording_actions.with_screenshots.first
        action&.screenshot_url(expires_in: 1.hour)
      end

      def safe_metadata(metadata)
        # Remove sensitive data from metadata
        metadata.except("cookies", "session_storage", "local_storage")
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
              value: action.value,
              metadata: action.metadata
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
