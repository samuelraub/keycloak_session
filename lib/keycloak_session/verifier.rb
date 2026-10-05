# frozen_string_literal: true

module KeycloakSession
  # Verifies tokens Keycloak signed: signature, expiry, issuer and audience.
  # Both methods return the claims or raise JWT::DecodeError for a token that fails, and
  # Unavailable when the keys to judge it by cannot be fetched.
  class Verifier
    LOGOUT_EVENT = "http://schemas.openid.net/event/backchannel-logout"
    ALGORITHMS = %w[RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512].freeze
    LOGOUT_CLAIMS = %w[iat jti].freeze

    def initialize(client: Client.new, config: KeycloakSession.config)
      @client = client
      @config = config
    end

    def decode_access_token(jwt)
      decode(jwt)
    end

    def decode_logout_token(jwt)
      claims = decode(jwt)
      events = claims["events"]
      raise JWT::DecodeError, "not a logout token" unless events.is_a?(Hash) && events.key?(LOGOUT_EVENT)
      raise JWT::DecodeError, "logout token carries a nonce" if claims.key?("nonce")
      missing = LOGOUT_CLAIMS.reject { |name| claims[name].present? }
      raise JWT::DecodeError, "logout token is missing: #{missing.join(", ")}" if missing.any?

      claims
    end

    private

    def decode(jwt)
      keys = keys_for(jwt)
      options = {
        algorithms: algorithms(keys), jwks: keys,
        iss: @config.issuer, verify_iss: true,
        aud: @config.audience, verify_aud: true,
        # Without it a token would never expire: the library only checks an `exp` that is there.
        required_claims: %w[exp]
      }
      JWT.decode(jwt.to_s, nil, true, options).first
    end

    # Keycloak signs with a new kid after a key rotation, so look again before giving up.
    def keys_for(jwt)
      kid = header(jwt)["kid"]
      keys = signing_keys(@client.jwks_document)
      return keys if keys.any? { |key| key[:kid] == kid }

      signing_keys(@client.jwks_document(force: true))
    end

    # Callers are unauthenticated, and the library trips over a header that is not an object.
    def header(jwt)
      header = JWT.decode(jwt.to_s, nil, false).last
      return header if header.is_a?(Hash)

      raise JWT::DecodeError, "malformed header"
    rescue TypeError, NoMethodError
      raise JWT::DecodeError, "malformed header"
    end

    def signing_keys(document)
      raise Unavailable, "JWKS unavailable" unless document

      JWT::JWK::Set.new(document).filter { |key| key[:use] == "sig" }
    end

    def algorithms(keys)
      found = keys.filter_map { |key| key[:alg] }.uniq & ALGORITHMS
      raise JWT::DecodeError, "no signing key" if found.empty?

      found
    end
  end
end
