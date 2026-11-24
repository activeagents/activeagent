# Builds evaluation scenarios from the conversations people have had with an
# agent: every user message becomes a scenario, keyed by its text so running
# this again adds only what is new.
#
# Where the agent answered a message by calling tools, those tools become the
# scenario's expectation: a later version of the agent that stops reaching for
# them fails the scenario. A message it answered without tools carries no
# expectation, and is left to the judge.
class ConversationScenarios
  def initialize(agent)
    @agent = agent
  end

  # @return [Array<Hash>] scenario attributes for Evaluation#merge_scenarios!
  def call
    turns.uniq { |turn| turn[:prompt].downcase }.map do |turn|
      {
        "key" => "chat-#{Digest::SHA1.hexdigest(turn[:prompt].downcase)[0, 10]}",
        "group" => "From conversations",
        "prompt" => turn[:prompt],
        "expectations" => turn[:tools].any? ? { "tools" => turn[:tools] } : {}
      }
    end
  end

  private

  def turns
    contexts = ActionAgent::AgentContext.where(contextable: @agent).order(:id)
    contexts.flat_map do |context|
      context.messages.chronological.where(role: %w[user tool]).slice_before { |message| message.role == "user" }
        .filter_map do |user, *tool_rows|
          next unless user.role == "user" && user.content.present?

          { prompt: user.content.strip, tools: tool_rows.filter_map(&:tool_name).uniq }
        end
    end
  end
end
