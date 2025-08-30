# frozen_string_literal: true

require "active_agent/action_prompt"
require "active_agent/prompt_helper"
require "active_agent/action_prompt/base"

# The ActiveAgent module provides a framework for creating agents that can generate content
# and handle various actions. The Base class within this module extends AbstractController::Base
# and includes several modules to provide additional functionality such as callbacks, generation
# methods, and rescuable actions.
#
# The Base class defines several class methods for registering and unregistering observers and
# interceptors, as well as methods for generating content with a specified provider and streaming
# content. It also provides methods for setting default parameters and handling prompts.
#
# The instance methods in the Base class include methods for performing generation, processing
# actions, and handling headers and attachments. The class also defines a NullPrompt class for
# handling cases where no prompt is provided.
#
# The Base class uses ActiveSupport::Notifications for instrumentation and provides several
# private methods for setting payloads, applying defaults, and collecting responses from blocks,
# text, or templates.
#
# The class also includes several protected instance variables and defines hooks for loading
# additional functionality.
module ActiveAgent
  class Base < ActiveAgent::ActionPrompt::Base
    # This class is the base class for agents in the ActiveAgent framework.
    # It is built on top of ActionPrompt which provides methods for generating content, handling actions, and managing prompts.
    # ActiveAgent::Base is designed to be extended by specific agent implementations.
    # It provides a common set of agent actions for self-contained agents that can determine their own actions using all available actions.
    # Base actions include: prompt_context, continue, reasoning, reiterate, and conclude
    
    # Include SolidAgent persistence if available
    # This will be included when solid_agent gem is installed
    # For now, check if constants are defined
    if defined?(SolidAgent) && defined?(SolidAgent::Persistable)
      include SolidAgent::Persistable
    end
    
    if defined?(SolidAgent) && defined?(SolidAgent::Actionable)
      include SolidAgent::Actionable
    end
    
    # Track prompt-generation cycles
    around_action :track_prompt_generation_cycle, if: :solid_agent_enabled?
    
    def prompt_context(additional_options = {})
      prompt(
        {
          stream: params[:stream],
          messages: params[:messages],
          message: params[:message],
          context_id: params[:context_id],
          options: params[:options],
          mcp_servers: params[:mcp_servers]
        }.merge(additional_options)
      )
    end
    
    private
    
    def solid_agent_enabled?
      defined?(SolidAgent) && respond_to?(:solid_agent_enabled) && solid_agent_enabled
    end
    
    def track_prompt_generation_cycle
      return yield unless solid_agent_enabled?
      
      # Start a new prompt-generation cycle
      @_prompt_generation_cycle = SolidAgent::Models::PromptGenerationCycle.new(
        contextual: determine_contextual,
        agent: SolidAgent::Models::Agent.register(self.class),
        status: "prompting",
        started_at: Time.current
      )
      
      # Track the prompt phase
      @_prompt_generation_cycle.track_prompt_construction do
        yield
      end
      
      # The generation will be tracked by the Persistable module
      @_prompt_generation_cycle.save!
    ensure
      # Complete or fail the cycle based on outcome
      if @_prompt_generation_cycle&.persisted?
        if @_solid_generation&.completed?
          @_prompt_generation_cycle.complete!(@_solid_generation.attributes)
        elsif @_solid_generation&.failed?
          @_prompt_generation_cycle.fail!(@_solid_generation.error_message)
        end
      end
    end
    
    def determine_contextual
      # Try to find the contextual object (User, Session, Job, etc.)
      if respond_to?(:current_user) && current_user
        current_user
      elsif respond_to?(:session) && session
        session
      elsif defined?(@job) && @job
        @job
      else
        nil
      end
    end
  end
end
