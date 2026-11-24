Rails.application.routes.draw do
  mount ActionAgent::Engine => "/activeagents"
  root "issues#index"

  resources :issues do
    resources :comments, only: :create
  end
  resource :session, only: :update
  resource :assistant_messages, only: %i[create destroy]

  get "up" => "rails/health#show", as: :rails_health_check
end
