module ActiveAgent
  module ActionPrompt
    class Message
      VALID_ROLES = %w[system assistant user tool function].freeze

      attr_accessor :content, :role, :name, :action_requested, :requested_actions

      def initialize(attributes = {})
        @content = attributes[:content] || ""
        @role = attributes[:role] || "user"
        @name = attributes[:name]
        @action_requested = attributes[:function_call]
        @requested_actions = attributes[:tool_calls] || []
        validate_role
      end

      def to_h
        hash = {role: role, content: content}
        hash[:name] = name if name
        hash[:action_requested] = action_requested if action_requested
        hash[:requested_actions] = requested_actions if requested_actions.any?
        hash
      end

      def perform_actions
        requested_actions.each do |action|
          action.call(self) if action.respond_to?(:call)
        end
      end

      def action_requested?
        action_requested.present? || requested_actions.any?
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
