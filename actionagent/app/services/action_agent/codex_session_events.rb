# frozen_string_literal: true

module ActionAgent
  # Keep Codex's native JSONL transcript while adapting its terminal event
  # to CodeSession's shared result contract. A process exit alone is never
  # enough to mark a coding session successful.
  class CodexSessionEvents
    def consume(event)
      return unless event.is_a?(Hash)

      case event["type"]
      when "thread.started"
        @thread_id = event["thread_id"]
      when "item.completed"
        item = event["item"]
        @answer = item["text"] if item.is_a?(Hash) && item["type"] == "agent_message"
      when "turn.completed"
        return result(false, @answer, event["usage"])
      when "turn.failed", "error"
        error = event["error"]
        message = error.is_a?(Hash) ? error["message"] : event["message"]
        return result(true, message.presence || "Codex reported a failed turn", {})
      end
      nil
    end

    private

    def result(failed, answer, usage)
      {
        "type" => "result", "subtype" => failed ? "error_during_execution" : "success",
        "is_error" => failed, "result" => answer, "session_id" => @thread_id,
        "usage" => usage.is_a?(Hash) ? usage.slice("input_tokens", "output_tokens") : {}
      }
    end
  end
end
