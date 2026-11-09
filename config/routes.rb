Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Same REST endpoints as the original Node.js app:
  #   GET /api/tasks, POST /api/tasks, PUT /api/tasks/:id, DELETE /api/tasks/:id
  # The task manager page is served from public/index.html at "/".
  namespace :api do
    resources :tasks, only: %i[index create update destroy]
  end
end
