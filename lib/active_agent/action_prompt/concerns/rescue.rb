# frozen_string_literal: true

module ActiveAgent
  module ActionPrompt
    # Provides exception handling capabilities for action prompts.
    #
    # Includes ActiveSupport::Rescuable to enable `rescue_from` declarations
    # that catch and handle exceptions during prompt processing.
    #
    # Note: Handler methods referenced in `rescue_from` must be public or protected,
    # as ActiveSupport::Rescuable uses `Kernel#method()` to look them up.
    #
    # @see https://github.com/rails/rails/blob/main/actionpack/lib/action_controller/metal/rescue.rb
    # @see ActiveSupport::Rescuable
    module Rescue
      extend ActiveSupport::Concern
      include ActiveSupport::Rescuable

      class_methods do
        # Finds and instruments the rescue handler for an exception.
        #
        # @param exception [Exception] the exception to handle
        # @return [Proc, nil] the handler proc if found, nil otherwise
        # @api private
        # def handler_for_rescue(exception, ...)
        #   if (handler = super)
        #     ActiveSupport::Notifications.instrument("rescue_from_callback.action_prompt.active_agent", exception:)
        #     handler
        #   end
        # end
      end

      def handle_exceptions
        yield
      rescue Exception => exception
        rescue_with_handler(exception) || raise
      end

      private

      # Processes the prompt with exception handling.
      # Rescues exceptions using registered handlers or re-raises.
      #
      # @raise [Exception] if no handler is found
      # @api private
      def process(...)
        super
      rescue Exception => exception
        rescue_with_handler(exception) || raise
      end
    end
  end
end
