# frozen_string_literal: true

require "active_support/callbacks"

module ActiveAgent
  # Provides callback hooks for prompting and embedding lifecycles.
  #
  # Enables agents to execute custom logic before, after, or around prompt execution
  # and embedding operations. Callbacks support conditional execution via `:if` and
  # `:unless` options, and after callbacks are skipped when the chain is terminated
  # with `throw :abort`.
  #
  # @example Before prompting callback
  #   class MyAgent < ActiveAgent::Base
  #     before_prompting :load_context
  #
  #     def load_context
  #       @user_data = User.find(params[:user_id])
  #     end
  #   end
  #
  # @example After prompting with condition
  #   class MyAgent < ActiveAgent::Base
  #     after_prompting :log_response, if: :production?
  #
  #     def log_response
  #       Logger.info("Generated response: #{context.messages.last}")
  #     end
  #   end
  #
  # @example Around embedding for timing
  #   class MyAgent < ActiveAgent::Base
  #     around_embedding :measure_time
  #
  #     def measure_time
  #       start = Time.now
  #       yield
  #       Rails.logger.info("Embedding took #{Time.now - start}s")
  #     end
  #   end
  module Callbacks
    extend ActiveSupport::Concern

    included do
      include ActiveSupport::Callbacks
      define_callbacks :prompting, skip_after_callbacks_if_terminated: true
      define_callbacks :embedding, skip_after_callbacks_if_terminated: true
    end

    module ClassMethods
      # Registers callbacks for the prompting lifecycle.
      #
      # Dynamically defines `before_prompting`, `after_prompting`, and
      # `around_prompting` class methods. Multiple callbacks execute in
      # registration order for before/around, and reverse order for after.
      #
      # @param names [Symbol, Array<Symbol>] method name(s) to call
      # @param blk [Proc] optional block to execute instead of named method
      # @yield callback implementation when using block form
      #
      # @example Multiple before callbacks
      #   before_prompting :load_user, :check_permissions
      #
      # @example Block syntax
      #   after_prompting do
      #     cache.write("last_response", context.messages.last)
      #   end
      [ :before, :after, :around ].each do |callback|
        define_method "#{callback}_prompting" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:prompting, callback, name, options)
          end
        end

        # Deprecated: Use #{callback}_prompting instead
        # Sets callbacks on both :generation and :prompting chains for backward compatibility
        define_method "#{callback}_generation" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:prompting, callback, name, options)
          end
        end

        # Registers callbacks for the embedding lifecycle.
        #
        # Dynamically defines `before_embedding`, `after_embedding`, and
        # `around_embedding` class methods. Behavior identical to prompting
        # callbacks but invoked during embedding operations.
        #
        # @param names [Symbol, Array<Symbol>] method name(s) to call
        # @param blk [Proc] optional block to execute instead of named method
        # @yield callback implementation when using block form
        #
        # @example Track embedding calls
        #   before_embedding :increment_counter
        #   after_embedding :store_embedding
        define_method "#{callback}_embedding" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:embedding, callback, name, options)
          end
        end
      end
    end
  end
end
