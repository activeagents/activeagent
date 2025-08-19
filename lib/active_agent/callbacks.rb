# frozen_string_literal: true

module ActiveAgent
  module Callbacks
    extend ActiveSupport::Concern

    included do
      include ActiveSupport::Callbacks
      define_callbacks :generation, skip_after_callbacks_if_terminated: true
    end

    module ClassMethods
      # # Defines a callback that will get called right before/after/around the
      # # generation provider method.
      [ :before, :after, :around ].each do |callback|
        define_method "#{callback}_generation" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:generation, callback, name, options)
          end
        end
      end
    end
  end
end
