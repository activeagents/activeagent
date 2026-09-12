# frozen_string_literal: true

ActionAgent::Engine.routes.draw do
  # The React dashboard's entry point. Its own paths (/traces, /metrics,
  # /agents/1/edit, ...) are matched by the catch-all at the bottom of this
  # file, so deep links and the browser's back button both work wherever the
  # engine is mounted.
  root to: "dashboard#index"

  # The server-rendered console. Same data, no JavaScript — useful when the
  # bundle can't run, and the surface the dashboard shipped with before the
  # React app moved into the engine.
  scope :console do
    resources :traces, only: [ :index, :show ], controller: "traces" do
      collection do
        get :metrics
      end
    end
  end

  # The dashboard's own JSON API, read and written by the React app.
  namespace :api do
    resource :dashboard_assistant, only: [ :show, :create ], controller: "dashboard_assistant"

    # Telemetry ingestion, relative to wherever the engine is mounted:
    # <mount>/api/traces (e.g. /activeagents/api/traces at the default mount).
    # Authenticated with a bearer token, not a session.
    resources :traces, only: [ :create ]

    # A JSON API has no :new or :edit forms to serve.
    resources :agents, except: [ :new, :edit ] do
      member do
        get :versions
        post :restore
        get :runs
        post :execute
        post :test
        post :duplicate
        get :export
        get :analytics
        # The Tools tab's roster: offerable tools and MCP services, each
        # with what the window recorded for it.
        get :tool_roster
        # The runner's conversation picker: this agent's persisted contexts,
        # and a fresh one to pin a first message to.
        get :conversations
        post :conversations, action: :create_conversation
      end
      collection do
        get :presets
      end
    end

    resources :templates, only: [ :index, :show ] do
      member do
        post :use
      end
    end

    resources :runs, controller: "agent_runs", only: [ :index, :show ] do
      member do
        post :cancel
      end
    end

    # Sandboxes. The engine ships the in-memory backend; an operator registers
    # real ones (see ActionAgent.sandbox_backends).
    resources :sandboxes, param: :id, only: [ :index, :create, :show, :destroy ] do
      collection do
        post :compare
      end
      member do
        post :run
      end
    end

    # Tool inventory — auto-detected from the tool roster each generation
    # request offered, telemetry tool spans, and solid_agent records.
    resources :tools, only: [ :index ]

    # MCP services — detected servers unioned with the default catalog
    # (MCPCatalog), plus on-demand sandbox provisioning. Keys are catalog
    # slugs like "sequential-thinking", so the id segment allows dashes.
    resources :mcp_servers, only: [ :index, :show ], id: /[^\/]+/ do
      member do
        post :launch
      end
    end

    resources :instance_tiers, only: [ :index, :show ] do
      collection do
        get :recommend
        get :pricing
      end
    end

    resources :session_recordings, only: [ :index, :show, :destroy ] do
      member do
        get :actions
        get "snapshot/:action_id", action: :snapshot, as: :snapshot
        post :export
        post :handoff
        post :record_action
        post :complete, action: :complete_session
      end
      collection do
        get :recent
        post :start_user_session
      end
    end

    resource :analytics, only: [], controller: "analytics" do
      get "/", action: :index
    end

    # Reading traces is the same path as ingesting them, separated by verb:
    # POST is the SDK's authenticated-by-token ingest above, GET is the
    # dashboard's session-authenticated read.
    resources :traces, only: [ :index, :show ], controller: "trace_reports", as: :trace_reports
    resource :metrics, only: [ :show ], controller: "metrics"

    # Conversations (contexts, messages, generations) behind Interactions.
    # The runner edits a conversation in place — seeds, fixes or drops a
    # turn — so the next run sees exactly the history it should.
    resources :interactions, only: [ :index, :show ] do
      resources :messages, only: [ :create, :update, :destroy ], controller: "interaction_messages"
    end

    # Agent output evaluations. A scenario suite also manages its scenarios
    # here, and exposes each run's per-scenario, per-model results.
    resources :evaluations, only: [ :index, :show, :create, :destroy ] do
      member do
        post :run
        get "runs/:run_id", action: :show_run, as: :run_result
        get "runs/:run_id/report", action: :run_report, as: :run_report
        get :scenarios
        put :scenarios, action: :replace_scenarios
        patch "scenarios/:scenario_id", action: :update_scenario, as: :scenario
        delete "scenarios/:scenario_id", action: :destroy_scenario
      end
    end

    # Credentials: dashboard API keys (token shown once on create) and the
    # owner's own LLM provider credentials, both encrypted at rest.
    resources :api_keys, only: [ :index, :create, :destroy ]
    resources :provider_keys, only: [ :index, :create, :destroy ], param: :provider

    # Model catalogs for the agent builder (Ollama queried live from the
    # configured host; hosted providers curated).
    resources :provider_models, only: [ :index ]

    # The plan meter the Organization view and the Run Agents quota banner
    # read. The engine meters nothing itself: a host that tracks usage
    # against a plan answers through ActionAgent.usage_resolver, and a bare
    # mount reports unlimited rather than 404.
    resource :usage, only: [ :show ], controller: "usage"
  end

  # The account's agents presented as an authenticated MCP server (tools +
  # agent:// resources) over Streamable HTTP JSON-RPC. Authenticated with a
  # dashboard API key rather than a session, so it sits outside the api
  # namespace's session-authenticated controllers.
  post "mcp", to: "api/mcp#create"

  # MCP Streamable HTTP (2025-03-26): a client MAY open the server-to-client
  # SSE stream with GET, and ends a session with DELETE. This facade offers
  # no stream and keeps no sessions, so both answer 405 with Allow: POST —
  # the clean "not offered" signal SDK clients expect, instead of the
  # dashboard's HTML page parsed as an event stream. A browser's GET (Accept
  # prefers HTML) is the MCP Services view's deep link, and falls through to
  # the catch-all below like any other client-side route.
  match "mcp", to: "api/mcp#unsupported", via: [ :get, :delete ],
    constraints: ->(request) { request.delete? || !ActionAgent::Engine.html_request?(request) }

  # Everything else under the mount is a client-side route: render the
  # dashboard and let the browser resolve it. Anchored last so it can only
  # ever catch what the routes above did not, and refuses /api paths so a
  # mistyped endpoint answers as an API would rather than returning a page.
  get "*path", to: "dashboard#index", constraints: ->(request) { !request.path.include?("/api/") }
end
