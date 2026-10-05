# frozen_string_literal: true

# Mount at /auth: OmniAuth serves POST /auth/keycloak and redirects failures to /auth/failure.
KeycloakSession::Engine.routes.draw do
  get "keycloak/callback", to: "sessions#callback"
  get "failure", to: "sessions#failure"
  post "logout", to: "sessions#logout"
  post "backchannel-logout", to: "sessions#backchannel_logout"
end
