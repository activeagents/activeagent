# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Stores screenshots and DOM snapshots from session recordings.
    #
    # Supports Active Storage for file attachment and provides
    # signed URLs for secure access.
    #
    class RecordingSnapshot < ApplicationRecord
      belongs_to :session_recording, class_name: "ActiveAgent::Dashboard::SessionRecording"
      belongs_to :recording_action, class_name: "ActiveAgent::Dashboard::RecordingAction", optional: true

      has_one_attached :file if defined?(ActiveStorage)

      SNAPSHOT_TYPES = %w[screenshot dom full_page].freeze

      validates :storage_key, presence: true, uniqueness: true
      validates :snapshot_type, presence: true, inclusion: { in: SNAPSHOT_TYPES }

      scope :screenshots, -> { where(snapshot_type: "screenshot") }
      scope :dom_snapshots, -> { where(snapshot_type: "dom") }
      scope :ordered, -> { order(:created_at) }

      # Get a signed URL for the file
      def signed_url(expires_in: 15.minutes)
        return nil unless respond_to?(:file) && file.attached?

        file.url(expires_in: expires_in)
      rescue StandardError
        nil
      end

      # Store file data
      def store!(data, filename: nil, content_type: nil)
        return unless respond_to?(:file)

        content_type ||= infer_content_type
        filename ||= generate_filename

        file.attach(
          io: StringIO.new(data),
          filename: filename,
          content_type: content_type
        )

        update!(file_size_bytes: data.bytesize)
      end

      # For API response
      def as_json_for_api
        {
          id: id,
          storage_key: storage_key,
          snapshot_type: snapshot_type,
          width: width,
          height: height,
          file_size_bytes: file_size_bytes,
          url: signed_url,
          created_at: created_at.iso8601
        }
      end

      private

      def infer_content_type
        case snapshot_type
        when "screenshot", "full_page"
          "image/png"
        when "dom"
          "text/html"
        else
          "application/octet-stream"
        end
      end

      def generate_filename
        ext = snapshot_type == "dom" ? "html" : "png"
        "#{storage_key.tr('/', '_')}.#{ext}"
      end
    end
  end
end
