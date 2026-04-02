# frozen_string_literal: true

ActiveAgent::Dashboard::Engine.routes.draw do
  # Dashboard root
  root to: "dashboard#index"

  # Dashboard
  get "dashboard", to: "dashboard#index"

  # Traces
  resources :traces, only: [ :index, :show ] do
    collection do
      get :metrics
    end
  end

  # Agents
  resources :agents do
    member do
      post :execute
      post :test
      get :versions
      post :restore_version
    end
    resources :runs, controller: "agent_runs", only: [ :index, :show ] do
      member do
        post :cancel
      end
    end
  end

  # Agent Templates
  resources :templates, only: [ :index, :show ] do
    member do
      post :create_agent
    end
  end

  # Sandbox Sessions
  resources :sandboxes, controller: "sandbox_sessions" do
    member do
      post :provision
      post :execute
      post :expire
    end
    resources :runs, controller: "sandbox_runs", only: [ :index, :show ]
  end

  # Session Recordings
  resources :recordings, controller: "session_recordings", only: [ :index, :show ] do
    member do
      get :timeline
      get :playback
    end
  end

  # API namespace
  namespace :api do
    namespace :v1 do
      # Telemetry ingestion
      resources :traces, only: [ :create ]

      # Agent execution API
      resources :agents, only: [ :index, :show ] do
        member do
          post :execute
        end
      end

      # Sandbox API
      resources :sandboxes, only: [ :create, :show ] do
        member do
          post :execute
        end
      end
    end
  end
end
