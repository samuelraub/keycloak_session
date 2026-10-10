# frozen_string_literal: true

module KeycloakSession
  class SessionsController < ActionController::Base
    protect_from_forgery with: :exception
    skip_forgery_protection only: :backchannel_logout
    # Before anything resets the session, and so that no outcome leaves the path behind.
    before_action :take_return_to, only: %i[callback failure]

    def callback
      auth = request.env["omniauth.auth"] or return refuse
      access_token = auth.dig("credentials", "token")
      refresh_token = auth.dig("credentials", "refresh_token")
      id_token = auth.dig("credentials", "id_token")
      return refuse if access_token.blank? || refresh_token.blank?

      # Verified before the user is resolved: no account for realm users who may not use this client.
      claims = Verifier.new.decode_access_token(access_token)
      claims["sub"] ||= auth["uid"]
      user = settings.resolve_user.call(claims) or return refuse

      TokenSet.expired.delete_all
      token_set = TokenSet.create!(
        user: user, subject: claims["sub"], sid: claims["sid"],
        access_token: access_token, refresh_token: refresh_token, id_token: id_token
      )

      reset_session
      session[SESSION_KEY] = token_set.id
      redirect_to after_login_path(user)
    rescue JWT::DecodeError, Unavailable => e
      settings.logger.warn("Keycloak login refused: #{e.message}")
      refuse
    end

    def failure
      settings.logger.warn("Keycloak login failed: #{params[:message]}")
      refuse
    end

    def logout
      token_set = TokenSet.find_by(id: session[SESSION_KEY]) if session[SESSION_KEY]
      reset_session
      # Through Keycloak, or the next sign-in would go through without credentials. That holds
      # without a token set too: a refused refresh drops it and leaves Keycloak's session alone.
      url = token_set ? token_set.logout_url! : Client.new.logout_url(nil)
      redirect_to url || settings.login_path, allow_other_host: true
    end

    def backchannel_logout
      response.headers["Cache-Control"] = "no-store"

      claims = Verifier.new.decode_logout_token(params[:logout_token])
      return head(:bad_request) if claims["sub"].blank? && claims["sid"].blank?

      logged_out(claims).destroy_all
      head :ok
    rescue JWT::DecodeError, Unavailable => e
      settings.logger.warn("Keycloak logout token refused: #{e.message}")
      head :bad_request
    end

    private

    def settings = KeycloakSession.config

    # A token with a `sid` ends that one Keycloak session; without, all of the subject's.
    def logged_out(claims)
      sid, sub = claims.values_at("sid", "sub")
      return TokenSet.where(subject: sub) if sid.blank?

      # Rows without a sid cannot be told apart, so they go with their subject.
      scope = TokenSet.where(sid: sid)
      sub.present? ? scope.or(TokenSet.where(sid: nil, subject: sub)) : scope
    end

    def take_return_to
      @return_to = ReturnPath.take(session)
    end

    def after_login_path(user)
      path = settings.after_login_path
      # In the controller, where redirect_to evaluated a proc before it was given arguments.
      path.is_a?(Proc) ? instance_exec(user, @return_to, &path) : @return_to || path
    end

    # With the path, so the login page can offer its button for that page again.
    def refuse
      redirect_to ReturnPath.login_path(@return_to), alert: I18n.t("keycloak_session.login_failed", default: "Sign-in failed.")
    end
  end
end
