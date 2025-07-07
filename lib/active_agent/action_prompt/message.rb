module ActiveAgent
  module ActionPrompt
    class Message
      class << self
        def from_messages(messages)
          return messages if messages.empty? || messages.first.is_a?(Message)

          messages.map do |message|
            if message.is_a?(Hash)
              new(message)
            elsif message.is_a?(Message)
              message
            else
              raise ArgumentError, "Messages must be Hash or Message objects"
            end
          end
        end
      end
      VALID_ROLES = %w[system assistant user tool].freeze

      attr_accessor :action_id, :action_name, :raw_actions, :generation_id, :content, :role, :action_requested, :requested_actions, :content_type, :charset

      def initialize(attributes = {})
        @action_id = attributes[:action_id]
        @action_name = attributes[:action_name]
        @generation_id = attributes[:generation_id]
        @charset = attributes[:charset] || "UTF-8"
        @content = attributes[:content] || ""
        @content_type = attributes[:content_type] || "text/plain"
        @role = attributes[:role] || :user
        @raw_actions = attributes[:raw_actions]
        @requested_actions = attributes[:requested_actions] || []
        @action_requested = @requested_actions.any?
        validate_role
      end

      def to_s
        @content.to_s
      end

      def to_h
        hash = {
          role: role,
          action_id: action_id,
          name: action_name,
          generation_id: generation_id,
          content: content,
          type: content_type,
          charset: charset
        }

        hash[:action_requested] = requested_actions.any?
        hash[:requested_actions] = requested_actions if requested_actions.any?
        hash
      end

      private

      def validate_role
        unless VALID_ROLES.include?(role.to_s)
          raise ArgumentError, "Invalid role: #{role}. Valid roles are: #{VALID_ROLES.join(", ")}"
        end
      end
    end
  end
end
