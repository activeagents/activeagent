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

      attr_accessor :action_id, :action_name, :raw_actions, :generation_id, :content, :raw_content, :role, :action_requested, :requested_actions, :content_type, :charset, :metadata

      def initialize(attributes = {})
        @action_id = attributes[:action_id]
        @action_name = attributes[:action_name]
        @generation_id = attributes[:generation_id]
        @metadata = attributes[:metadata] || {}
        @charset = attributes[:charset] || "UTF-8"
        @raw_content = attributes[:content] || ""
        @content_type = detect_content_type(attributes)
        @content = parse_content(@raw_content, @content_type)
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

      def embed
        @agent_class.embed(@content)
      end

      def inspect
        truncated_content = if @content.is_a?(String) && @content.length > 256
          @content[0, 256] + "..."
        elsif @content.is_a?(Array)
          @content.map do |item|
            if item.is_a?(String) && item.length > 256
              item[0, 256] + "..."
            else
              item
            end
          end
        else
          @content
        end

        "#<#{self.class}:0x#{object_id.to_s(16)}\n" +
        "    @action_id=#{@action_id.inspect},\n" +
        "    @action_name=#{@action_name.inspect},\n" +
        "    @action_requested=#{@action_requested.inspect},\n" +
        "    @charset=#{@charset.inspect},\n" +
        "    @content=#{truncated_content.inspect},\n" +
        "    @role=#{@role.inspect}>"
      end

      private

      def parse_content(content, content_type)
        # Auto-parse JSON content if content_type indicates JSON
        if content_type&.match?(/json/i) && content.is_a?(String) && !content.empty?
          begin
            JSON.parse(content)
          rescue JSON::ParserError
            # If parsing fails, return the raw content
            content
          end
        else
          content
        end
      end

      def detect_content_type(attributes)
        # If content_type is explicitly provided, use it
        return attributes[:content_type] if attributes[:content_type]

        # If content is an array with multipart/mixed content, set appropriate type
        if attributes[:content].is_a?(Array)
          # Check if it contains multimodal content (text, image_url, file, etc.)
          has_multimodal = attributes[:content].any? do |item|
            item.is_a?(Hash) && (item[:type] || item["type"])
          end
          has_multimodal ? "multipart/mixed" : "array"
        else
          "text/plain"
        end
      end

      def validate_role
        unless VALID_ROLES.include?(role.to_s)
          raise ArgumentError, "Invalid role: #{role}. Valid roles are: #{VALID_ROLES.join(", ")}"
        end
      end
    end
  end
end
