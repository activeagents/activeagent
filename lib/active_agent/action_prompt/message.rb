module ActiveAgent
  module ActionPrompt
    class Message
      VALID_ROLES = %w[system assistant user tool function].freeze

      attr_accessor :action_id, :content, :role, :name, :action_requested, :requested_actions, :content_type, :charset

      def initialize(attributes = {})        
        @action_id = attributes[:action_id]
        @charset = attributes[:charset] || "UTF-8"
        @content = attributes[:content] || ""
        @content_type = attributes[:content_type] || "text/plain"
        @name = attributes[:name]
        @role = attributes[:role] || :user
        @requested_actions = attributes[:requested_actions] || []
        @action_requested = @requested_actions.any?
        validate_role
      end

      def to_h
        hash = {
          role: role, 
          action_id: action_id,
          content: content,
          type: content_type,
          charset: charset
        }
        hash[:name] = name if name
        hash[:action_requested] = requested_actions.any?
        hash[:requested_actions] = requested_actions if requested_actions.any?
        hash
      end

      def embed
        @agent_class.embed(@content)
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
