# frozen_string_literal: true

module ActionAgent
  # Masks what a browser tool call typed: the `text` of `browser_type`, the
  # `promptText` of `browser_handle_dialog` and each field `value` of
  # `browser_fill_form`. MCPRecordingMiddleware applies it before an agent's
  # browser action is stored, and SessionTimeline before a tool call is
  # shown.
  #
  # Masking is per call. A value one call typed is masked in that call's
  # arguments and result, but not in another call's result that shows it,
  # such as a later snapshot of the filled field.
  module BrowserToolRedaction
    MASK = "[REDACTED]"
    # The argument that holds what each single-value typing tool typed.
    TYPED_ARGUMENTS = { "browser_type" => "text", "browser_handle_dialog" => "promptText" }.freeze
    TYPING_TOOLS = [ *TYPED_ARGUMENTS.keys, "browser_fill_form" ].freeze
    # Shorter typed values are masked in the arguments but not searched for
    # in other text, where they would mask unrelated characters.
    MIN_SEARCHED_LENGTH = 3

    module_function

    def typing_tool?(tool_name)
      TYPING_TOOLS.include?(tool_name.to_s)
    end

    # Returns +arguments+ with the typed values masked, in the form given: a
    # Hash, or JSON text. Arguments of a typing tool that cannot be read as a
    # Hash, such as JSON cut off mid-string, are masked whole. Other tools'
    # arguments are returned unchanged.
    def redact_arguments(tool_name, arguments)
      return arguments unless typing_tool?(tool_name)

      parsed = parse(arguments)
      return MASK unless parsed.is_a?(Hash)

      typed = TYPED_ARGUMENTS[tool_name.to_s]
      masked =
        if typed
          parsed.key?(typed) ? parsed.merge(typed => MASK) : parsed
        else
          parsed.merge("fields" => Array(parsed["fields"]).map { |field| mask_field(field) })
        end
      arguments.is_a?(String) ? masked.to_json : masked
    end

    # Returns +text+, such as a tool result, with the values the call typed
    # masked. A typing tool's text is masked whole when its +arguments+
    # cannot be read. Other tools' text is returned unchanged.
    def redact_text(tool_name, text, arguments)
      return text unless typing_tool?(tool_name) && text.is_a?(String)

      parsed = parse(arguments)
      return MASK unless parsed.is_a?(Hash)

      typed_values(tool_name, parsed)
        .select { |value| value.length >= MIN_SEARCHED_LENGTH }
        .sort_by { |value| -value.length }
        .reduce(text) { |masked, value| masked.gsub(value, MASK) }
    end

    # The values a typing tool call typed, from its parsed arguments.
    def typed_values(tool_name, parsed)
      typed = TYPED_ARGUMENTS[tool_name.to_s]
      values = typed ? [ parsed[typed] ] : Array(parsed["fields"]).map { |field| field["value"] if field.is_a?(Hash) }
      values.compact.map(&:to_s).reject(&:empty?)
    end

    def mask_field(field)
      return field unless field.is_a?(Hash)

      field = field.deep_stringify_keys
      field.key?("value") ? field.merge("value" => MASK) : field
    end

    # +arguments+ as a string-keyed Hash: a Hash as given, JSON text parsed.
    # Anything else, or JSON that does not parse, is returned as nil.
    def parse(arguments)
      case arguments
      when Hash then arguments.deep_stringify_keys
      when String
        parsed = JSON.parse(arguments)
        parsed.is_a?(Hash) ? parsed : nil
      end
    rescue JSON::ParserError
      nil
    end
  end
end
