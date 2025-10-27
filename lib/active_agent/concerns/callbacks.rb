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
  # == Callback Types
  #
  # Each lifecycle supports three timing hooks:
  # * +before_*+ - executes before the operation
  # * +after_*+ - executes after the operation (skipped if aborted)
  # * +around_*+ - wraps the operation (must call +yield+)
  #
  # == Callback Control
  #
  # * +prepend_*+ - inserts callback at the beginning of the chain
  # * +append_*+ - adds callback at the end (same as base methods)
  # * +skip_*+ - removes a previously defined callback
  #
  # @example Before prompting callback
  #   class MyAgent < ActiveAgent::Base
  #     before_prompt :load_context
  #
  #     def load_context
  #       @user_data = User.find(params[:user_id])
  #     end
  #   end
  #
  # @example After prompting with condition
  #   class MyAgent < ActiveAgent::Base
  #     after_prompt :log_response, if: :production?
  #
  #     def log_response
  #       Logger.info("Generated response: #{context.messages.last}")
  #     end
  #   end
  #
  # @example Around embedding for timing
  #   class MyAgent < ActiveAgent::Base
  #     around_embed :measure_time
  #
  #     def measure_time
  #       start = Time.now
  #       yield
  #       Rails.logger.info("Embedding took #{Time.now - start}s")
  #     end
  #   end
  #
  # @example Prepending and skipping callbacks
  #   class MyAgent < ActiveAgent::Base
  #     prepend_before_prompt :urgent_check  # Runs first
  #     before_prompt :normal_check          # Runs second
  #
  #     skip_after_prompt :log_response      # Removes inherited callback
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
      # Dynamically defines callback methods for each timing hook.
      # Multiple callbacks execute in registration order for before/around,
      # and reverse order for after.
      #
      # @param names [Symbol, Array<Symbol>] method name(s) to call
      # @param blk [Proc] optional block to execute instead of named method
      # @yield callback implementation when using block form
      #
      # @example Multiple before callbacks
      #   before_prompt :load_user, :check_permissions
      #
      # @example Block syntax
      #   after_prompt do
      #     cache.write("last_response", context.messages.last)
      #   end
      [ :before, :after, :around ].each do |callback|
        define_method "#{callback}_prompt" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:prompting, callback, name, options)
          end
        end

        # Prepends a callback to the beginning of the prompting chain.
        #
        # Useful for ensuring critical setup runs before other callbacks.
        #
        # @param names [Symbol, Array<Symbol>] method name(s) to call
        # @param blk [Proc] optional block to execute
        #
        # @example Prepend urgent validation
        #   prepend_before_prompt :validate_api_key
        define_method "prepend_#{callback}_prompt" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:prompting, callback, name, options.merge(prepend: true))
          end
        end

        # Skips a previously defined prompting callback.
        #
        # Useful for removing inherited callbacks or disabling callbacks
        # conditionally in subclasses.
        #
        # @param names [Symbol, Array<Symbol>] method name(s) to skip
        #
        # @example Skip inherited callback
        #   skip_after_prompt :log_response
        define_method "skip_#{callback}_prompt" do |*names|
          _insert_callbacks(names) do |name, options|
            skip_callback(:prompting, callback, name, options)
          end
        end

        # Alias for explicit append behavior (same as base method).
        alias_method :"append_#{callback}_prompt", :"#{callback}_prompt"

        # Deprecated: Use #{callback}_prompt instead
        # Sets callbacks on the prompting chain for backward compatibility
        define_method "#{callback}_generation" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:prompting, callback, name, options)
          end
        end

        # Deprecated: Use prepend_#{callback}_prompt instead
        define_method "prepend_#{callback}_generation" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:prompting, callback, name, options.merge(prepend: true))
          end
        end

        # Deprecated: Use skip_#{callback}_prompt instead
        define_method "skip_#{callback}_generation" do |*names|
          _insert_callbacks(names) do |name, options|
            skip_callback(:prompting, callback, name, options)
          end
        end

        # Deprecated: Use append_#{callback}_prompt instead
        alias_method :"append_#{callback}_generation", :"#{callback}_generation"

        # Registers callbacks for the embedding lifecycle.
        #
        # Behavior identical to prompting callbacks but invoked during
        # embedding operations.
        #
        # @param names [Symbol, Array<Symbol>] method name(s) to call
        # @param blk [Proc] optional block to execute instead of named method
        # @yield callback implementation when using block form
        #
        # @example Track embedding calls
        #   before_embed :increment_counter
        #   after_embed :store_embedding
        define_method "#{callback}_embed" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:embedding, callback, name, options)
          end
        end

        # Prepends a callback to the beginning of the embedding chain.
        #
        # @param names [Symbol, Array<Symbol>] method name(s) to call
        # @param blk [Proc] optional block to execute
        #
        # @example Prepend rate limiting
        #   prepend_before_embed :check_rate_limit
        define_method "prepend_#{callback}_embed" do |*names, &blk|
          _insert_callbacks(names, blk) do |name, options|
            set_callback(:embedding, callback, name, options.merge(prepend: true))
          end
        end

        # Skips a previously defined embedding callback.
        #
        # @param names [Symbol, Array<Symbol>] method name(s) to skip
        #
        # @example Skip inherited callback
        #   skip_before_embed :validate_input
        define_method "skip_#{callback}_embed" do |*names|
          _insert_callbacks(names) do |name, options|
            skip_callback(:embedding, callback, name, options)
          end
        end

        # Alias for explicit append behavior (same as base method).
        alias_method :"append_#{callback}_embed", :"#{callback}_embed"
      end
    end
  end
end
