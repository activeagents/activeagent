# frozen_string_literal: true

module ActiveAgent # :nodoc:
  # = Active Agent \Rescuable
  #
  # Provides
  # {rescue_from}[rdoc-ref:ActiveSupport::Rescuable::ClassMethods#rescue_from]
  # for agents. Wraps agent action processing, generation job processing, and prompt
  # generation to handle configured errors.
  module Rescuable
    extend ActiveSupport::Concern
    include ActiveSupport::Rescuable

    class_methods do
      def handle_exception(exception) # :nodoc:
        rescue_with_handler(exception) || raise(exception)
      end
    end

    def handle_exceptions # :nodoc:
      yield
    rescue => exception
      rescue_with_handler(exception) || raise
    end

    private

    def process(...)
      handle_exceptions do
        super
      end
    end
  end
end
