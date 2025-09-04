# frozen_string_literal: true

module SolidAgent
  # Actionable provides multiple ways to define agent actions:
  # 1. Public methods (traditional ActiveAgent way)
  # 2. Concerns with action definitions
  # 3. External tools via MCP servers
  # 4. Dynamic tool registration
  #
  # All actions are automatically tracked by SolidAgent
  #
  # Example:
  #   class ResearchAgent < ApplicationAgent
  #     include SolidAgent::Actionable
  #     
  #     # Method 1: Public methods become actions automatically
  #     def search_papers(query:, limit: 10)
  #       # This is automatically an action
  #     end
  #     
  #     # Method 2: Include concerns with actions
  #     include WebSearchActions
  #     include GraphRetrievalActions
  #     
  #     # Method 3: Connect MCP servers
  #     mcp_server "filesystem", url: "npx @modelcontextprotocol/server-filesystem"
  #     mcp_server "github", url: "npx @modelcontextprotocol/server-github"
  #     
  #     # Method 4: Define actions explicitly
  #     action :analyze_code do
  #       description "Analyzes code quality and suggests improvements"
  #       parameter :file_path, type: :string, required: true
  #       parameter :language, type: :string, enum: ["ruby", "python", "js"]
  #       
  #       execute do |params|
  #         # Implementation
  #       end
  #     end
  #     
  #     # Method 5: Register external tools
  #     tool "browser" do
  #       provider BrowserAutomation
  #       actions [:navigate, :click, :type, :screenshot]
  #     end
  #   end
  #
  module Actionable
    extend ActiveSupport::Concern

    included do
      class_attribute :registered_actions, default: {}
      class_attribute :mcp_servers, default: {}
      class_attribute :external_tools, default: {}
      class_attribute :action_concerns, default: []
      
      # Track all action executions
      around_action :track_action_execution
    end

    class_methods do
      # Define an action explicitly
      def action(name, &block)
        action_def = ActionDefinition.new(name)
        action_def.instance_eval(&block) if block_given?
        
        registered_actions[name] = action_def
        
        # Create the method if it has an execute block
        if action_def.executor
          define_method(name) do |**params|
            execute_action(name, params)
          end
        end
        
        # Make it available as a tool
        expose_as_tool(action_def)
      end

      # Connect an MCP server
      def mcp_server(name, url: nil, config: {})
        mcp_servers[name] = {
          url: url,
          config: config,
          connected: false,
          tools: []
        }
        
        # Connect and discover tools on first use
        after_initialize do
          connect_mcp_server(name)
        end
      end

      # Register an external tool provider
      def tool(name, &block)
        tool_config = ToolConfiguration.new(name)
        tool_config.instance_eval(&block) if block_given?
        
        external_tools[name] = tool_config
        
        # Register tool actions
        register_tool_actions(tool_config)
      end

      # Include a concern with actions
      def include_actions(*concerns)
        concerns.each do |concern|
          include concern
          action_concerns << concern
          
          # Discover actions from the concern
          discover_concern_actions(concern)
        end
      end

      # Get all available actions (for tool schemas)
      def all_actions
        actions = {}
        
        # Public methods (traditional ActiveAgent)
        action_methods.each do |method_name|
          actions[method_name] = ActionDefinition.from_method(self, method_name)
        end
        
        # Explicitly defined actions
        actions.merge!(registered_actions)
        
        # MCP server tools
        mcp_servers.each do |server_name, config|
          config[:tools].each do |tool|
            actions[tool[:name]] = ActionDefinition.from_mcp_tool(server_name, tool)
          end
        end
        
        # External tools
        external_tools.each do |tool_name, config|
          config.actions.each do |action_name|
            full_name = "#{tool_name}_#{action_name}"
            actions[full_name] = ActionDefinition.from_external_tool(tool_name, action_name, config)
          end
        end
        
        actions
      end

      private

      def expose_as_tool(action_def)
        # Generate JSON schema for the action
        schema = action_def.to_tool_schema
        
        # Register with ActiveAgent's tool system
        # This makes it available to the AI
        register_tool(action_def.name, schema)
      end

      def discover_concern_actions(concern)
        # Find all public methods defined by the concern
        concern_methods = concern.instance_methods(false)
        
        concern_methods.each do |method_name|
          # Skip if already registered
          next if registered_actions[method_name]
          
          # Check if method has action metadata
          if concern.respond_to?(:action_metadata) && concern.action_metadata[method_name]
            metadata = concern.action_metadata[method_name]
            action_def = ActionDefinition.new(method_name, metadata)
            registered_actions[method_name] = action_def
            expose_as_tool(action_def)
          end
        end
      end

      def register_tool_actions(tool_config)
        tool_config.actions.each do |action_name|
          full_name = "#{tool_config.name}_#{action_name}"
          
          # Create wrapper method
          define_method full_name do |**params|
            execute_external_tool(tool_config.name, action_name, params)
          end
        end
      end
    end

    # Instance methods for action execution
    def execute_action(name, params)
      action_def = self.class.registered_actions[name]
      return super unless action_def
      
      # Validate parameters
      validate_action_params(action_def, params)
      
      # Track execution
      track_action(name, params) do
        if action_def.executor
          instance_exec(params, &action_def.executor)
        else
          super
        end
      end
    end

    def execute_mcp_tool(server_name, tool_name, params)
      server = self.class.mcp_servers[server_name]
      raise "MCP server #{server_name} not found" unless server
      
      track_action("mcp_#{server_name}_#{tool_name}", params) do
        MCPClient.execute(
          server: server,
          tool: tool_name,
          parameters: params
        )
      end
    end

    def execute_external_tool(tool_name, action_name, params)
      tool_config = self.class.external_tools[tool_name]
      raise "Tool #{tool_name} not found" unless tool_config
      
      track_action("#{tool_name}_#{action_name}", params) do
        tool_config.provider.execute(action_name, params)
      end
    end

    private

    def track_action_execution
      return yield unless @_solid_prompt_context
      
      # Create action execution record
      @_current_action = Models::ActionExecution.create!(
        message: @_solid_prompt_context.messages.last,
        prompt_generation_cycle: @_current_cycle,
        action_type: detect_action_type,
        action_name: action_name.to_s,
        parameters: params.to_unsafe_h,
        status: "executing"
      )
      
      result = yield
      
      # Mark as complete
      @_current_action.complete!(
        result_data: serialize_result(result)
      )
      
      result
    rescue => e
      @_current_action&.fail!(e.message, e.class.name => e.backtrace.first(5))
      raise
    end

    def track_action(name, params)
      return yield unless SolidAgent.configuration.auto_persist
      
      action_record = Models::ActionExecution.create!(
        action_name: name.to_s,
        action_type: detect_action_type_for(name),
        parameters: params,
        status: "executing",
        executed_at: Time.current
      )
      
      result = yield
      
      action_record.complete!(result_data: result)
      result
    rescue => e
      action_record&.fail!(e.message)
      raise
    end

    def detect_action_type
      case action_name.to_s
      when /^mcp_/
        "mcp_tool"
      when /search/
        "web_search"
      when /browse|navigate/
        "web_browse"
      when /graph|retrieve/
        "graph_retrieval"
      when /computer|screen/
        "computer_use"
      else
        "tool"
      end
    end

    def detect_action_type_for(name)
      name = name.to_s
      
      if name.start_with?("mcp_")
        "mcp_tool"
      elsif self.class.external_tools.any? { |tool_name, _| name.start_with?("#{tool_name}_") }
        "tool"
      else
        "function"
      end
    end

    def validate_action_params(action_def, params)
      action_def.parameters.each do |param_name, param_def|
        if param_def[:required] && !params.key?(param_name)
          raise ArgumentError, "Required parameter #{param_name} missing"
        end
        
        if param_def[:type] && params[param_name]
          validate_param_type(param_name, params[param_name], param_def[:type])
        end
        
        if param_def[:enum] && params[param_name]
          unless param_def[:enum].include?(params[param_name])
            raise ArgumentError, "#{param_name} must be one of: #{param_def[:enum].join(', ')}"
          end
        end
      end
    end

    def validate_param_type(name, value, type)
      valid = case type
      when :string then value.is_a?(String)
      when :integer then value.is_a?(Integer)
      when :float then value.is_a?(Numeric)
      when :boolean then [true, false].include?(value)
      when :array then value.is_a?(Array)
      when :object, :hash then value.is_a?(Hash)
      else true
      end
      
      raise ArgumentError, "#{name} must be of type #{type}" unless valid
    end

    def serialize_result(result)
      case result
      when String, Numeric, TrueClass, FalseClass, NilClass
        { value: result }
      when Array, Hash
        { value: result }
      else
        { value: result.to_s, class: result.class.name }
      end
    end

    def connect_mcp_server(name)
      config = self.class.mcp_servers[name]
      return if config[:connected]
      
      # Connect to MCP server and discover tools
      client = MCPClient.connect(config[:url], config[:config])
      tools = client.list_tools
      
      config[:tools] = tools
      config[:connected] = true
      config[:client] = client
      
      # Register discovered tools
      tools.each do |tool|
        register_mcp_tool(name, tool)
      end
    rescue => e
      Rails.logger.error "Failed to connect to MCP server #{name}: #{e.message}"
    end

    def register_mcp_tool(server_name, tool)
      full_name = "mcp_#{server_name}_#{tool[:name]}"
      
      # Create method for the tool
      self.class.define_method full_name do |**params|
        execute_mcp_tool(server_name, tool[:name], params)
      end
    end

    # Action definition DSL
    class ActionDefinition
      attr_reader :name, :description, :parameters, :executor

      def initialize(name, metadata = {})
        @name = name
        @description = metadata[:description]
        @parameters = {}
        @executor = nil
      end

      def description(text)
        @description = text
      end

      def parameter(name, type: :string, required: false, description: nil, enum: nil, default: nil)
        @parameters[name] = {
          type: type,
          required: required,
          description: description,
          enum: enum,
          default: default
        }.compact
      end

      def execute(&block)
        @executor = block
      end

      def to_tool_schema
        {
          type: "function",
          function: {
            name: name.to_s,
            description: description,
            parameters: {
              type: "object",
              properties: parameters.transform_values do |param|
                schema = { type: param[:type].to_s }
                schema[:description] = param[:description] if param[:description]
                schema[:enum] = param[:enum] if param[:enum]
                schema[:default] = param[:default] if param[:default]
                schema
              end,
              required: parameters.select { |_, p| p[:required] }.keys.map(&:to_s)
            }
          }
        }
      end

      class << self
        def from_method(klass, method_name)
          new(method_name).tap do |action|
            action.description "Executes #{method_name}"
            
            # Try to extract parameters from method signature
            if klass.instance_method(method_name).parameters.any?
              klass.instance_method(method_name).parameters.each do |type, name|
                next if name == :block
                action.parameter(name, required: type == :req || type == :keyreq)
              end
            end
          end
        end

        def from_mcp_tool(server_name, tool)
          new("mcp_#{server_name}_#{tool[:name]}").tap do |action|
            action.description tool[:description]
            
            tool[:parameters]&.each do |param_name, param_schema|
              action.parameter(
                param_name,
                type: param_schema[:type]&.to_sym || :string,
                required: tool[:required]&.include?(param_name),
                description: param_schema[:description]
              )
            end
          end
        end

        def from_external_tool(tool_name, action_name, config)
          new("#{tool_name}_#{action_name}").tap do |action|
            action.description "#{action_name} via #{tool_name}"
          end
        end
      end
    end

    # Tool configuration DSL
    class ToolConfiguration
      attr_reader :name, :provider, :actions

      def initialize(name)
        @name = name
        @actions = []
      end

      def provider(klass)
        @provider = klass
      end

      def actions(list)
        @actions = list
      end
    end
  end
end