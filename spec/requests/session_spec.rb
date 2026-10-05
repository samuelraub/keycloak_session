# frozen_string_literal: true

RSpec.describe "Keycloak session", type: :request do
  let!(:user) { User.create!(email: "a@example.test", oidc_id: "abc") }
  let(:token_sets) { KeycloakSession::TokenSet }

  def expire_access_token
    token_sets.last.update_columns(access_token: fake_keycloak.access_token(sub: "abc", exp: Time.now.to_i - 10))
  end

  describe "signing in" do
    it "sends a visitor without a session to the login page" do
      get "/"

      expect(response).to redirect_to("/login")
    end

    it "signs in a user whose token carries the audience" do
      keycloak_sign_in(sub: "abc")
      expect(response).to redirect_to("/")

      get "/"
      expect(response.body).to eq("Hello a@example.test")
      expect(token_sets.last).to have_attributes(user_id: user.id, subject: "abc", id_token: be_present)
    end

    it "refuses a token without the audience before resolving the user" do
      expect(KeycloakSession.config.resolve_user).not_to receive(:call)

      keycloak_sign_in(sub: "abc", aud: "account")

      expect(response).to redirect_to("/login")
      expect(token_sets.count).to eq(0)
      follow_redirect!
      expect(response.body).to include("Sign-in failed.")
    end

    it "refuses a subject the app does not know" do
      keycloak_sign_in(sub: "stranger")

      expect(response).to redirect_to("/login")
      expect(token_sets.count).to eq(0)
    end

    it "refuses the login when Keycloak's keys cannot be fetched" do
      fake_keycloak.down = true

      keycloak_sign_in(sub: "abc")

      expect(response).to redirect_to("/login")
    end

    it "refuses a callback without tokens" do
      OmniAuth.config.mock_auth[:keycloak] = OmniAuth::AuthHash.new(provider: "keycloak", uid: "abc")

      post "/auth/keycloak"
      follow_redirect!

      expect(response).to redirect_to("/login")
    end

    it "lands on the login page when OmniAuth reports a failure" do
      OmniAuth.config.mock_auth[:keycloak] = :invalid_credentials

      post "/auth/keycloak"
      follow_redirect!
      expect(response).to redirect_to(%r{/auth/failure})
      follow_redirect!
      expect(response).to redirect_to("/login")
    end

    it "hands the failure of another provider to the app's own handler" do
      strategy = instance_double(OmniAuth::Strategies::OpenIDConnect, name: "other")

      expect(OmniAuth.config.on_failure.call("omniauth.error.strategy" => strategy).first).to eq(418)
    end

    it "clears out expired token sets of earlier logins" do
      keycloak_sign_in(sub: "abc")
      token_sets.last.update_columns(expires_at: 1.minute.ago)

      expect { keycloak_sign_in(sub: "abc") }.not_to change(token_sets, :count)
    end

    it "keeps one token set per login, so two devices stay signed in" do
      keycloak_sign_in(sub: "abc")

      expect { keycloak_sign_in(sub: "abc") }.to change(token_sets, :count).from(1).to(2)
    end
  end

  describe "an expired access token" do
    before do
      keycloak_sign_in(sub: "abc")
      expire_access_token
    end

    it "keeps the visitor signed in on the tokens Keycloak hands back" do
      fresh = fake_keycloak.access_token(sub: "abc")
      fake_keycloak.refreshed_tokens = {access_token: fresh}

      get "/"

      expect(response.body).to eq("Hello a@example.test")
      expect(token_sets.last.access_token).to eq(fresh)
    end

    it "signs the visitor out when the refresh fails" do
      get "/"

      expect(response).to redirect_to("/login")
    end

    it "keeps the session through an outage of Keycloak" do
      fake_keycloak.down = true
      get "/"
      expect(response).to redirect_to("/login")

      fake_keycloak.down = false
      fake_keycloak.refreshed_tokens = {access_token: fake_keycloak.access_token(sub: "abc")}
      get "/"
      expect(response.body).to eq("Hello a@example.test")
    end

    it "signs the visitor out and drops the token set when the audience is gone" do
      fake_keycloak.refreshed_tokens = {access_token: fake_keycloak.access_token(sub: "abc", aud: "account")}

      get "/"

      expect(response).to redirect_to("/login")
      expect(token_sets.count).to eq(0)
    end
  end

  describe "an outage of Keycloak with a cold key cache" do
    it "keeps the session of a visitor whose token is still good" do
      keycloak_sign_in(sub: "abc")
      KeycloakSession::Client.new.clear_cache
      fake_keycloak.down = true
      get "/"
      expect(response).to redirect_to("/login")

      fake_keycloak.down = false
      get "/"
      expect(response.body).to eq("Hello a@example.test")
    end
  end

  describe "a token set that cannot be decrypted", if: KeycloakSession.config.encrypt_tokens do
    it "keeps the session, in case it is the key that is wrong" do
      keycloak_sign_in(sub: "abc")
      row = token_sets.where(id: token_sets.last.id)
      good = token_sets.connection.select_one("SELECT access_token FROM #{token_sets.table_name}")["access_token"]

      row.update_all("access_token = 'plain'")
      get "/"
      expect(response).to redirect_to("/login")

      row.update_all(["access_token = ?", good])
      get "/"
      expect(response.body).to eq("Hello a@example.test")
    end
  end

  describe "signing out" do
    before { keycloak_sign_in(sub: "abc") }

    it "ends the session here and sends the browser to Keycloak to end it there" do
      fake_keycloak.logout_page = true
      id_token = token_sets.last.id_token

      post "/auth/logout"

      expect(response.location).to start_with("https://kc.example.test/realms/test/protocol/openid-connect/logout?")
      expect(Rack::Utils.parse_query(URI(response.location).query)).to eq(
        "client_id" => "dummy", "id_token_hint" => id_token,
        "post_logout_redirect_uri" => "http://www.example.com/login"
      )
      expect(token_sets.count).to eq(0)
      get "/"
      expect(response).to redirect_to("/login")
    end

    it "keeps the ID token out of the log line about the redirect" do
      fake_keycloak.logout_page = true

      post "/auth/logout"

      expect(response.filtered_location).not_to include(response.location.split("id_token_hint=").last)
    end

    it "signs the visitor out locally when Keycloak names no logout page" do
      post "/auth/logout"

      expect(response).to redirect_to("/login")
      expect(token_sets.count).to eq(0)
    end

    it "signs the visitor out locally during an outage of Keycloak" do
      fake_keycloak.logout_page = true
      fake_keycloak.down = true
      expect { KeycloakSession::Client.new.refresh("old") }.to raise_error(KeycloakSession::Unavailable)

      post "/auth/logout"

      expect(response).to redirect_to("/login")
      expect(token_sets.count).to eq(0)
    end

    it "still goes through Keycloak when the token set is already gone" do
      fake_keycloak.logout_page = true
      token_sets.delete_all

      post "/auth/logout"

      expect(response.location).to include("/protocol/openid-connect/logout?")
      expect(response.location).not_to include("id_token_hint")
    end

    it "refuses a sign-out without a CSRF token" do
      ActionController::Base.allow_forgery_protection = true

      expect { post "/auth/logout" }.to raise_error(ActionController::InvalidAuthenticityToken)
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    it "is a no-op for a visitor who is already signed out" do
      post "/auth/logout"
      post "/auth/logout"

      expect(response).to redirect_to("/login")
    end
  end

  describe "back-channel logout" do
    before { keycloak_sign_in(sub: "abc") }

    it "drops every token set of the subject" do
      keycloak_sign_in(sub: "abc")

      post "/auth/backchannel-logout", params: {logout_token: fake_keycloak.logout_token(sub: "abc")}

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(token_sets.count).to eq(0)
    end

    it "drops only the token set of the session a sid names" do
      token_sets.delete_all
      keycloak_sign_in(sub: "abc", sid: "laptop")
      keycloak_sign_in(sub: "abc", sid: "phone")

      post "/auth/backchannel-logout", params: {logout_token: fake_keycloak.logout_token(sub: "abc", sid: "phone")}

      expect(response).to have_http_status(:ok)
      expect(token_sets.pluck(:sid)).to eq(["laptop"])
    end

    it "accepts a token that carries a sid and no subject" do
      token_sets.delete_all
      keycloak_sign_in(sub: "abc", sid: "laptop")

      post "/auth/backchannel-logout", params: {logout_token: fake_keycloak.logout_token(sub: nil, sid: "laptop")}

      expect(response).to have_http_status(:ok)
      expect(token_sets.count).to eq(0)
    end

    it "drops the subject's token sets that have no sid along with the named session" do
      post "/auth/backchannel-logout", params: {logout_token: fake_keycloak.logout_token(sub: "abc", sid: "phone")}

      expect(token_sets.count).to eq(0)
    end

    it "answers 400 to a token with neither subject nor sid" do
      post "/auth/backchannel-logout", params: {logout_token: fake_keycloak.logout_token(sub: nil)}

      expect(response).to have_http_status(:bad_request)
    end

    it "answers 400 to a token whose header is not an object" do
      post "/auth/backchannel-logout", params: {logout_token: "W10.e30.x"}

      expect(response).to have_http_status(:bad_request)
    end

    it "leaves other subjects alone" do
      post "/auth/backchannel-logout", params: {logout_token: fake_keycloak.logout_token(sub: "someone-else")}

      expect(response).to have_http_status(:ok)
      expect(token_sets.count).to eq(1)
    end

    it "answers 400 to a validly signed token that is not a logout" do
      post "/auth/backchannel-logout", params: {logout_token: fake_keycloak.access_token(sub: "abc")}

      expect(response).to have_http_status(:bad_request)
      expect(token_sets.count).to eq(1)
    end

    it "answers 400 to a forged token" do
      forged = fake_keycloak.logout_token(sub: "abc", key: fake_keycloak.foreign_key)

      post "/auth/backchannel-logout", params: {logout_token: forged}

      expect(response).to have_http_status(:bad_request)
      expect(token_sets.count).to eq(1)
    end

    it "answers 400 without a token" do
      post "/auth/backchannel-logout"

      expect(response).to have_http_status(:bad_request)
    end
  end
end
