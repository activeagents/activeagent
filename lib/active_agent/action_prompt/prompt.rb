require_relative "message"

module ActiveAgent
  module ActionPrompt
    class Prompt
      attr_reader :messages, :instructions
      attr_accessor :actions, :body, :content_type, :context_id, :message, :options, :mime_version, :charset, :context, :parts, :params, :action_choice, :agent_class, :output_schema, :action_name, :agent_instance, :mcp_servers

      def initialize(attributes = {})
        @options = attributes.fetch(:options, {})
        @multimodal = attributes.fetch(:multimodal, false)
        @agent_class = attributes.fetch(:agent_class, ApplicationAgent)
        @agent_instance = attributes.fetch(:agent_instance, nil)
        @actions = attributes.fetch(:actions, [])
        @action_choice = attributes.fetch(:action_choice, "")
        @instructions = attributes.fetch(:instructions, "")
        @body = attributes.fetch(:body, "")
        @content_type = attributes.fetch(:content_type, "text/plain")
        @message = attributes.fetch(:message, nil)
        @messages = attributes.fetch(:messages, [])
        @params = attributes.fetch(:params, {})
        @mime_version = attributes.fetch(:mime_version, "1.0")
        @charset = attributes.fetch(:charset, "UTF-8")
        @context = attributes.fetch(:context, [])
        @context_id = attributes.fetch(:context_id, nil)
        @headers = attributes.fetch(:headers, {})
        @parts = attributes.fetch(:parts, [])
        @output_schema = attributes.fetch(:output_schema, nil)
        @messages = Message.from_messages(@messages)
        @action_name = attributes.fetch(:action_name, nil)
        @mcp_servers = attributes.fetch(:mcp_servers, [])
        set_message if attributes[:message].is_a?(String) || @body.is_a?(String) && @message&.content
        # Ensure we have a system message with instructions at the start
        if @messages.empty? || @messages[0].role != :system
          @messages.unshift(instructions_message)
        elsif @instructions.present?
          @messages[0] = instructions_message
        end
      end

      def multimodal?
        @multimodal ||= @message&.content.is_a?(Array) || @messages.any? { |m| m&.content.is_a?(Array) }
      end

      def messages=(messages)
        @messages = messages
        # Only add system message if we have instructions and don't already have a system message
        if @instructions.present? && (@messages.empty? || @messages.first&.role != :system)
          set_messages
        end
      end

      def instructions=(instructions)
        # Store the instructions even if blank (will use empty string)
        @instructions = instructions || ""

        # Update or add the system message
        if @messages[0].present? && @messages[0].role == :system
          @messages[0] = instructions_message
        elsif @messages.empty? || @messages[0].role != :system
          # Only add system message if we don't have one at the start
          @messages.unshift(instructions_message)
        end
      end

      # Generate the prompt as a string (for debugging or sending to the provider)
      def to_s
        @message.to_s
      end

      def add_part(message)
        @message = message
        set_message

        @parts << message
      end

      def multipart?
        @parts.any?
      end

      def to_h
        {
          actions: @actions,
          action: @action_choice,
          instructions: @instructions,
          message: @message.to_h,
          messages: @messages.map(&:to_h),
          headers: @headers,
          context: @context
        }
      end

      def inspect
        "#<#{self.class}:0x#{object_id.to_s(16)}\n" +
          "  @options=#{ActiveAgent.sanitize_credentials(@options.inspect)}\n" +
          "  @actions=#{@actions.inspect}\n" +
          "  @action_choice=#{@action_choice.inspect}\n" +
          "  @instructions=#{@instructions.inspect}\n" +
          "  @message=#{@message.inspect}\n" +
          "  @output_schema=#{@output_schema}\n" +
          "  @headers=#{@headers.inspect}\n" +
          "  @context=#{@context.inspect}\n" +
          "  @messages=#{@messages.inspect}\n" +
          ">"
      end

      def headers(headers = {})
        @headers.merge!(headers)
      end

      private

      def instructions_message
        Message.new(content: @instructions, role: :system)
      end

      def set_messages
        @messages = [ instructions_message ] + @messages
        # if @message.nil? || @message.content.blank?
        #   @message = @messages.last
        # end
      end

      def set_message
        if @message.is_a? String
          @message = Message.new(content: @message, role: :user)
        elsif @body.is_a?(String) && @message.content.blank?
          @message = Message.new(content: @body, role: :user)
        end

        @messages = @messages + [ @message ]
      end
    end
  end
end
