# frozen_string_literal: true

require_relative "integration_case"

# The combination a user installs: activeagent generating, solid_agent
# persisting, into the models `rails generate solid_agent:install` writes.
class SolidAgentContextPersistenceTest < SolidAgentIntegrationTest
  # Persistence::SupportAgent declares `contextual:`, which solid_agent
  # renamed from `contextable:` after 0.1 — referencing the class at all
  # raises on an older gem, so the check has to come before that.
  requires_solid_agent_capability("has_context(contextual:)") do
    SolidAgent::HasContext::ClassMethods.instance_method(:has_context)
      .parameters.any? { |_, name| name == :contextual }
  end

  test "a generation writes the context, both turns and the generation record" do
    response = Persistence::SupportAgent.with(
      user: subject_record, message: "My invoice is wrong"
    ).answer.generate_now

    context = AgentContext.for_agent("Persistence::SupportAgent").sole

    assert_equal "answer", context.action_name
    assert_equal subject_record, context.contextable

    assert_equal [ "user", "assistant" ], context.messages.chronological.map(&:role)
    assert_equal "My invoice is wrong", context.messages.user_messages.sole.content
    assert_equal response.message.content, context.messages.assistant_messages.sole.content

    generation = context.generations.sole
    assert_equal response.message.content, generation.content
    assert generation.model.present?, "expected the generation to record the model"
  end

  test "a second turn replays the first out of the database" do
    message_counts = []

    ActiveSupport::Notifications.subscribed(
      ->(*, payload) { message_counts << payload[:message_count] },
      "prompt.provider.active_agent"
    ) do
      2.times do |i|
        Persistence::SupportAgent.with(
          user: subject_record, message: "Turn #{i}"
        ).answer.generate_now
      end
    end

    context = AgentContext.for_agent("Persistence::SupportAgent").sole

    assert_equal 1, AgentContext.count, "expected both turns to share one context"
    assert_equal %w[user assistant user assistant], context.messages.chronological.map(&:role)
    assert_equal 2, context.generations.count

    # The point of persistence: the second request sent the stored exchange
    # back to the provider — one message, then three.
    assert_equal [ 1, 3 ], message_counts
  end

  test "each generation records provenance and a trace id" do
    Persistence::SupportAgent.with(
      user: subject_record, message: "Trace me"
    ).answer.generate_now

    generation = AgentGeneration.sole

    assert generation.trace_id.present?, "expected a trace_id for telemetry correlation"
    assert_equal "Persistence::SupportAgent", generation.provenance["agent_class"]
    assert_equal "answer", generation.provenance["action_name"]
    assert generation.provenance["prompt_checksum"].present?
    assert generation.provenance["agent_checksum"].present?

    assert_equal [ generation ], AgentGeneration.with_trace(generation.trace_id).to_a
  end

  test "token counts roll up onto the context" do
    Persistence::SupportAgent.with(
      user: subject_record, message: "Count me"
    ).answer.generate_now

    context = AgentContext.sole
    generation = context.generations.sole

    assert_equal generation.input_tokens, context.total_input_tokens
    assert_equal generation.output_tokens, context.total_output_tokens
    assert_equal context.total_input_tokens + context.total_output_tokens, context.total_tokens
  end
end
