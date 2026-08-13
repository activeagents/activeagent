# frozen_string_literal: true

module ActionAgent
  class RecordingSnapshot < ApplicationRecord
    belongs_to :session_recording
    belongs_to :recording_action, optional: true

    # Guarded: a host app created with --skip-active-storage (or --minimal)
    # has no has_one_attached, and the gem depends on railties rather than
    # rails, so it may not even have the gem to require. Without this the
    # engine dies during eager load at boot.
    has_one_attached :file if defined?(ActiveStorage)

    # Whether file attachment is available in this host app.
    def self.attachments_available?
      defined?(ActiveStorage) && method_defined?(:file)
    end

    SNAPSHOT_TYPES = %w[screenshot dom full_page].freeze

    validates :storage_key, presence: true, uniqueness: true
    validates :snapshot_type, presence: true, inclusion: { in: SNAPSHOT_TYPES }

    scope :screenshots, -> { where(snapshot_type: "screenshot") }
    scope :dom_snapshots, -> { where(snapshot_type: "dom") }
    scope :ordered, -> { order(:created_at) }

    # Get a signed URL for the file
    def signed_url(expires_in: 15.minutes)
      return nil unless self.class.attachments_available?
      return nil unless file.attached?

      file.url(expires_in: expires_in)
    rescue StandardError
      # Fallback if storage not configured
      nil
    end

    # Store file data. Without Active Storage the row still records the
    # snapshot's metadata; only the blob is skipped.
    def store!(data, filename: nil, content_type: nil)
      content_type ||= infer_content_type
      filename ||= generate_filename

      if self.class.attachments_available?
        file.attach(
          io: StringIO.new(data),
          filename: filename,
          content_type: content_type
        )
      end

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
