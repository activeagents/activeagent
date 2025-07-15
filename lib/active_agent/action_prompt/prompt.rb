require_relative "message"

module ActiveAgent
  module ActionPrompt
    class Prompt
      attr_reader :messages
      attr_accessor :actions, :body, :content_type, :context_id, :instructions, :message, :options, :mime_version, :charset, :context, :parts, :params, :action_choice, :agent_class

      def initialize(attributes = {})
        @options = attributes.fetch(:options, {})
        @agent_class = attributes.fetch(:agent_class, ApplicationAgent)
        @actions = attributes.fetch(:actions, [])
        @action_choice = attributes.fetch(:action_choice, "")
        @instructions = load_instructions(attributes.fetch(:instructions, ""))
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
        @messages = Message.from_messages(@messages)
        set_message if attributes[:message].is_a?(String) || @body.is_a?(String) && @message&.content
        set_messages
      end

      def messages=(messages)
        @messages = messages
        set_messages
      end

      # Generate the prompt as a string (for debugging or sending to the provider)
      def to_s
        @message.to_s
      end

      def add_part(message)
        if @content_type == message.content_type && message.content.present?
          @message = message
          set_message
        end

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

      def headers(headers = {})
        @headers.merge!(headers)
      end

      private

      def set_messages
        @messages = [ Message.new(content: @instructions, role: :system) ] + Message.from_messages(@messages) if @instructions.present?
      end

      def set_message
        if @message.is_a? String
          @message = Message.new(content: @message, role: :user)
        elsif @body.is_a?(String) && @message.content.blank?
          @message = Message.new(content: @body, role: :user)
        end

        @messages << @message
      end

      def load_instructions(instructions)
        filename = instructions.to_s
        filename = "instructions" if filename == ""

        file_path = Rails.root.join("app", "views", @agent_class.name.underscore, "#{filename}.text.erb")
        if File.exist?(file_path)
          template = ERB.new(File.read(file_path))
          template.result(binding)
        else
          instructions.to_s
        end
      end
    end
  end
end
