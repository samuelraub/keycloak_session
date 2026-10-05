# frozen_string_literal: true

module KeycloakSession
  class SessionsController < ActionController::Base
    protect_from_forgery with: :exception
    skip_forgery_protection only: :backchannel_logout

    def callback
      auth = request.env["omniauth.auth"] or return refuse
      access_token = auth.dig("credentials", "token")
      refresh_token = auth.dig("credentials", "refresh_token")
      return refuse if access_token.blank? || refresh_token.blank?

      # Verified before the user is resolved: no account for realm users who may not use this client.
      claims = Verifier.new.decode_access_token(access_token)
      claims["sub"] ||= auth["uid"]
      user = settings.resolve_user.call(claims) or return refuse

      TokenSet.expired.delete_all
      token_set = TokenSet.create!(
        user: user, subject: claims["sub"], access_token: access_token, refresh_token: refresh_token
      )

      reset_session
      session[SESSION_KEY] = token_set.id
      redirect_to settings.after_login_path
    rescue JWT::DecodeError => e
      settings.logger.warn("Keycloak login refused: #{e.message}")
      refuse
    end

    def failure
      settings.logger.warn("Keycloak login failed: #{params[:message]}")
      refuse
    end

    def logout
      TokenSet.find_by(id: session[SESSION_KEY])&.end_session if session[SESSION_KEY]
      reset_session
      redirect_to settings.login_path
    end

    def backchannel_logout
      response.headers["Cache-Control"] = "no-store"

      claims = Verifier.new.decode_logout_token(params[:logout_token])
      return head(:bad_request) if claims["sub"].blank?

      TokenSet.where(subject: claims["sub"]).destroy_all
      head :ok
    rescue JWT::DecodeError => e
      settings.logger.warn("Keycloak logout token refused: #{e.message}")
      head :bad_request
    end

    private

    def settings = KeycloakSession.config

    def refuse
      redirect_to settings.login_path, alert: I18n.t("keycloak_session.login_failed", default: "Sign-in failed.")
    end
  end
end
