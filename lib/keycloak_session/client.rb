# frozen_string_literal: true

require "digest"
require "json"
require "uri"

module KeycloakSession
  # Every request to Keycloak outside the login redirect. Total by contract: this runs on every
  # authenticated request, so a failure comes back as false or nil instead of raising. The one
  # exception is `refresh`, where an outage must not pass for a refusal.
  class Client
    # An unreachable Keycloak has to fail fast, or it ties up the app's threads.
    OPEN_TIMEOUT = 2
    TIMEOUT = 5

    CACHE_TTL = 12 * 60 * 60
    # Unknown key ids come from unauthenticated callers too, so a forced refetch is rationed.
    REFETCH_INTERVAL = 60

    def initialize(config: KeycloakSession.config)
      @config = config
    end

    # Ends the Keycloak SSO session, so the next visit to the login page asks for credentials.
    def end_session(refresh_token)
      url = endpoint("end_session_endpoint")
      return false unless url

      res = post_form(url, refresh_token: refresh_token)
      return true if res.success?

      logger.error("Keycloak logout failed with status #{res.status}")
      false
    rescue => e
      logger.error("Keycloak logout failed: #{e.class}: #{e.message}")
      false
    end

    # The new tokens, or nil when Keycloak refuses. `refresh_token` is absent while the realm
    # does not rotate them. Raises Unavailable when Keycloak gave no verdict.
    def refresh(refresh_token)
      url = endpoint("token_endpoint") or raise Unavailable, "no token_endpoint"

      res = post_form(url, refresh_token: refresh_token, grant_type: "refresh_token")
      raise Unavailable, "status #{res.status}" if res.status >= 500

      unless res.success?
        logger.error("Keycloak token refresh failed with status #{res.status}")
        return nil
      end

      body = JSON.parse(res.body, symbolize_names: true)
      return body.slice(:access_token, :refresh_token) if body[:access_token]

      logger.error("Keycloak token refresh returned no access token, only: #{body.keys.join(", ")}")
      nil
    rescue Unavailable => e
      logger.error("Keycloak token refresh failed: #{e.message}")
      raise
    rescue => e
      logger.error("Keycloak token refresh failed: #{e.class}: #{e.message}")
      raise Unavailable, e.message
    end

    # The raw key set, or nil. `force` bypasses the cache after a key rotation.
    def jwks_document(force: false)
      force &&= refetch_allowed?
      return @jwks_document if @jwks_document && !force

      @jwks_document = cache.fetch(cache_key("jwks"), expires_in: CACHE_TTL, force: force) do
        url = endpoint("jwks_uri") or raise Faraday::Error, "no jwks_uri in the discovery document"
        document = JSON.parse(get!(url).body)
        raise Faraday::Error, "empty key set" unless document.is_a?(Hash) && document["keys"].present?

        document
      end
    rescue => e
      logger.error("Keycloak JWKS fetch failed: #{e.class}: #{e.message}")
      nil
    end

    # For tests: a fake that changes its keys would otherwise be judged by the cached set.
    def clear_cache
      %w[discovery jwks jwks-refetched].each { |name| cache.delete(cache_key(name)) }
      @jwks_document = nil
      remove_instance_variable(:@discovery) if defined?(@discovery)
    end

    private

    attr_reader :config

    def endpoint(name)
      discovery&.dig(name)
    end

    def discovery
      return @discovery if defined?(@discovery)

      @discovery = cache.fetch(cache_key("discovery"), expires_in: CACHE_TTL) do
        JSON.parse(get!("#{config.issuer.chomp("/")}/.well-known/openid-configuration").body)
      end
    rescue => e
      logger.error("Keycloak discovery failed: #{e.class}: #{e.message}")
      @discovery = nil
    end

    def refetch_allowed?
      return false if cache.read(cache_key("jwks-refetched"))

      cache.write(cache_key("jwks-refetched"), true, expires_in: REFETCH_INTERVAL)
      true
    end

    # Raises, so a failed fetch leaves the surrounding cache block without writing anything.
    def get!(url)
      res = connection.get(url)
      raise Faraday::Error, "status #{res.status}" unless res.success?

      res
    end

    def post_form(url, params)
      credentials = {client_id: config.client_id, client_secret: config.client_secret}
      connection.post(url) do |req|
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
        req.body = URI.encode_www_form(credentials.merge(params))
      end
    end

    def connection
      @connection ||= config.connection || Faraday.new do |conn|
        conn.options.open_timeout = OPEN_TIMEOUT
        conn.options.timeout = TIMEOUT
      end
    end

    def cache_key(name)
      "keycloak_session/#{Digest::SHA256.hexdigest(config.issuer.to_s)[0, 16]}/#{name}"
    end

    def cache = config.cache

    def logger = config.logger
  end
end
