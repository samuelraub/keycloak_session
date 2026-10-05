# frozen_string_literal: true

RSpec.describe KeycloakSession::Client do
  subject(:client) { described_class.new }

  describe "#end_session" do
    it "posts the refresh token to Keycloak" do
      expect(client.end_session("refresh-1")).to be(true)
      expect(fake_keycloak.ended_refresh_tokens).to eq(["refresh-1"])
    end

    it "reports a failure rather than raising when Keycloak is down" do
      fake_keycloak.down = true

      expect(client.end_session("refresh-1")).to be(false)
    end
  end

  describe "#refresh" do
    it "returns the tokens Keycloak sends back" do
      fake_keycloak.refreshed_tokens = {access_token: "a", refresh_token: "r", id_token: "i"}

      expect(client.refresh("old")).to eq(access_token: "a", refresh_token: "r")
    end

    it "returns the access token on its own when the refresh token is not rotated" do
      fake_keycloak.refreshed_tokens = {access_token: "a"}

      expect(client.refresh("old")).to eq(access_token: "a")
    end

    it "reports a failure when Keycloak rejects the request" do
      expect(client.refresh("old")).to be_nil
    end

    it "reports a failure when a 200 carries no access token" do
      fake_keycloak.refreshed_tokens = {id_token: "i"}

      expect(client.refresh("old")).to be_nil
    end

    it "raises Unavailable when Keycloak is down, which is not a refusal" do
      fake_keycloak.down = true

      expect { client.refresh("old") }.to raise_error(KeycloakSession::Unavailable)
    end

    it "raises Unavailable on a server error" do
      allow(client).to receive(:post_form).and_return(instance_double(Faraday::Response, status: 503))

      expect { client.refresh("old") }.to raise_error(KeycloakSession::Unavailable)
    end
  end

  describe "#jwks_document" do
    it "returns the key set" do
      expect(client.jwks_document["keys"].size).to eq(1)
    end

    it "is served from the cache across instances" do
      client.jwks_document
      described_class.new.jwks_document

      expect(fake_keycloak.jwks_requests).to eq(1)
    end

    it "does not cache a failed fetch" do
      fake_keycloak.down = true
      expect(client.jwks_document).to be_nil

      fake_keycloak.down = false
      expect(described_class.new.jwks_document).to be_a(Hash)
    end

    it "refetches when forced, but only once a minute" do
      client.jwks_document
      described_class.new.jwks_document(force: true)
      described_class.new.jwks_document(force: true)

      expect(fake_keycloak.jwks_requests).to eq(2)
    end

    it "reports a failure rather than raising when the cache itself blows up" do
      broken = Class.new(ActiveSupport::Cache::MemoryStore) { def fetch(*) = raise("cache down") }.new
      allow(KeycloakSession.config).to receive(:cache).and_return(broken)

      expect(client.jwks_document).to be_nil
    end
  end

  it "keeps the caches of two realms apart" do
    client.jwks_document
    other = KeycloakSession.config.dup
    other.issuer = "https://kc.example.test/realms/other"

    expect(described_class.new(config: other).jwks_document).to be_nil
  end

  it "bounds its requests, so an unreachable Keycloak cannot wedge the app" do
    allow(KeycloakSession.config).to receive(:connection).and_return(nil)
    options = client.send(:connection).options

    expect([options.open_timeout, options.timeout]).to eq([2, 5])
  end
end
