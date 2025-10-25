# frozen_string_literal: true

module ActiveAgent
  # Provides template lookup and rendering for agent classes.
  #
  # Enables agents to render instructions, schemas, and messages from
  # ERB templates with flexible directory structures and fallback paths.
  module View
    extend ActiveSupport::Concern

    included do
      include ActionView::Layouts
    end

    # Builds template lookup paths supporting both flat and nested directory structures.
    #
    # Templates are searched in priority order:
    # - `app/views/{agent_name}/` (e.g., `app/views/support_agent/`)
    # - `app/views/agents/{agent_without_suffix}/` (e.g., `app/views/agents/support/`)
    #
    # With action_name present:
    # - `app/views/agents/{agent_without_suffix}/{action_name}/`
    # - `app/views/{agent_name}/{action_name}/`
    # - `app/views/{agent_name}/`
    # - `app/views/agents/{agent_without_suffix}/`
    #
    # @return [Array<String>] ordered prefixes for template lookup
    def _prefixes
      @_prefixes ||= begin
        # Get the base agent name (e.g., "statements_agent" or "view_test/test_agent")
        base = agent_name

        # Build the nested structure under agents/
        # e.g., "agents/statements" for StatementsAgent
        nested = "agents/#{base.delete_suffix("_agent")}"

        # Build prefixes with action_name if present
        if action_name.present?
          # Priority order: nested/action, base/action, base, nested
          [  "#{nested}/#{action_name}", "#{base}/#{action_name}", base, nested ]
        else
          # Priority order: base, nested
          [ nested, base ]
        end
      end
    end

    ##### Instructions Templating ###########################################

    # Prepares instructions from various input formats.
    #
    # Supported formats:
    # - `String`: returned as-is
    # - `Symbol`: invokes method with that name (like ActiveRecord callbacks)
    # - `Array<String>`: returned as-is if all elements are strings
    # - `Hash`: requires `:template` key, optional `:locals`
    # - `nil` or `true`: renders default "instructions" template
    #
    # @param value [Hash, String, Symbol, Array<String>, Boolean, nil]
    # @return [String, Array<String>, nil] nil if template not found
    # @raise [ArgumentError] if format is invalid or Hash missing :template key
    def prompt_view_instructions(value)
      case value
      when String
        value.presence

      when Symbol
        send(value)

      when Array
        raise ArgumentError, "Instructions array must contain only strings" unless value.all?(String)
        value.presence

      when Hash
        raise ArgumentError, "Expected `:template` key in instructions hash" unless value[:template]
        view_render_template(value[:template], **value[:locals])

      when nil, true
        view_render_template("instructions", strict: value == true, **params.dig(:instructions, :locals))

      else
        raise ArgumentError, "Instructions must be Hash, String, Symbol or nil"
      end
    end

    ##### Action Templating #################################################

    # Renders template for a prompt action or message.
    #
    # @param action_name [String, Symbol]
    # @param locals [Hash]
    # @return [String, nil]
    def prompt_view_message(action_name, **locals)
      view_render_template(action_name, **locals)
    end

    # Renders JSON schema from template or returns Hash directly.
    #
    # @param value [Hash, String, Symbol, Boolean, nil]
    # @return [Hash, String, nil]
    def prompt_view_schema(value)
      case value
      when Hash
        value
      when String, Symbol
        JSON.parse(view_render_template(value, strict: true), symbolize_names: true)
      when true, nil
        JSON.parse(view_render_template("schema", strict: true), symbolize_names: true)
      end
    end

    # Renders template for embedding input.
    #
    # @param action_name [String, Symbol]
    # @param locals [Hash]
    # @return [String, nil]
    def embed_view_input(action_name, **locals)
      view_render_template(action_name, **locals)
    end

    private

    ##### Shared Helpers ####################################################

    # Renders a template if it exists in any supported ERB format.
    #
    # Templates are looked up using the prefixes defined in `_prefixes`:
    # 1. `app/views/{agent_name}/` (e.g., `app/views/statements_agent/`)
    # 2. `app/views/agents/{agent_without_suffix}/` (e.g., `app/views/agents/statements/`)
    #
    # @param template_name [String, Symbol] template file name without extension
    # @param strict [Boolean] if true, raises error when template not found
    # @param locals [Hash] local variables passed to template
    # @return [String, nil] nil if template not found and not strict
    def view_render_template(template_name, strict: false, **locals)
      return if !strict && !lookup_context.exists?(template_name, _prefixes, false)

      template = lookup_context.find_template(template_name, _prefixes, false)

      render_to_string(template: template.virtual_path, locals:, layout: false).chomp.presence
    end
  end
end
