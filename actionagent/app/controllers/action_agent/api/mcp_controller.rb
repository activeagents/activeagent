# frozen_string_literal: true

module ActionAgent
  module Api
    # Exposes the dashboard's agents as an authenticated MCP (Model Context
    # Protocol) service over Streamable HTTP JSON-RPC — agents present
    # themselves as Resource Agents backed by their ActiveRecord state:
    #
    # - tools/list & tools/call: each agent is a callable tool (run_<slug>)
    #   that executes a synchronous generation run.
    # - resources/list & resources/read: each agent is an agent://<slug>
    #   resource whose content is its live scorecard (config + stats + memory
    #   summary from the solid_agent datasets).
    #
    # Authentication/authorization: Bearer <api key> (Settings -> API Keys).
    # The key scopes everything to its account — its members' agents and its
    # run quotas.
    #
    # Connect from an MCP client with:
    #   { "type": "http", "url": "https://activeagents.ai/mcp",
    #     "headers": { "Authorization": "Bearer aa_..." } }
    class MCPController < BaseController
      # Authenticated by API key rather than by the host app's sessions.
      allow_unauthenticated_access
      before_action :authenticate_api_key!, except: [ :unsupported ]

      PROTOCOL_VERSION = "2025-03-26"
      JSONRPC_METHOD_NOT_FOUND = -32601
      JSONRPC_INVALID_PARAMS = -32602
      JSONRPC_SERVER_ERROR = -32000
      # No JSON-RPC code means "forbidden", and the MCP spec leaves -32000..
      # -32099 to the server. A refusal gets its own so a client can tell it
      # from a run that merely failed.
      JSONRPC_FORBIDDEN = -32003

      # POST /mcp
      def create
        request_id = params[:id]

        # JSON-RPC notifications get no response body.
        return head :accepted if request_id.nil? && params[:method].to_s.start_with?("notifications/")

        result = case params[:method]
        when "initialize" then initialize_result
        when "ping" then {}
        when "tools/list" then tools_list
        when "tools/call" then tools_call
        when "resources/list" then resources_list
        when "resources/read" then resources_read
        else
          return render_error(request_id, JSONRPC_METHOD_NOT_FOUND, "Method not found: #{params[:method]}")
        end

        render json: { jsonrpc: "2.0", id: request_id, result: result }
      rescue McpError => e
        render_error(request_id, e.code, e.message)
      rescue StandardError => e
        Rails.logger.error("[Api::MCPController] #{e.class}: #{e.message}")
        render_error(request_id, JSONRPC_SERVER_ERROR, "Internal error")
      end

      # GET (open an SSE stream) and DELETE (end a session) on the endpoint.
      # Neither is offered: per Streamable HTTP a server that does not
      # provide a stream MUST answer GET with 405, and an unsupported
      # session DELETE likewise. Unauthenticated on purpose — a client
      # probing for the stream should learn "not offered", not "sign in".
      def unsupported
        response.headers["Allow"] = "POST"
        head :method_not_allowed
      end

      private

      # JSON-RPC errors ride on HTTP 200 per the MCP Streamable HTTP transport.
      def render_error(id, code, message)
        render json: { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
      end

      class McpError < StandardError
        attr_reader :code

        def initialize(message, code = JSONRPC_SERVER_ERROR)
          super(message)
          @code = code
        end
      end

      def authenticate_api_key!
        token = request.headers["Authorization"].to_s[/\ABearer\s+(.+)\z/i, 1]
        api_key = ApiKey.authenticate(token)

        if api_key.nil?
          render json: { error: "Unauthorized: pass a dashboard API key as a Bearer token" }, status: :unauthorized
          return
        end

        api_key.touch_last_used!
        @api_key = api_key
        @owner = api_key.owner
      end

      # The agents this key can reach. A key belongs to whoever owns it, and
      # a single-user install has no owner, so the key reaches every agent
      # the dashboard holds.
      def key_agents
        ActionAgent.agents_for(@owner).where.not(status: :archived).order(:slug)
      end

      # The caller an MCP-invoked run executes on behalf of.
      #
      # The key's owner is the identity that authenticated this request, so
      # it is the default; a host issuing keys per end user overrides it
      # with ActionAgent.agent_actor_resolver, which is handed this
      # controller and can read the request however it likes.
      #
      # The agent's own callbacks decide what the actor may do — that is the
      # point of carrying one. This only answers *who*.
      def agent_actor
        return @agent_actor if defined?(@agent_actor)

        @agent_actor =
          if (resolver = ActionAgent.agent_actor_resolver)
            resolver.arity.zero? ? resolver.call : resolver.call(self)
          else
            @api_key.respond_to?(:user) && @api_key.user ? @api_key.user : @owner
          end
      end

      # Whether the run ended because the agent refused this caller, rather
      # than because something broke. Matched on the error class the
      # framework raises (and the ones a host names with `denies_with`), not
      # on the message.
      def run_refused?(run)
        klass = run.output_metadata.is_a?(Hash) ? run.output_metadata["error_class"] : nil
        return false if klass.blank?

        klass.to_s == "ActiveAgent::NotAuthorized" ||
          ActiveAgent::Base.authorization_errors.any? { |error| error.name == klass.to_s }
      end

      def initialize_result
        {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {}, resources: {} },
          serverInfo: { name: "activeagents", version: "1.0" },
          instructions: "Each tool runs one of this account's agents. Each agent://<slug> resource returns the agent's live scorecard."
        }
      end

      MESSAGE_INPUT_SCHEMA = {
        type: "object",
        properties: {
          message: { type: "string", description: "The prompt/message for the agent" }
        },
        required: [ "message" ]
      }.freeze

      def tools_list
        tools = key_agents.flat_map do |agent|
          agent_tools = [ {
            name: "run_#{agent.slug}",
            description: agent.description.presence || "Run the #{agent.name} agent",
            inputSchema: MESSAGE_INPUT_SCHEMA
          } ]
          # Named actions marked expose_as_tool are individually callable —
          # the activeagent "actions as tools" pattern over MCP.
          Array(agent.action_prompts).select { |ap| ap["expose_as_tool"] }.each do |action|
            agent_tools << {
              name: "run_#{agent.slug}__#{action['name']}",
              description: "Run the #{agent.name} agent's #{action['name']} action",
              inputSchema: MESSAGE_INPUT_SCHEMA
            }
          end
          agent_tools
        end

        { tools: tools }
      end

      def tools_call
        name = params.dig(:params, :name).to_s
        slug, action = name.delete_prefix("run_").split("__", 2)
        agent = key_agents.find_by(slug: slug)
        raise McpError.new("Unknown tool: #{name}", JSONRPC_INVALID_PARAMS) unless agent
        if action.present? && agent.action_prompt_for(action)&.dig("expose_as_tool") != true
          raise McpError.new("Unknown tool: #{name}", JSONRPC_INVALID_PARAMS)
        end

        message = params.dig(:params, :arguments, :message).to_s
        raise McpError.new("Missing required argument: message", JSONRPC_INVALID_PARAMS) if message.blank?

        unless ActionAgent.execution_enabled?
          raise McpError.new("Agent execution is disabled on this dashboard")
        end
        if (denial = ActionAgent.quota_denial(@owner, :execution)).present?
          raise McpError.new(denial.is_a?(Hash) ? denial[:message] || denial["message"] : denial)
        end

        run = agent.test_execute(message, action: action, actor: agent_actor)
        ActionAgent.record_usage(@owner, :execution)

        if run.failed?
          # A refusal is not a result. An agent that declined on this
          # caller's behalf answers as a JSON-RPC error, so the client sees
          # "not allowed" rather than an empty, confident answer — the
          # failure mode a nil-actor scope produces on its own.
          raise McpError.new(run.error_message.to_s, JSONRPC_FORBIDDEN) if run_refused?(run)

          { content: [ { type: "text", text: "Agent run failed: #{run.error_message}" } ], isError: true }
        else
          {
            content: [ { type: "text", text: run.output.to_s } ],
            structuredContent: {
              run_id: run.id,
              trace_id: run.trace_id,
              duration_ms: run.duration_ms,
              total_tokens: run.total_tokens,
              metadata: run.output_metadata
            }
          }
        end
      end

      def resources_list
        {
          resources: key_agents.map do |agent|
            {
              uri: "agent://#{agent.slug}",
              name: agent.name,
              description: agent.description.presence || "#{agent.name} scorecard",
              mimeType: "application/json"
            }
          end
        }
      end

      def resources_read
        uri = params.dig(:params, :uri).to_s
        slug = uri.delete_prefix("agent://")
        agent = key_agents.find_by(slug: slug)
        raise McpError.new("Unknown resource: #{uri}", JSONRPC_INVALID_PARAMS) unless agent

        {
          contents: [ {
            uri: uri,
            mimeType: "application/json",
            text: agent_resource(agent).to_json
          } ]
        }
      end

      # The Resource Agent card: configuration plus live scorecard stats and
      # the agent's memory summary (solid_agent datasets).
      def agent_resource(agent)
        {
          name: agent.name,
          slug: agent.slug,
          description: agent.description,
          provider: agent.provider,
          model: agent.model,
          status: agent.status,
          tools: agent.tools,
          instructions: agent.instructions,
          stats: AgentScorecard.for_agents([ agent ])[agent.id],
          memory: agent.memory.summary_list.last(20)
        }
      end
    end
  end
end
