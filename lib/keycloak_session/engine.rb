# frozen_string_literal: true

require "rails/engine"

module KeycloakSession
  class Engine < ::Rails::Engine
    isolate_namespace KeycloakSession

    initializer "keycloak_session.omniauth" do |app|
      # The block runs when the stack is built, after the app's own initializers have configured us.
      app.middleware.use OmniAuth::Builder do
        config = KeycloakSession.config
        next unless config.enabled

        issuer = URI(config.issuer)
        provider :openid_connect,
          name: KeycloakSession::PROVIDER,
          issuer: config.issuer,
          discovery: true,
          pkce: true,
          scope: config.scopes.map(&:to_sym),
          client_options: {
            scheme: issuer.scheme,
            host: issuer.host,
            port: issuer.port,
            identifier: config.client_id,
            secret: config.client_secret,
            redirect_uri: config.redirect_uri
          }
      end
    end

    config.after_initialize do
      KeycloakSession.config.validate!
      next unless KeycloakSession.config.enabled

      OmniAuth.config.logger = KeycloakSession.config.logger
      # Development would raise instead of landing on our failure action.
      OmniAuth.config.on_failure = proc { |env| OmniAuth::FailureEndpoint.new(env).redirect_to_failure }
    end
  end
end
