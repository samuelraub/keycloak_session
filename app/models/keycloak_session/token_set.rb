# frozen_string_literal: true

module KeycloakSession
  # The tokens of one login. The session cookie only holds this row's id.
  class TokenSet < ActiveRecord::Base
    self.table_name = "keycloak_session_token_sets"

    # A row nobody refreshed for this long belongs to a cookie that is gone.
    STALE_AFTER = 60.days

    belongs_to :user, class_name: KeycloakSession.config.user_class

    validates :subject, :access_token, :refresh_token, presence: true
    before_save :set_expires_at, if: :refresh_token_changed?

    scope :expired, -> { where(expires_at: ...Time.current).or(where(updated_at: ...STALE_AFTER.ago)) }

    # The claims, or false. Raises Unavailable while Keycloak's keys cannot be fetched.
    def access_token_valid?
      verifier.decode_access_token(access_token)
    rescue JWT::DecodeError
      false
    end

    # False when Keycloak refuses; raises Unavailable when it could not be asked.
    def refresh
      return false unless renew_tokens

      # Keycloak keeps refreshing for a user whose role is gone and only drops the audience.
      return true if access_token_valid?

      destroy
      false
    rescue ActiveRecord::RecordNotFound
      false
    end

    # Reaching Keycloak is best effort; the local row always goes.
    def end_session
      client.end_session(refresh_token)
      destroy
    end

    private

    # Locked, because a rotating realm takes a second use of a refresh token for theft.
    # Saved before the new access token is verified, so an outage there cannot lose the pair.
    def renew_tokens
      seen = access_token
      with_lock do
        # A parallel request was first; its tokens are the current ones.
        next true if access_token != seen

        tokens = client.refresh(refresh_token) or next false
        update!(access_token: tokens[:access_token], refresh_token: tokens[:refresh_token] || refresh_token)
      end
    end

    # Unverified on purpose: Keycloak signs refresh tokens with a key it does not publish, and
    # the date only feeds the cleanup. Offline tokens carry no `exp`.
    def set_expires_at
      exp = JWT.decode(refresh_token, nil, false).first["exp"].to_i
      self.expires_at = exp.positive? ? Time.zone.at(exp) : nil
    rescue JWT::DecodeError
      self.expires_at = nil
    end

    def verifier
      @verifier ||= Verifier.new(client: client)
    end

    def client
      @client ||= Client.new
    end
  end
end
