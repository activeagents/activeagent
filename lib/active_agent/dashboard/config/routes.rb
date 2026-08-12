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

  # Telemetry ingestion, relative to wherever the engine is mounted:
  # <mount>/api/traces (e.g. /activeagents/api/traces at the default mount).
  namespace :api do
    resources :traces, only: [ :create ]
  end
end
