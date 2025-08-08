module ActiveAgent
  module Sanitizers
    extend ActiveSupport::Concern

    SECRETS_KEYS = %w[access_token api_key]

    class_methods do
      # @return [Hash] The current sanitizers.
      def sanitizers
        @sanitizers ||= begin
          sanitizers = {}

          config.each do |provider, credentials|
            credentials.slice(*SECRETS_KEYS).compact.each do |name, secret|
              next if secret.blank?

              sanitizers[secret] = "<#{provider.upcase}_#{name.upcase}>"
            end
          end

          sanitizers
        end
      end

      # return [void]
      def sanitizers_reset!
        @sanitizers = nil
      end

      # @return [String] The sanitized string with sensitive data replaced by placeholders.
      def sanitize_credentials(string)
        sanitizers.each do |secret, placeholder|
          string = string.gsub(secret, placeholder)
        end

        string
      end
    end
  end
end
