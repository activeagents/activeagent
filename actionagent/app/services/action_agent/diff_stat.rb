# frozen_string_literal: true

module ActionAgent
  # Counts what a unified diff changes: { files:, additions:, deletions: }.
  # A code session's diff runs from the checkout's base commit, so each turn
  # of a conversation reports everything changed since the checkout, up to
  # and including that turn.
  module DiffStat
    module_function

    # @param diff [String, nil]
    # @return [Hash, nil] nil when there is no diff
    def call(diff)
      return nil if diff.blank?

      files = additions = deletions = 0
      diff.each_line do |line|
        if line.start_with?("diff --git ") then files += 1
        elsif line.start_with?("+++ ", "--- ") then next
        elsif line.start_with?("+") then additions += 1
        elsif line.start_with?("-") then deletions += 1
        end
      end
      { files: files, additions: additions, deletions: deletions }
    end
  end
end
