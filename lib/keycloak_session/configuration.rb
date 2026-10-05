# frozen_string_literal: true

module KeycloakSession
  class Configuration
    REQUIRED = %i[issuer client_id client_secret redirect_uri resolve_user].freeze

    # The realm URL, e.g. https://kc.example.com/realms/main. Every endpoint is discovered from it.
    attr_accessor :issuer
    attr_accessor :client_id, :client_secret, :redirect_uri
    attr_writer :audience, :cache, :logger
    attr_accessor :scopes

    # False keeps the provider out of the middleware stack, for apps that also have another login.
    attr_accessor :enabled

    attr_accessor :user_class

    # Called with the verified access token claims; returns the user to sign in, or nil to refuse.
    attr_accessor :resolve_user

    attr_accessor :login_path, :after_login_path

    # A Faraday connection, for tests. Nil builds one with timeouts.
    attr_accessor :connection

    def initialize
      @scopes = %i[openid email profile]
      @enabled = true
      @user_class = "User"
      @login_path = "/login"
      @after_login_path = "/"
    end

    # Keycloak only puts the client into `aud` for users allowed to use it (audience mapper on
    # a role-gated client scope), so this check is the access gate.
    def audience
      @audience || client_id
    end

    def cache
      @cache || Rails.cache
    end

    def logger
      @logger || Rails.logger
    end

    def validate!
      return unless enabled

      missing = REQUIRED.select { |name| public_send(name).blank? }
      raise ArgumentError, "KeycloakSession is missing: #{missing.join(", ")}" if missing.any?
    end
  end
end
