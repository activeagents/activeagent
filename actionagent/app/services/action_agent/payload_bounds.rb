# frozen_string_literal: true

module ActionAgent
  # Used to cap the size of JSON-like data handed to an MCP client, whose
  # context window pays for every character. Each cut leaves a marker saying
  # what was dropped, so a reader never mistakes a truncated value for the
  # whole one.
  module PayloadBounds
    module_function

    # Returns a copy of +value+ with every string cut to +max_string+
    # characters and every array to +max_items+ entries, at any depth. A cut
    # string ends in `…[truncated: N more characters]`; a cut array ends in
    # the string `[truncated: N more items]`. Other values come back as they
    # are.
    #
    #   bound({ "output" => "x" * 5 }, max_string: 3)
    #   # => { "output" => "xxx…[truncated: 2 more characters]" }
    def bound(value, max_string: 2_000, max_items: 50)
      case value
      when String then truncate_string(value, max_string)
      when Hash then value.to_h { |key, item| [ key, bound(item, max_string: max_string, max_items: max_items) ] }
      when Array
        kept = value.first(max_items).map { |item| bound(item, max_string: max_string, max_items: max_items) }
        value.size > max_items ? kept << "[truncated: #{value.size - max_items} more items]" : kept
      else value
      end
    end

    def truncate_string(value, max)
      return value if value.length <= max

      "#{value[0, max]}…[truncated: #{value.length - max} more characters]"
    end
  end
end
