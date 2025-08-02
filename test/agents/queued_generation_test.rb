require "test_helper"

class QueuedGenerationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  test "generate_later enqueues a generation job" do
    # region queued_generation_generate_later
    prompt = ApplicationAgent.with(message: "Process this later").prompt_context

    # Enqueue the generation job
    assert_enqueued_with(job: ActiveAgent::GenerationJob) do
      prompt.generate_later
    end
    # endregion queued_generation_generate_later
  end

  test "generate_later with custom queue and priority" do
    # region queued_generation_custom_queue
    prompt = ApplicationAgent.with(message: "Priority task").prompt_context

    # Enqueue with specific queue and priority
    assert_enqueued_with(
      job: ActiveAgent::GenerationJob,
      queue: "high_priority"
    ) do
      prompt.generate_later(queue: "high_priority", priority: 10)
    end
    # endregion queued_generation_custom_queue
  end
end
