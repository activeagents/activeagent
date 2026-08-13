# frozen_string_literal: true

module ActionAgent
  # API key generated from Settings -> API Keys. Authenticates requests to
  # the telemetry ingest endpoint as a Bearer token.
  #
  # The token is generated server-side (never accepted from user input) and
  # encrypted at rest with Active Record Encryption, so the host app needs
  # `rails db:encryption:init` before creating keys. Deterministic
  # encryption keeps find_by(token:) lookups working against the ciphertext.
  # Set ActionAgent.encrypt_credentials = false to store tokens
  # in plain text instead; that is a downgrade, not a default.
  class ApiKey < ApplicationRecord
    TOKEN_PREFIX = "aa_"

    include Ownable
    owned_by :account, :user

    encrypts :token, deterministic: true if ActionAgent.encrypt_credentials

    validates :name, presence: true, length: { maximum: 100 }
    validates :token, presence: true, uniqueness: true

    before_validation :generate_token, on: :create

    # Finds the key for a presented bearer token. Returns nil for blank or
    # unknown tokens.
    def self.authenticate(token)
      return nil if token.blank?

      find_by(token: token)
    end

    def touch_last_used!
      # Throttled to avoid a write per ingest request.
      update_column(:last_used_at, Time.current) if last_used_at.nil? || last_used_at < 1.minute.ago
    end

    # Safe to display in the dashboard key list: "aa_3xam…k9Q2"
    def masked_token
      "#{token_prefix}…#{token.last(4)}"
    end

    private

    def generate_token
      return if token.present?

      self.token = "#{TOKEN_PREFIX}#{SecureRandom.base58(32)}"
      self.token_prefix = token.first(TOKEN_PREFIX.length + 4)
    end
  end
end
