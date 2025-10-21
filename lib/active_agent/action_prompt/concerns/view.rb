# frozen_string_literal: true

require "active_agent/collector"

module ActiveAgent
  module ActionPrompt
    # Provides template lookup and rendering for ActionPrompt classes.
    #
    # This concern enables:
    # - Rendering instructions from templates or direct strings
    # - Loading JSON schemas from template files
    # - Collecting responses from templates, blocks, or text
    # - Creating message parts for multi-part responses
    module View
      extend ActiveSupport::Concern

      private

      ##### Instructions Templating ###########################################

      # Prepares instructions from various input formats.
      #
      # Accepts:
      # - String: returned as-is
      # - Symbol: calls method with that name (like ActiveRecord callbacks)
      # - Array: must contain only strings
      # - Hash: must have :template key, optional :locals
      # - nil: renders default "instructions" template
      #
      # @param param [Hash, String, Symbol, Array, nil]
      # @return [String, Array<String>, nil] nil if template not found
      # @raise [ArgumentError] if format is invalid or Hash missing :template key
      def prompt_view_instructions(param)
        case param
        when String
          param.presence

        when Symbol
          send(param)

        when Array
          raise ArgumentError, "Instructions array must contain only strings" unless param.all?(String)
          param.presence

        when Hash
          raise ArgumentError, "Expected `:template` key in instructions hash" unless param[:template]
          view_render_template(param[:template], **param[:locals])

        when nil
          view_render_template("instructions")

        else
          raise ArgumentError, "Instructions must be Hash, String, Symbol or nil"
        end
      end

      ##### Action Templating #################################################

      def prompt_view_message(action_name, **locals)
        view_render_template(action_name, **locals)
      end

      def embed_view_input(action_name, **locals)
        view_render_template(action_name, **locals)
      end

      ##### Shared Helpers ####################################################

      # Renders a template if it exists in any supported ERB format.
      #
      # @param template_name [String, Symbol]
      # @param locals [Hash]
      # @return [String, nil] nil if template not found
      def view_render_template(template_name, **locals)
        return unless lookup_context.exists?(template_name, agent_name, false)

        template = lookup_context.find_template(template_name, agent_name, false)

        render_to_string(template: template.virtual_path, locals:, layout: false).chomp.presence
      end

      ##################################################################################################################


      # Returns JSON schemas for all action methods.
      #
      # Looks for JSON templates corresponding to each action method name.
      #
      # @return [Array<Hash>]
      def action_schemas
        prefixes = set_prefixes(action_name, lookup_context.prefixes)

        action_methods.map do |action|
          render_schema(action, prefixes)
        end.compact
      end

      # Sets template prefixes for schema lookup.
      #
      # @param action [String] unused but kept for signature compatibility
      # @param prefixes [Array<String>]
      # @return [Array<String>] prefixes including agent name
      def set_prefixes(action, prefixes)
        prefixes = lookup_context.prefixes | [ self.class.agent_name ]
      end

      # Renders JSON schema from template or returns it directly if already a Hash.
      #
      # @param schema_or_action [Hash, String] schema hash or action name for template lookup
      # @param prefixes [Array<String>]
      # @return [Hash, nil] nil if template not found
      def render_schema(schema_or_action, prefixes)
        # If it's already a hash (direct schema), return it
        return schema_or_action if schema_or_action.is_a?(Hash)

        # Otherwise try to load from template
        return unless lookup_context.template_exists?(schema_or_action, prefixes, false, formats: [ :json ])

        JSON.parse render_to_string(locals: { action_name: schema_or_action }, action: schema_or_action, formats: :json)
      end

      # Collects responses from various sources.
      #
      # Routes to appropriate collection method based on whether a block is given
      # or args contains :body.
      #
      # @param args [Hash] may include :body, :template_name, etc.
      # @yield [collector] optional collector for building custom responses
      # @return [Array<Hash>] with :body and :content_type keys
      def collect_responses(args, &)
        if block_given?
          collect_responses_from_block(args, &)
        elsif args[:body]
          collect_responses_from_text(args)
        else
          collect_responses_from_templates(args)
        end
      end

      # Collects responses by yielding a collector to the given block.
      #
      # @param args [Hash] may include :template_name (defaults to action_name)
      # @yield [collector] ActiveAgent::Collector instance
      # @return [Array<Hash>]
      def collect_responses_from_block(args)
        templates_name = args[:template_name] || action_name
        collector = ActiveAgent::Collector.new(lookup_context) { render(templates_name) }
        yield(collector)
        collector.responses
      end

      # Collects response from direct text provided in args.
      #
      # @param args [Hash] must include :body, optional :content_type (defaults to "text/plain")
      # @return [Array<Hash>] single-element array
      def collect_responses_from_text(args)
        [ {
          body: args.delete(:body),
          content_type: args[:content_type] || "text/plain"
        } ]
      end

      # Collects responses by rendering templates for each available format.
      #
      # Skips JSON templates unless :format is explicitly :json.
      #
      # @param args [Hash] may include :template_path, :template_name, :format
      # @return [Array<Hash>]
      def collect_responses_from_templates(args)
        templates_path = args[:template_path] || self.class.agent_name
        templates_name = args[:template_name] || action_name
        each_template(Array(templates_path), templates_name).map do |template|
          next if template.format == :json && args[:format] != :json
          format = template.format || formats.first
          {
            body: render(template: template, formats: [ format ]),
            content_type: Mime[format].to_s
          }
        end.compact
      end

      # Finds and iterates over all templates matching name in paths.
      #
      # Templates are deduplicated by format.
      #
      # @param paths [Array<String>]
      # @param name [String]
      # @yield [template] each unique template found
      # @raise [ActionView::MissingTemplate] when no templates match
      def each_template(paths, name, &)
        templates = lookup_context.find_all(name, paths)
        if templates.empty?
          raise ActionView::MissingTemplate.new(paths, name, paths, false, "agent")
        else
          templates.uniq(&:format).each(&)
        end
      end
    end
  end
end
