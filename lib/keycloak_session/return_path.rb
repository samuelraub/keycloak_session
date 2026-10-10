# frozen_string_literal: true

module KeycloakSession
  # The page a visitor asked for before signing in, handed to POST /auth/keycloak as `return_to`.
  # The parameter is the visitor's to write.
  module ReturnPath
    PARAM = "return_to"
    SESSION_KEY = "keycloak_session_return_to"
    # A path of the host app. Control characters are out because browsers drop them from a URL,
    # which turns "/\t/host" into "//host".
    LOCAL = %r{\A/(?![/\\])[[:print:]]*\z}
    # The session may be a cookie of 4 kB, which the path shares with everything else in it.
    # Counted as the session's JSON holds it, where an escaped "&" takes six bytes.
    MAX_BYTES = 1024

    class << self
      # The value if it is a path to send a visitor to, or nil.
      def safe(value)
        return unless value.is_a?(String) && value.valid_encoding? && value.match?(LOCAL)
        return if ActiveSupport::JSON.encode(value).bytesize > MAX_BYTES

        # redirect_to raises on what URI cannot parse, e.g. a space or an unescaped umlaut.
        value if URI(value).host.nil?
      rescue URI::Error
        nil
      end

      # Takes the parameter out of the request before OmniAuth copies the query into the session,
      # so an oversized one is not stored at all. Replaces what an abandoned attempt left behind.
      def remember(env)
        request = Rack::Request.new(env)
        path = safe(request.delete_param(PARAM))
        path ? request.session[SESSION_KEY] = path : request.session.delete(SESSION_KEY)
      end

      def take(session)
        safe(session.delete(SESSION_KEY))
      end

      # The login path, with the path in its query when there is one.
      def login_path(path, config: KeycloakSession.config)
        return config.login_path unless path

        uri = URI(config.login_path)
        uri.query = [uri.query, {PARAM => path}.to_query].compact.join("&")
        uri.to_s
      end

      # The page a signed-out request asked for, or nil when it is nothing to come back to
      # with a GET, or a fragment of a page.
      def requested(request)
        return unless request.get? && !request.xhr? && request.headers["Turbo-Frame"].blank?

        safe(request.fullpath)
      end
    end
  end
end
