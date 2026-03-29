# frozen_string_literal: true

ActiveAgent::Dashboard::Engine.routes.draw do
  # Dashboard routes
  root to: "traces#index"

  resources :traces, only: [:index, :show] do
    collection do
      get :metrics
    end
  end

  # API routes for local telemetry ingestion
  namespace :api do
    resources :traces, only: [:create]
  end
end
