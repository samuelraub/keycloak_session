# frozen_string_literal: true

require "faraday"
require "jwt"
require "omniauth"
require "omniauth_openid_connect"
require "omniauth/rails_csrf_protection"

require "keycloak_session/version"
require "keycloak_session/configuration"
require "keycloak_session/return_path"
require "keycloak_session/client"
require "keycloak_session/verifier"
require "keycloak_session/engine"

module KeycloakSession
  PROVIDER = :keycloak
  SESSION_KEY = "keycloak_session_token_set_id"

  # Keycloak could not be asked. Says nothing about the token in question.
  class Unavailable < StandardError; end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end
  end
end
