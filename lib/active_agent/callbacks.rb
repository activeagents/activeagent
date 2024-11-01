# frozen_string_literal: true

module ActiveAgent
  module Callbacks
    extend ActiveSupport::Concern

    included do
      include ActiveSupport::Callbacks
      define_callbacks :generate, skip_after_callbacks_if_terminated: true
    end

    module ClassMethods
      # Defines a callback that will get called right before the
      # prompt is sent to the generation provider method.
      def before_generate(*filters, &)
        set_callback(:generate, :before, *filters, &)
      end

      # Defines a callback that will get called right after the
      # prompt's generation method is finished.
      def after_generate(*filters, &)
        set_callback(:generate, :after, *filters, &)
      end

      # Defines a callback that will get called around the prompt's generation method.
      def around_generate(*filters, &)
        set_callback(:generate, :around, *filters, &)
      end
    end
  end
end
