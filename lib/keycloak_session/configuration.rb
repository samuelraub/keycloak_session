# frozen_string_literal: true

module KeycloakSession
  class Configuration
    REQUIRED = %i[issuer client_id client_secret redirect_uri resolve_user].freeze

    # The realm URL, e.g. https://kc.example.com/realms/main. Every endpoint is discovered from it.
    attr_accessor :issuer
    attr_accessor :client_id, :client_secret, :redirect_uri
    attr_writer :audience, :cache, :logger, :post_logout_redirect_uri
    attr_accessor :scopes

    # False keeps the provider out of the middleware stack, for apps that also have another login.
    attr_accessor :enabled

    attr_accessor :user_class

    # Encrypts the stored tokens with Active Record encryption, which the app has to have keys for.
    attr_accessor :encrypt_tokens

    # Called with the verified access token claims; returns the user to sign in, or nil to refuse.
    attr_accessor :resolve_user

    attr_accessor :login_path, :after_login_path

    # A Faraday connection, for tests. Nil builds one with timeouts.
    attr_accessor :connection

    def initialize
      @scopes = %i[openid email profile]
      @enabled = true
      @user_class = "User"
      @encrypt_tokens = false
      @login_path = "/login"
      @after_login_path = "/"
    end

    # Keycloak only puts the client into `aud` for users allowed to use it (audience mapper on
    # a role-gated client scope), so this check is the access gate.
    def audience
      @audience || client_id
    end

    # Where Keycloak sends the browser after a sign-out. Has to be registered with the client.
    def post_logout_redirect_uri
      @post_logout_redirect_uri || URI.join(redirect_uri, login_path).to_s
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

      validate_encryption! if encrypt_tokens
      validate_post_logout_redirect_uri!
    end

    private

    # Otherwise every sign-out fails, after the session is gone.
    def validate_post_logout_redirect_uri!
      post_logout_redirect_uri
    rescue URI::Error => e
      raise ArgumentError, "KeycloakSession cannot derive post_logout_redirect_uri: #{e.message}"
    end

    # Otherwise the first login fails, after the user has been to Keycloak and back.
    def validate_encryption!
      ActiveRecord::Encryption.encryptor.encrypt("probe")
    rescue ActiveRecord::Encryption::Errors::Base => e
      raise ArgumentError, "KeycloakSession encrypt_tokens needs Active Record encryption: #{e.message}"
    end
  end
end
