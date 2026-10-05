# frozen_string_literal: true

require "keycloak_session"
require "openssl"
require "securerandom"

module KeycloakSession
  # Test support for apps using the gem, independent of the test framework:
  #
  #   require "keycloak_session/test_helpers"
  #   KeycloakSession::TestHelpers.install!
  #   include KeycloakSession::TestHelpers
  #
  # Tokens are really signed and really verified; only the HTTP calls to Keycloak are served
  # from memory.
  module TestHelpers
    # Stands in for the realm: signs tokens and answers discovery, JWKS, refresh and logout.
    class FakeKeycloak
      attr_reader :ended_refresh_tokens, :jwks_requests
      # What the token endpoint answers a refresh with: a hash of tokens, or nil to refuse.
      attr_accessor :refreshed_tokens

      def initialize(config: KeycloakSession.config)
        @config = config
        @keys = {}
        reset
      end

      def reset
        @down = false
        @refreshed_tokens = nil
        @ended_refresh_tokens = []
        @jwks_requests = 0
        @signing_key = key(:default)
      end

      def down=(value)
        @down = value
        # Back for good: the app would otherwise keep its distance for a moment longer.
        Client.new(config: @config).forget_outage unless value
      end

      # Signs with a new key from now on, as Keycloak does after a rotation.
      def rotate_key!
        @signing_key = OpenSSL::PKey::RSA.generate(2048)
      end

      # A key the realm does not publish.
      def foreign_key
        key(:foreign)
      end

      def access_token(sub: "test-subject", key: @signing_key, **claims)
        payload = {iss: @config.issuer, aud: @config.audience, sub: sub, exp: Time.now.to_i + 300}
        sign(payload.merge(claims).compact, key)
      end

      def refresh_token(sub: "test-subject", **claims)
        payload = {iss: @config.issuer, aud: @config.issuer, sub: sub, exp: Time.now.to_i + 1800,
                   jti: SecureRandom.uuid}
        JWT.encode(payload.merge(claims).compact, "keycloak-internal", "HS512")
      end

      def logout_token(sub: "test-subject", key: @signing_key, **claims)
        payload = {iss: @config.issuer, aud: @config.audience, sub: sub, iat: Time.now.to_i,
                   exp: Time.now.to_i + 120, jti: SecureRandom.uuid,
                   events: {Verifier::LOGOUT_EVENT => {}}}
        sign(payload.merge(claims).compact, key)
      end

      def connection
        @connection ||= Faraday.new { |conn| conn.adapter(:test, stubs) }
      end

      private

      def key(name)
        @keys[name] ||= OpenSSL::PKey::RSA.generate(2048)
      end

      def sign(payload, key)
        JWT.encode(payload, key, "RS256", kid: jwk(key).kid)
      end

      def jwk(key)
        JWT::JWK.new(key, use: "sig", alg: "RS256")
      end

      def stubs
        base = URI(@config.issuer).path.chomp("/")
        Faraday::Adapter::Test::Stubs.new do |stub|
          stub.get("#{base}/.well-known/openid-configuration") { respond(discovery_document) }
          stub.get("#{base}/protocol/openid-connect/certs") do
            @jwks_requests += 1
            respond({keys: [jwk(@signing_key).export]})
          end
          stub.post("#{base}/protocol/openid-connect/token") do
            @refreshed_tokens ? respond(@refreshed_tokens) : respond({error: "invalid_grant"}, status: 400)
          end
          stub.post("#{base}/protocol/openid-connect/logout") do |env|
            @ended_refresh_tokens << URI.decode_www_form(env.body).to_h["refresh_token"]
            respond(nil, status: 204)
          end
        end
      end

      def discovery_document
        endpoints = "#{@config.issuer.chomp("/")}/protocol/openid-connect"
        {
          issuer: @config.issuer,
          jwks_uri: "#{endpoints}/certs",
          token_endpoint: "#{endpoints}/token",
          end_session_endpoint: "#{endpoints}/logout"
        }
      end

      def respond(body, status: 200)
        raise Faraday::ConnectionFailed, "Keycloak is down" if @down

        [status, {"Content-Type" => "application/json"}, body ? JSON.generate(body) : ""]
      end
    end

    class << self
      attr_reader :fake_keycloak

      # Call once, after the app has booted. The fake stays installed for the whole process,
      # because system tests keep serving requests while an example tears down.
      def install!
        OmniAuth.config.test_mode = true
        @fake_keycloak = FakeKeycloak.new
        KeycloakSession.config.connection = @fake_keycloak.connection
      end

      # Call between tests.
      def reset
        fake_keycloak.reset
        Client.new.clear_cache
        OmniAuth.config.mock_auth.delete(KeycloakSession::PROVIDER)
      end
    end

    def fake_keycloak
      TestHelpers.fake_keycloak
    end

    # Prepares what Keycloak hands back at the callback. Trigger the login afterwards:
    # POST /auth/keycloak in a request test, or click the app's sign-in button in a system test.
    # Extra claims end up in the access token; `aud: nil` is a user without access.
    def mock_keycloak_login(sub: "test-subject", email: nil, **claims)
      OmniAuth.config.mock_auth[KeycloakSession::PROVIDER] = OmniAuth::AuthHash.new(
        provider: KeycloakSession::PROVIDER.to_s,
        uid: sub,
        info: {email: email},
        credentials: {
          token: fake_keycloak.access_token(sub: sub, email: email, **claims),
          refresh_token: fake_keycloak.refresh_token(sub: sub)
        }
      )
    end

    # For request and integration tests.
    def keycloak_sign_in(**)
      mock_keycloak_login(**)
      post "/auth/keycloak"
      follow_redirect!
    end
  end
end
