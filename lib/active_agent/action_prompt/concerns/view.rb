# frozen_string_literal: true

require "active_agent/action_prompt/message"
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
      # - Symbol: renders template with that name
      # - Array: must contain only strings
      # - Hash: must have :template key, optional :locals
      # - nil: renders default "instructions" template
      #
      # @param param [Hash, String, Symbol, Array, nil] Instructions input
      # @return [String, Array<String>, nil] Prepared instructions or nil if template not found
      # @raise [ArgumentError] If format is invalid or Hash missing :template key
      def prompt_view_instructions(param)
        case param
        when String
          param.presence

        when Symbol
          view_render_template(param)

        when Array
          raise ArgumentError, "Instructions array must contain only strings" unless param.all?(String)
          param.presence

        when Hash
          raise ArgumentError, "Expected `:template` key in instructions hash" unless param[:template]
          view_render_template(param[:template], param[:locals])

        when nil
          view_render_template("instructions")

        else
          raise ArgumentError, "Instructions must be Hash, String, Symbol or nil"
        end
      end

      ##### Action Templating #################################################

      ##### Shared Helpers ####################################################

      # Renders a text template if it exists.
      #
      # @param template_name [String, Symbol] Name of template to render
      # @param locals [Hash] Local variables to pass to template
      # @return [String, nil] Rendered template content or nil if not found
      def view_render_template(template_name, locals = {})
        return unless lookup_context.exists?(template_name, agent_name, false, [], formats: [ :text ])

        template = lookup_context.find_template(template_name, agent_name, false, [], formats: [ :text ])

        render_to_string(template: template.virtual_path, locals:, layout: false).chomp.presence
      end

      ##################################################################################################################


      # Returns JSON schemas for all action methods.
      #
      # Looks for JSON templates corresponding to each action method name
      # and parses them into schema hashes.
      #
      # @return [Array<Hash>] JSON schemas for available actions
      def action_schemas
        prefixes = set_prefixes(action_name, lookup_context.prefixes)

        action_methods.map do |action|
          render_schema(action, prefixes)
        end.compact
      end

      # Sets template prefixes for schema lookup.
      #
      # @param action [String] Current action name (unused but kept for signature)
      # @param prefixes [Array<String>] Existing lookup prefixes
      # @return [Array<String>] Updated prefixes including agent name
      def set_prefixes(action, prefixes)
        prefixes = lookup_context.prefixes | [ self.class.agent_name ]
      end

      # Renders JSON schema from template or returns it directly if already a Hash.
      #
      # @param schema_or_action [Hash, String] Direct schema or action name to find template
      # @param prefixes [Array<String>] Template lookup prefixes
      # @return [Hash, nil] Parsed JSON schema or nil if template not found
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
      # @param args [Hash] Response configuration (may include :body, :template_name, etc.)
      # @yield [collector] Optional collector for building custom responses
      # @return [Array<Hash>] Response hashes with :body and :content_type keys
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
      # @param args [Hash] May include :template_name (defaults to action_name)
      # @yield [collector] ActiveAgent::Collector instance for building responses
      # @return [Array<Hash>] Responses collected via the block
      def collect_responses_from_block(args)
        templates_name = args[:template_name] || action_name
        collector = ActiveAgent::Collector.new(lookup_context) { render(templates_name) }
        yield(collector)
        collector.responses
      end

      # Collects response from direct text provided in args.
      #
      # @param args [Hash] Must include :body, optional :content_type (defaults to "text/plain")
      # @return [Array<Hash>] Single-element array with response
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
      # @param args [Hash] May include :template_path, :template_name, :format
      # @return [Array<Hash>] Rendered template responses with detected content types
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
      # @param paths [Array<String>] Template lookup paths
      # @param name [String] Template name to find
      # @yield [template] Each unique template found
      # @raise [ActionView::MissingTemplate] If no templates match
      def each_template(paths, name, &)
        templates = lookup_context.find_all(name, paths)
        if templates.empty?
          raise ActionView::MissingTemplate.new(paths, name, paths, false, "agent")
        else
          templates.uniq(&:format).each(&)
        end
      end

      # Creates message parts from responses and adds them to context.
      #
      # @param context [Object] Context object that receives parts via add_part
      # @param responses [Array<Hash>] Response data with :body and :content_type
      def create_parts_from_responses(context, responses)
        if responses.size > 1
          responses.each { |r| insert_part(context, r, context.charset) }
        else
          responses.each { |r| insert_part(context, r, context.charset) }
        end
      end

      # Creates and inserts a single message part into the context.
      #
      # @param context [Object] Context object that receives part via add_part
      # @param response [Hash] Response with :body and :content_type keys
      # @param charset [String] Character encoding for the message
      def insert_part(context, response, charset)
        message = ActiveAgent::ActionPrompt::Message.new(
          content: response[:body],
          content_type: response[:content_type],
          charset: charset
        )
        context.add_part(message)
      end
    end
  end
end
