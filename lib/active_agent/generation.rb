# frozen_string_literal: true

require "active_agent/providers/common/messages/_types"

module ActiveAgent
  # Deferred agent action ready for synchronous or asynchronous execution.
  #
  # Returned when calling agent actions. Provides methods to execute immediately
  # or queue for background processing, plus access to prompt properties before execution.
  #
  # @example Synchronous generation
  #   generation = MyAgent.with(message: "Hello").greet
  #   response = generation.prompt_now
  #
  # @example Asynchronous generation
  #   MyAgent.with(message: "Hello").greet.prompt_later(queue: :prompts)
  #
  # @example Accessing prompt properties before generation
  #   generation = MyAgent.prompt(message: "Hello")
  #   generation.message.content  # => "Hello"
  #   generation.messages         # => [...]
  class Generation
    attr_internal :agent_class, :action_name, :args, :kwargs

    # @param agent_class [Class]
    # @param action_name [Symbol]
    # @param args [Array]
    # @param kwargs [Hash]
    def initialize(agent_class, action_name, *args, **kwargs)
      self.agent_class, self.action_name, self.args, self.kwargs = agent_class, action_name, args, kwargs
    end

    # @return [Boolean]
    def processed?
      !!@agent
    end

    # Accesses prompt options by processing the agent if needed.
    #
    # Lazily processes the agent on first access, allowing inspection of
    # prompt properties before executing generation.
    #
    # @return [Hash] with :messages, :actions, and configuration keys
    def prompt_options
      agent.prompt_options
    end

    # @return [Hash] configuration options excluding messages and actions
    def options
      prompt_options.except(:messages, :actions)
    end

    def instructions
      agent.prompt_view_instructions(prompt_options[:instructions])
    end

    # @return [Array]
    def messages
      prompt_options[:messages] || []
    end

    # Returns the last message with consistent `.content` access.
    #
    # Wraps various message formats (String, Hash, objects) using the common
    # MessageType for uniform access patterns.
    #
    # @return [ActiveAgent::Providers::Common::Messages::Base, nil]
    def message
      last_message = messages.last
      return nil unless last_message

      message_type.cast(last_message)
    end

    # @return [Array]
    def actions
      prompt_options[:actions] || []
    end

    # Executes prompt generation synchronously with immediate processing.
    #
    # @return [ActiveAgent::Providers::Response]
    def prompt_now!
      agent.process_prompt!
    end
    alias generate_now! prompt_now!

    # Executes prompt generation synchronously.
    #
    # @return [ActiveAgent::Providers::Response]
    def prompt_now
      agent.process_prompt
    end
    alias generate_now prompt_now

    # Queues for background execution.
    #
    # @param options [Hash] job options (queue, priority, wait, etc.)
    # @return [Object] enqueued job instance
    # @raise [RuntimeError] if agent was accessed before queueing
    def prompt_later(options = {})
      enqueue_generation :prompt_now, options
    end
    alias generate_later prompt_later

    # Continues a generation that paused for user input.
    #
    # Call it on the generation that paused, or on one built the same way —
    # same agent, action, arguments and params — in another request or
    # process. A new generation runs the action again, so tools, instructions
    # and options are rebuilt. Either way the conversation is replaced with
    # the checkpoint's, and each paused tool call is dispatched again with
    # its answer readable through {InputRequest.answer_for}. Calls that
    # finished before the pause keep their results.
    #
    # @param checkpoint [Hash] the paused response's
    #   {Providers::Common::Responses::Prompt#checkpoint checkpoint}
    # @param answers [Hash{String => Object}] an answer per paused tool call
    #   id; `false` declines
    # @return [ActiveAgent::Providers::Common::PromptResponse] which may itself
    #   be awaiting input again
    # @raise [InputRequest::ResumeError] before any tool runs or any request
    #   is sent, when an answer is missing or does not fit its request, or the
    #   checkpoint was taken by another action, provider or model
    #
    # @example
    #   response = SupportAgent.with(ticket:).triage.generate_now
    #   if response.awaiting_input?
    #     request = response.input_requests.first
    #     SupportAgent.with(ticket:).triage.resume_now(
    #       checkpoint: response.checkpoint,
    #       answers: { request.tool_call_id => true }
    #     )
    #   end
    def resume_now(checkpoint:, answers:)
      agent.resume_prompt(checkpoint:, answers:)
    end

    # Queues {#resume_now} for background execution on the agent's
    # generation job, which runs the action again from its arguments, params
    # and actor.
    #
    # The checkpoint and answers become job arguments, stored by the queue
    # backend for as long as the job lives. A `:secret` answer is therefore
    # refused: resume a generation that waits on a secret inside your own
    # job, which reads the answer from where your app keeps it.
    #
    # @param checkpoint [Hash] the paused response's checkpoint
    # @param answers [Hash{String => Object}] an answer per paused tool call
    #   id; `false` declines
    # @param options [Hash] job options (queue, priority, wait, etc.)
    # @return [Object] enqueued job instance
    # @raise [InputRequest::ResumeError] before enqueueing, when an answer is
    #   missing, does not fit its request, or answers a `:secret` request
    # @raise [RuntimeError] if agent was accessed before queueing
    def resume_later(checkpoint:, answers:, **options)
      if InputRequest::Resume.new(checkpoint:, answers:).secret_answers.any?
        ::Kernel.raise InputRequest::ResumeError, "resume_later cannot carry the answer to a :secret request, because job " \
          "arguments are stored with the job. Call resume_now from your own job, reading the answer from where your app keeps it."
      end

      enqueue_generation :resume_now, options, resume: { "checkpoint" => checkpoint.as_json, "answers" => answers.as_json }
    end

    # Generates a preview of the prompt without executing generation.
    #
    # Processes the agent action and renders the prompt configuration as
    # markdown for debugging and inspection.
    #
    # @return [String] markdown-formatted preview
    def prompt_preview
      agent.preview_prompt
    end
    alias preview_prompt prompt_preview

    # Executes embedding generation synchronously.
    #
    # @return [ActiveAgent::Providers::Response] embedding response with vector data
    def embed_now
      agent.process_embed
    end

    # Queues embedding generation for background execution.
    #
    # @param options [Hash] job options (queue, priority, wait, etc.)
    # @return [Object] enqueued job instance
    # @raise [RuntimeError] if agent was accessed before queueing
    def embed_later(options = {})
      enqueue_generation :embed_now, options
    end

    private

    # Lazily instantiates and processes the agent instance.
    #
    # Cached after first call.
    #
    # @return [ActiveAgent::Base]
    # @api private
    def agent
      @agent ||= agent_class.new.tap do |agent|
        agent.params = @params
        agent.process(action_name, *args, **kwargs)
      end
    end

    # Enqueues for background processing.
    #
    # Prevents enqueuing if the agent has been accessed, as local changes
    # would be lost. Only method arguments are passed to the job, not the
    # agent instance state.
    #
    # @param generation_method [Symbol, String]
    # @param options [Hash]
    # @param job_arguments [Hash] further keyword arguments for the job
    # @return [Object] enqueued job
    # @raise [RuntimeError] when agent already processed to prevent data loss
    # @api private
    def enqueue_generation(generation_method, options = {}, **job_arguments)
      if processed?
        ::Kernel.raise "You've accessed the agent before asking to " \
          "generate it later, so you may have made local changes that would " \
          "be silently lost if we enqueued a job to generate it. Why? Only " \
          "the agent method *arguments* are passed with the generation job! " \
          "Do not access the agent in any way if you mean to generate it " \
          "later. Workarounds: 1. don't touch the agent before calling " \
          "#prompt_later, 2. only touch the agent *within your agent " \
          "method*, or 3. use a custom Active Job instead of #prompt_later."
      else
        agent_class.generation_job.set(options).perform_later(
          agent_class.name, action_name.to_s, generation_method.to_s, args: args, kwargs: kwargs, **job_arguments
        )
      end
    end

    # Lazy-loaded message type instance for casting messages.
    #
    # @return [ActiveAgent::Providers::Common::Messages::Types::MessageType]
    # @api private
    def message_type
      @message_type ||= ActiveAgent::Providers::Common::Messages::Types::MessageType.new
    end
  end
end
