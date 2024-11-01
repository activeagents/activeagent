module ActiveAgent
  module ActionPrompt
    class Message
      VALID_ROLES = %w[system assistant user].freeze

      attr_accessor :content, :requested_actions, :params, :role

      def initialize(attributes = {})
        @content = attributes[:content] || ""
        @requested_actions = attributes[:requested_actions] || []
        @params = attributes[:params] || {}
        @role = attributes[:role] || "system"
        validate_role
      end

      def actions_requested?
        requested_actions.any?
      end

      def call_actions
        requested_actions.each do |action|
          action.call(self) if action.respond_to?(:call)
        end
      end

      def to_s
        content.to_s
      end

      def to_h
        {content: content, role: role}
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
