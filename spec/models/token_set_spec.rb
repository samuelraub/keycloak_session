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

  describe "encrypted tokens", if: KeycloakSession.config.encrypt_tokens do
    # Raw SQL, because `update_all` would encrypt.
    def store_plaintext
      described_class.where(id: token_set.id).update_all("access_token = 'plain', refresh_token = 'plain'")
      token_set.reload
    end

    it "keeps neither token readable in the table" do
      raw = described_class.connection.select_one("SELECT access_token, refresh_token FROM #{described_class.table_name}")

      expect(raw["access_token"]).not_to include(token_set.access_token)
      expect(raw["refresh_token"]).not_to include(token_set.refresh_token)
      expect(token_set.reload.access_token_valid?).to include("sub" => "abc")
    end

    it "cannot read a row from before encryption, and leaves it alone" do
      store_plaintext

      expect { token_set.access_token_valid? }.to raise_error(described_class::Unreadable)
      expect { token_set.refresh }.to raise_error(described_class::Unreadable)
      expect(described_class.exists?(token_set.id)).to be(true)
    end

    it "still drops such a row on sign-out, without bothering Keycloak" do
      store_plaintext

      token_set.end_session

      expect(fake_keycloak.ended_refresh_tokens).to be_empty
      expect(described_class.exists?(token_set.id)).to be(false)
    end
  end

  describe "plaintext tokens", unless: KeycloakSession.config.encrypt_tokens do
    before { token_set.update_columns(access_token: '{"p":"x"}', refresh_token: '{"p":"y"}') }

    it "does not hand ciphertext from an encrypted past to Keycloak" do
      fake_keycloak.refreshed_tokens = {access_token: fake_keycloak.access_token(sub: "abc")}

      expect { token_set.refresh }.to raise_error(described_class::Unreadable)
      token_set.end_session
      expect(fake_keycloak.ended_refresh_tokens).to be_empty
    end
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

    it "raises Unavailable and keeps the token set when Keycloak is down" do
      fake_keycloak.down = true

      expect { token_set.refresh }.to raise_error(KeycloakSession::Unavailable)
      expect(token_set.reload.changed?).to be(false)
    end

    it "keeps the new tokens when they cannot be verified during an outage" do
      fresh = {access_token: fake_keycloak.access_token(sub: "abc"), refresh_token: fake_keycloak.refresh_token}
      fake_keycloak.refreshed_tokens = fresh
      allow_any_instance_of(KeycloakSession::Verifier).to receive(:decode_access_token)
        .and_raise(KeycloakSession::Unavailable)

      expect { token_set.refresh }.to raise_error(KeycloakSession::Unavailable)
      expect(token_set.reload).to have_attributes(fresh)
    end

    it "does not spend the refresh token again after a parallel request refreshed" do
      late = described_class.find(token_set.id)
      fake_keycloak.refreshed_tokens = {access_token: fake_keycloak.access_token(sub: "abc", jti: "fresh")}
      token_set.refresh
      fake_keycloak.refreshed_tokens = nil

      expect(late.refresh).to be(true)
      expect(late.access_token).to eq(token_set.access_token)
    end

    it "waits for a refresh in progress and takes its tokens" do
      fresh = fake_keycloak.access_token(sub: "abc", jti: "fresh")
      token_set.update_columns(refreshing_until: 10.seconds.from_now)
      allow(token_set).to receive(:sleep) do
        described_class.where(id: token_set.id).update_all(access_token: fresh, refreshing_until: nil)
      end

      expect(token_set.refresh).to be(true)
      expect(token_set.access_token).to eq(fresh)
    end

    it "takes over from a refresh that never finished" do
      token_set.update_columns(refreshing_until: 1.second.ago)
      fake_keycloak.refreshed_tokens = {access_token: fake_keycloak.access_token(sub: "abc", jti: "fresh")}

      expect(token_set.refresh).to be(true)
    end

    it "gives up its claim whatever the outcome" do
      token_set.refresh
      expect(token_set.reload.refreshing_until).to be_nil

      fake_keycloak.down = true
      expect { token_set.refresh }.to raise_error(KeycloakSession::Unavailable)
      expect(token_set.reload.refreshing_until).to be_nil
    end

    it "is false when the token set was dropped in the meantime" do
      described_class.find(token_set.id).destroy

      expect(token_set.refresh).to be(false)
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

    it "raises Unavailable when Keycloak is down" do
      fake_keycloak.down = true

      expect { token_set.access_token_valid? }.to raise_error(KeycloakSession::Unavailable)
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
