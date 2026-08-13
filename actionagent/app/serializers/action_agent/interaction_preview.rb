# frozen_string_literal: true

module ActionAgent
  # The two lines a collapsed interaction row shows — what the stream was
  # asked, and what it finally answered. Both sources of an interaction produce
  # them: solid_agent contexts (Api::InteractionsController) and reported
  # traces (TraceInteractionSerializer), so a list mixing the two reads the
  # same way either side of the row came from.
  module InteractionPreview
    # One line each. The list is fifty streams deep, and the row clips to a
    # single line anyway — sending the whole conversation to be truncated in
    # the browser would pay for text nobody reads.
    LIMIT = 300

    def self.line(value)
      text = value.to_s.squish
      return nil if text.blank?

      text.truncate(LIMIT)
    end
  end
end
