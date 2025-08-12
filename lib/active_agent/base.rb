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
  end
end
