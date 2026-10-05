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
    # After a request that got no answer, the next ones are skipped rather than left to time out
    # as well: during an outage every signed-in request would otherwise wait in turn.
    DOWN_FOR = 10

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
      body = JSON.parse(res.body, symbolize_names: true)
      # The one answer that judges the refresh token. A wrong client secret or a rate limit does not.
      if res.status == 400 && body[:error] == "invalid_grant"
        logger.warn("Keycloak refused the token refresh: #{body[:error_description]}")
        return nil
      end
      raise Unavailable, "status #{res.status}" unless res.success?
      raise Unavailable, "no access token, only: #{body.keys.join(", ")}" if body[:access_token].blank?

      body.slice(:access_token, :refresh_token).compact_blank
    rescue => e
      logger.error("Keycloak token refresh failed: #{e.class}: #{e.message}")
      raise e.is_a?(Unavailable) ? e : Unavailable.new(e.message)
    end

    # The raw key set, or nil. `force` bypasses the cache after a key rotation, and is nil while
    # rationed: a key missing from the cached set may exist all the same.
    def jwks_document(force: false)
      return nil if force && !refetch_allowed?
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
      %w[discovery jwks jwks-refetched down].each { |name| cache.delete(cache_key(name)) }
      @jwks_document = nil
      remove_instance_variable(:@discovery) if defined?(@discovery)
    end

    # For tests: Keycloak is back before DOWN_FOR is over.
    def forget_outage
      cache.delete(cache_key("down"))
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
      cache.write(cache_key("jwks-refetched"), true, expires_in: REFETCH_INTERVAL, unless_exist: true)
    end

    def request
      raise Faraday::Error, "skipped, Keycloak did not answer a moment ago" if down?

      begin
        res = yield
      rescue Faraday::Error
        down!
        raise
      end
      down! if res.status >= 500
      res
    end

    # The marker is a courtesy; a cache that fails must not add to the trouble.
    def down?
      cache.read(cache_key("down"))
    rescue
      false
    end

    def down!
      cache.write(cache_key("down"), true, expires_in: DOWN_FOR)
    rescue
      nil
    end

    # Raises, so a failed fetch leaves the surrounding cache block without writing anything.
    def get!(url)
      res = request { connection.get(url) }
      raise Faraday::Error, "status #{res.status}" unless res.success?

      res
    end

    def post_form(url, params)
      credentials = {client_id: config.client_id, client_secret: config.client_secret}
      request do
        connection.post(url) do |req|
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
          req.body = URI.encode_www_form(credentials.merge(params))
        end
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
