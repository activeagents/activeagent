# frozen_string_literal: true

ActiveAgent::Dashboard::Engine.routes.draw do
  # The functional dashboard surface: traces + metrics.
  root to: "traces#index"
  get "dashboard", to: "dashboard#index"

  resources :traces, only: [ :index, :show ] do
    collection do
      get :metrics
    end
  end

  # Telemetry ingestion — matches
  # ActiveAgent::Telemetry::Configuration::LOCAL_ENDPOINT_PATH
  # (/active_agent/api/traces when mounted at the default /active_agent).
  namespace :api do
    resources :traces, only: [ :create ]
  end
end
