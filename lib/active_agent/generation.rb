# lib/active_agent/generation.rb
require "delegate"

module ActiveAgent
  class Generation < Delegator
    def initialize(agent_class, action, *args)
      @agent_class, @action, @args = agent_class, action, args
      @processed_agent = nil
      @prompt_context = nil
    end
    ruby2_keywords(:initialize)

    def __getobj__
      @prompt_context ||= processed_agent.context
    end

    def __setobj__(prompt_context)
      @prompt_context = prompt_context
    end

    def context
      __getobj__
    end

    def processed?
      @processed_agent || @prompt_context
    end

    def generate_later!(options = {})
      enqueue_generation :generate_now!, options
    end

    def generate_later(options = {})
      enqueue_generation :generate_now, options
    end

    def generate_now!
      processed_agent.handle_exceptions do
        processed_agent.run_callbacks(:generate) do
          processed_agent.perform_generation!
        end
      end
    end

    def generate_now
      processed_agent.handle_exceptions do
        processed_agent.run_callbacks(:generate) do
          processed_agent.perform_generation
        end
      end
    end

    private

    def processed_agent
      @processed_agent ||= @agent_class.new.tap do |agent|
        agent.process(@action, *@args)
      end
    end

    def enqueue_generation(generation_method, options = {})
      if processed?
        ::Kernel.raise "You've accessed the context before asking to " \
          "generate it later, so you may have made local changes that would " \
          "be silently lost if we enqueued a job to generate it. Why? Only " \
          "the agent method *arguments* are passed with the generation job! " \
          "Do not access the context in any way if you mean to generate it " \
          "later. Workarounds: 1. don't touch the context before calling " \
          "#generate_later, 2. only touch the context *within your agent " \
          "method*, or 3. use a custom Active Job instead of #generate_later."
      else
        @agent_class.generation_job.set(options).perform_later(
          @agent_class.name, @action.to_s, args: @args
        )
      end
    end
  end
end
