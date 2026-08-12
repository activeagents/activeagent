# frozen_string_literal: true

ActiveAgent::Dashboard::Engine.routes.draw do
  # The React dashboard. Every path below it is routed client-side, so the
  # controller renders the same page for all of them and the browser's back
  # button keeps working.
  root to: "dashboard#index"
  get "dashboard", to: "dashboard#index"
  get "dashboard/*path", to: "dashboard#index"

  # The server-rendered traces surface. Older installs linked straight to it,
  # and it stays useful where the JS bundle can't run.
  resources :traces, only: [ :index, :show ], controller: "traces" do
    collection do
      get :metrics
    end
  end

  # The dashboard's own JSON API, read and written by the React app.
  namespace :api do
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
    # real ones (see ActiveAgent::Dashboard.sandbox_backends).
    resources :sandboxes, param: :id, only: [ :index, :create, :show, :destroy ] do
      collection do
        post :compare
      end
      member do
        post :run
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
        get :demo
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
    resources :interactions, only: [ :index, :show ]

    # Agent output evaluations.
    resources :evaluations, only: [ :index, :show, :create, :destroy ] do
      member do
        post :run
      end
    end

    # Credentials: dashboard API keys (token shown once on create) and the
    # owner's own LLM provider credentials, both encrypted at rest.
    resources :api_keys, only: [ :index, :create, :destroy ]
    resources :provider_keys, only: [ :index, :create, :destroy ], param: :provider

    # Model catalogs for the agent builder (Ollama queried live from the
    # configured host; hosted providers curated).
    resources :provider_models, only: [ :index ]
  end

  # The account's agents presented as an authenticated MCP server (tools +
  # agent:// resources) over Streamable HTTP JSON-RPC. Authenticated with a
  # dashboard API key rather than a session, so it sits outside the api
  # namespace's session-authenticated controllers.
  post "mcp", to: "api/mcp#create"
end
