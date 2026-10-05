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

    # The claims, or false.
    def access_token_valid?
      verifier.decode_access_token(access_token)
    rescue JWT::DecodeError
      false
    end

    def refresh
      tokens = client.refresh(refresh_token)
      return false unless tokens

      self.access_token = tokens[:access_token]
      self.refresh_token = tokens[:refresh_token] || refresh_token

      # Keycloak keeps refreshing for a user whose role is gone and only drops the audience.
      return save if access_token_valid?

      destroy
      false
    end

    # Reaching Keycloak is best effort; the local row always goes.
    def end_session
      client.end_session(refresh_token)
      destroy
    end

    private

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
