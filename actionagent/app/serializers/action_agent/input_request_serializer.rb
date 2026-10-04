# frozen_string_literal: true

module ActionAgent
  # The JSON shape of an InputRequest, shared by the JSON API and the MCP
  # facade. It never includes the request's answer or checkpoint.
  #
  # `actor` is the person the paused run executes on behalf of, and
  # `arguments` the paused call's arguments, for a `confirm` request only.
  module InputRequestSerializer
    module_function

    # @param request [InputRequest]
    # @return [Hash]
    def call(request)
      run = request.subject
      agent = run.try(:agent)

      {
        id: request.id,
        kind: request.kind,
        status: request.status,
        prompt: request.prompt,
        options: request.options,
        answer_schema: request.answer_schema,
        tool_name: request.tool_name,
        tool_call_id: request.tool_call_id,
        arguments: request.kind == "confirm" ? request.arguments : nil,
        agent: agent && { id: agent.id, name: agent.name, slug: agent.slug },
        run_id: run.is_a?(AgentRun) ? run.id : nil,
        actor: actor_json(run.try(:actor)),
        created_at: request.created_at,
        expires_at: request.expires_at,
        answered_at: request.answered_at
      }
    end

    def actor_json(actor)
      return nil if actor.nil?

      {
        type: actor.class.name,
        id: actor.try(:id),
        name: actor.try(:name).presence || actor.try(:email).presence
      }
    end
  end
end
