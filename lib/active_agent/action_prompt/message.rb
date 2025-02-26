module ActiveAgent
  module ActionPrompt
    class Message
      VALID_ROLES = %w[system assistant user tool function].freeze

      attr_accessor :content, :role, :name, :action_requested, :requested_actions, :content_type, :charset

      def initialize(attributes = {})
        @requested_actions = attributes[:requested_actions] || []
        @action_requested = @requested_actions.any?  
        @agent_class = attributes[:agent_class]       
        @charset = attributes[:charset] || "UTF-8"
        @content = attributes[:content] || ""
        @content_type = attributes[:content_type] || "text/plain"
        @name = attributes[:name]
        @role = attributes[:role] || :user
        @requested_actions = attributes[:requested_actions] || []
        validate_role
      end

      def to_h
        hash = {
          role: role, 
          content: content,
          content_type: content_type,
          charset: charset
        }
        hash[:name] = name if name
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
