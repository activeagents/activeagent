# frozen_string_literal: true

require "active_support/descendants_tracker"

module ActiveAgent
  module Previews # :nodoc:
    extend ActiveSupport::Concern

    included do
      mattr_accessor :preview_paths, instance_writer: false, default: []

      mattr_accessor :show_previews, instance_writer: false

      mattr_accessor :preview_interceptors, instance_writer: false, default: [ ActiveAgent::InlinePreviewInterceptor ]
    end

    module ClassMethods
      # Register one or more Interceptors which will be called before prompt is previewed.
      def register_preview_interceptors(*interceptors)
        interceptors.flatten.compact.each { |interceptor| register_preview_interceptor(interceptor) }
      end

      # Unregister one or more previously registered Interceptors.
      def unregister_preview_interceptors(*interceptors)
        interceptors.flatten.compact.each { |interceptor| unregister_preview_interceptor(interceptor) }
      end

      # Register an Interceptor which will be called before prompt is previewed.
      # Either a class or a string can be passed in as the Interceptor. If a
      # string is passed in it will be constantized.
      def register_preview_interceptor(interceptor)
        preview_interceptor = interceptor_class_for(interceptor)

        unless preview_interceptors.include?(preview_interceptor)
          preview_interceptors << preview_interceptor
        end
      end

      # Unregister a previously registered Interceptor.
      # Either a class or a string can be passed in as the Interceptor. If a
      # string is passed in it will be constantized.
      def unregister_preview_interceptor(interceptor)
        preview_interceptors.delete(interceptor_class_for(interceptor))
      end

      private

      def interceptor_class_for(interceptor)
        case interceptor
        when String, Symbol
          interceptor.to_s.camelize.constantize
        else
          interceptor
        end
      end
    end
  end

  class Preview
    extend ActiveSupport::DescendantsTracker

    attr_reader :params

    def initialize(params = {})
      @params = params
    end

    class << self
      # Returns all agent preview classes.
      def all
        load_previews if descendants.empty?
        descendants.sort_by { |agent| agent.name.titleize }
      end

      # Returns the prompt object for the given context. The registered preview
      # interceptors will be informed so that they can transform the message
      # as they would if the mail was actually being delivered.
      def call(context, params = {})
        preview = new(params)
        prompt = preview.public_send(context)
        inform_preview_interceptors(prompt)
        prompt
      end

      # Returns all of the available prompt previews.
      def prompts
        public_instance_methods(false).map(&:to_s).sort
      end

      # Returns +true+ if the prompt exists.
      def prompt_exists?(prompt)
        prompts.include?(prompt)
      end

      # Returns +true+ if the preview exists.
      def exists?(preview)
        all.any? { |p| p.preview_name == preview }
      end

      # Find a agent preview by its underscored class name.
      def find(preview)
        all.find { |p| p.preview_name == preview }
      end

      # Returns the underscored name of the agent preview without the suffix.
      def preview_name
        name.delete_suffix("Preview").underscore
      end

      private

      def load_previews
        preview_paths.each do |preview_path|
          Dir["#{preview_path}/**/*_preview.rb"].sort.each { |file| require file }
        end
      end

      def preview_paths
        Base.preview_paths
      end

      def show_previews
        Base.show_previews
      end

      def inform_preview_interceptors(context)
        Base.preview_interceptors.each do |interceptor|
          interceptor.previewing_prompt(context)
        end
      end
    end
  end
end
