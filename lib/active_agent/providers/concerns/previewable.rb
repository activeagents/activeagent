# frozen_string_literal: true

module ActiveAgent
  module Providers
    # Generates markdown previews of prompts for debugging and inspection.
    #
    # Renders request parameters, instructions, messages, and tools in a
    # human-readable format without executing the actual API call.
    module Previewable
      extend ActiveSupport::Concern

      # Generates a markdown preview of the prompt request.
      #
      # @return [String] markdown-formatted preview
      def preview_prompt
        request = prepare_prompt_request

        # @todo Validate Request
        api_parameters = api_request_build(request, prompt_request_type)

        render_markdown_preview(api_parameters)
      end

      private

      # Renders markdown preview with YAML metadata, instructions, messages, and tools.
      #
      # Sections are separated by `---` dividers for readability.
      #
      # @param parameters [Hash]
      # @return [String]
      def render_markdown_preview(parameters)
        sections = []

        # Instructions section
        if (instructions = parameters.delete(:instructions)).present?
          sections << render_instructions_section(instructions)
        end

        # Messages section
        if (messages = parameters.delete(:messages) || parameters.delete(:input)).present?
          sections << render_messages_section(messages)
        end

        # Tools section
        if (tools = parameters.delete(:tools)).present?
          sections << render_tools_section(tools)
        end

        # Prepend YAML section with request details
        sections = [ render_yaml_section(parameters) ] + sections

        sections.compact.join("\n---\n")
      end

      # @param instructions [String]
      # @return [String]
      def render_instructions_section(instructions)
        "## Instructions\n#{instructions}"
      end

      # Renders conversation messages with role labels.
      #
      # @param messages [Array<Hash>]
      # @return [String]
      def render_messages_section(messages)
        return "" if messages.nil? || messages.empty?

        content = +"## Messages\n\n"

        Array(messages).each_with_index do |message, index|
          content << render_single_message(message, index + 1)
          content << "\n\n" unless index == messages.size - 1
        end

        content
      end

      # @param message [Hash]
      # @param index [Integer] 1-based message number
      # @return [String]
      def render_single_message(message, index)
        role    = (message.is_a?(Hash) && message[:role]) || "user"
        content = extract_message_content(message)

        "### Message #{index} (#{role.capitalize})\n#{content}"
      end

      # Renders available tools with descriptions and parameter schemas.
      #
      # @param tools [Array<Hash>]
      # @return [String]
      def render_tools_section(tools)
        return "" if tools.nil? || tools.empty?

        content = +"## Tools\n\n"

        tools.each_with_index do |tool, index|
          content << "### #{tool[:name] || "Tool #{index + 1}"}\n"
          content << "**Description:** #{tool[:description] || 'No description'}\n\n"

          if tool[:parameters]
            content << "**Parameters:**\n```json\n#{JSON.pretty_generate(tool[:parameters])}\n```\n\n"
          end
        end

        content.chomp
      end

      # Extracts text content from various message formats.
      #
      # Handles string messages, hash messages with :content key, and
      # array content blocks (extracting only text-type blocks).
      #
      # @param message [Hash, String, nil]
      # @return [String]
      def extract_message_content(message)
        return "" if message.nil?

        case message
        when String
          message
        when Hash
          content = message[:content]
          case content
          when String
            content
          when Array
            content
              .select { |block| block.is_a?(Hash) && block[:type] == "text" }
              .map { |block| block[:text] }
              .join(" ")
          else
            content.to_s
          end
        else
          message.to_s
        end
      end

      # Renders request metadata as YAML.
      #
      # @param parameters [Hash]
      # @return [String]
      def render_yaml_section(parameters)
        parameters.to_yaml.chomp
      end
    end
  end
end
