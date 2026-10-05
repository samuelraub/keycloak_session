# frozen_string_literal: true

module KeycloakSession
  # Include in ApplicationController, then `before_action :require_login`.
  # Apps with a second login override `current_user` and fall back to `keycloak_user`.
  module Authentication
    extend ActiveSupport::Concern

    included do
      helper_method :current_user if respond_to?(:helper_method)
    end

    def current_user
      keycloak_user
    end

    def keycloak_user
      return @keycloak_user if defined?(@keycloak_user)

      @keycloak_user = keycloak_token_set&.user
    end

    def require_login
      request_login unless current_user
    end

    def request_login
      redirect_to KeycloakSession.config.login_path
    end

    private

    def keycloak_token_set
      id = session[KeycloakSession::SESSION_KEY] or return
      token_set = KeycloakSession::TokenSet.find_by(id: id)
      return token_set if token_set && (token_set.access_token_valid? || token_set.refresh)

      session.delete(KeycloakSession::SESSION_KEY)
      nil
    rescue KeycloakSession::Unavailable, KeycloakSession::TokenSet::Unreadable
      # Nobody is signed in for this request, but the session survives an outage or a wrong key.
      nil
    end
  end
end
