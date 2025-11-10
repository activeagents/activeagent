# frozen_string_literal: true

module ActiveAgent
  # Provides exception handling for action prompts using `rescue_from` declarations.
  #
  # Handler methods must be public or protected because ActiveSupport::Rescuable
  # uses `Kernel#method()` for lookup.
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
      #     ActiveSupport::Notifications.instrument("rescue_from_callback.active_agent", exception:)
      #     handler
      #   end
      # end
    end

    # Yields to block with exception handling.
    # Rescues using registered handlers or re-raises.
    #
    # @yield block to execute with exception handling
    # @raise [Exception] if no handler is registered for the exception
    def handle_exceptions
      yield
    rescue Exception => exception
      rescue_with_handler(exception) || raise
    end

    private

    # Processes the prompt with exception handling.
    #
    # Overrides parent to rescue exceptions using registered handlers.
    #
    # @raise [Exception] if no handler is registered for the exception
    # @api private
    def process(...)
      super
    rescue Exception => exception
      rescue_with_handler(exception) || raise
    end

    # Returns proc that rescues exceptions using registered handlers.
    #
    # @return [Proc]
    # @api private
    def exception_handler
      proc do |exception|
        rescue_with_handler(exception)
      end
    end
  end
end
