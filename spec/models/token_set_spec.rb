# frozen_string_literal: true

RSpec.describe KeycloakSession::TokenSet do
  let(:user) { User.create!(email: "a@example.test", oidc_id: "abc") }
  let!(:token_set) do
    described_class.create!(
      user: user, subject: "abc",
      access_token: fake_keycloak.access_token(sub: "abc"),
      refresh_token: fake_keycloak.refresh_token(sub: "abc")
    )
  end

  describe "#refresh" do
    it "stores the tokens Keycloak sends back" do
      fresh = {access_token: fake_keycloak.access_token(sub: "abc"), refresh_token: fake_keycloak.refresh_token}
      fake_keycloak.refreshed_tokens = fresh

      expect(token_set.refresh).to be(true)
      expect(token_set.reload).to have_attributes(fresh)
    end

    it "keeps the refresh token it has when Keycloak does not rotate it" do
      fake_keycloak.refreshed_tokens = {access_token: fake_keycloak.access_token(sub: "abc")}

      expect { token_set.refresh }.not_to change { token_set.reload.refresh_token }
    end

    it "rejects a refreshed token without the audience and drops the token set" do
      fake_keycloak.refreshed_tokens = {access_token: fake_keycloak.access_token(aud: "account")}

      expect(token_set.refresh).to be(false)
      expect(described_class.exists?(token_set.id)).to be(false)
    end

    it "keeps the token set untouched when the refresh itself fails" do
      expect(token_set.refresh).to be(false)
      expect(token_set.reload.changed?).to be(false)
    end
  end

  describe "#access_token_valid?" do
    it "returns the claims of a valid token" do
      expect(token_set.access_token_valid?).to include("sub" => "abc")
    end

    it "is false for a token that does not decode, rather than raising" do
      token_set.access_token = "not-a-token"

      expect(token_set.access_token_valid?).to be(false)
    end
  end

  describe "#end_session" do
    it "ends the session at Keycloak and drops the row" do
      token_set.end_session

      expect(fake_keycloak.ended_refresh_tokens).to eq([token_set.refresh_token])
      expect(described_class.exists?(token_set.id)).to be(false)
    end

    it "drops the row even when Keycloak is down" do
      fake_keycloak.down = true

      expect { token_set.end_session }.to change(described_class, :count).from(1).to(0)
    end
  end

  describe "expires_at" do
    it "follows the refresh token" do
      exp = 1.hour.from_now.to_i
      token_set.update!(refresh_token: fake_keycloak.refresh_token(exp: exp))

      expect(token_set.expires_at.to_i).to eq(exp)
    end

    it "stays empty for an offline token, which never expires" do
      token_set.update!(refresh_token: fake_keycloak.refresh_token(exp: nil))

      expect(token_set.expires_at).to be_nil
    end
  end

  describe ".expired" do
    it "matches an expired refresh token and a row nobody touched for months" do
      token_set.update!(refresh_token: fake_keycloak.refresh_token(exp: nil))
      expect(described_class.expired).to be_empty

      token_set.update_columns(expires_at: 1.minute.ago)
      expect(described_class.expired).to contain_exactly(token_set)

      token_set.update_columns(expires_at: nil, updated_at: 61.days.ago)
      expect(described_class.expired).to contain_exactly(token_set)
    end
  end
end
