# frozen_string_literal: true

module KeycloakSession
  # The tokens of one login. The session cookie only holds this row's id.
  class TokenSet < ActiveRecord::Base
    self.table_name = "keycloak_session_token_sets"

    # A row nobody refreshed for this long belongs to a cookie that is gone.
    STALE_AFTER = 60.days

    # Longer than a request to Keycloak can take, so only the claim of a dead process runs out.
    REFRESH_CLAIM = 15.seconds
    REFRESH_POLL = 0.05

    # The tokens were written under the other `encrypt_tokens` setting, or the key is wrong.
    class Unreadable < StandardError; end

    belongs_to :user, class_name: KeycloakSession.config.user_class

    encrypts :access_token, :refresh_token, :id_token if KeycloakSession.config.encrypt_tokens

    validates :subject, :access_token, :refresh_token, presence: true
    before_save :set_expires_at, if: :refresh_token_changed?

    scope :expired, -> { where(expires_at: ...Time.current).or(where(updated_at: ...STALE_AFTER.ago)) }

    # The claims, or false. Raises Unavailable while Keycloak's keys cannot be fetched.
    def access_token_valid?
      verifier.decode_access_token(readable(:access_token))
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

    # Drops the row and returns where the browser ends the session at Keycloak, or nil.
    # Keycloak learns nothing unless the browser goes there.
    def logout_url!
      client.logout_url(readable(:id_token))
    rescue Unreadable
      client.logout_url(nil)
    ensure
      destroy
    end

    private

    # One request at a time, because a rotating realm takes a second use of a refresh token for
    # theft. A claim on the row rather than a lock: SQLite has no row locks, and no transaction
    # stays open while Keycloak answers.
    # Saved before the new access token is verified, so an outage there cannot lose the pair.
    def renew_tokens
      seen = readable(:access_token)
      until claim_refresh
        sleep REFRESH_POLL
        return true if reload.access_token != seen
      end

      begin
        # A parallel request was first; its tokens are the current ones.
        return true if reload.access_token != seen

        tokens = client.refresh(readable(:refresh_token)) or return false
        update!(tokens.reverse_merge(refresh_token: refresh_token))
      ensure
        self.class.where(id: id).update_all(refreshing_until: nil)
      end
    end

    def claim_refresh
      now = Time.current
      self.class.where(id: id).where("refreshing_until IS NULL OR refreshing_until < ?", now)
        .update_all(refreshing_until: now + REFRESH_CLAIM) == 1
    end

    def readable(name)
      value = public_send(name)
      # Ciphertext is a JSON document, which no token is.
      raise Unreadable, "#{name} is encrypted" if value&.start_with?("{")

      value
    rescue ActiveRecord::Encryption::Errors::Decryption
      raise Unreadable, "#{name} cannot be decrypted"
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
