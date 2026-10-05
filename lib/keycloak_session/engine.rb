# frozen_string_literal: true

require "rails/engine"

module KeycloakSession
  class Engine < ::Rails::Engine
    isolate_namespace KeycloakSession

    initializer "keycloak_session.omniauth" do |app|
      # The block runs when the stack is built, after the app's own initializers have configured us.
      app.middleware.use OmniAuth::Builder do
        config = KeycloakSession.config
        config.validate!
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
      next unless KeycloakSession.config.enabled

      OmniAuth.config.logger = KeycloakSession.config.logger
      # Development would raise instead of landing on our failure action. Other providers keep
      # the handler the app gave them.
      host_failure = OmniAuth.config.on_failure
      OmniAuth.config.on_failure = proc do |env|
        ours = env["omniauth.error.strategy"]&.name.to_s == KeycloakSession::PROVIDER.to_s
        ours ? OmniAuth::FailureEndpoint.new(env).redirect_to_failure : host_failure.call(env)
      end
    end
  end
end
