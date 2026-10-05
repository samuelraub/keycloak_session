# frozen_string_literal: true

RSpec.describe KeycloakSession::Client do
  subject(:client) { described_class.new }

  describe "#logout_url" do
    def params(url)
      URI.decode_www_form(URI(url).query).to_h
    end

    before { fake_keycloak.logout_page = true }

    it "points at Keycloak's logout page, with the ID token as proof and the way back" do
      url = client.logout_url("id-1")

      expect(url).to start_with("https://kc.example.test/realms/test/protocol/openid-connect/logout?")
      expect(params(url)).to eq(
        "client_id" => "dummy", "id_token_hint" => "id-1",
        "post_logout_redirect_uri" => "http://www.example.com/login"
      )
    end

    it "does without the hint when there is no ID token, or one too long for a URL" do
      expect(params(client.logout_url(nil))).not_to have_key("id_token_hint")
      expect(params(client.logout_url("x" * (described_class::HINT_LIMIT + 1)))).not_to have_key("id_token_hint")
    end

    it "is nil during an outage, although the logout page is known from the cache" do
      client.logout_url("id-1")
      fake_keycloak.down = true
      expect { client.refresh("old") }.to raise_error(KeycloakSession::Unavailable)

      expect(described_class.new.logout_url("id-1")).to be_nil
    end

    it "is nil when Keycloak names no logout page or cannot be asked" do
      fake_keycloak.logout_page = false
      expect(client.logout_url("id-1")).to be_nil

      fake_keycloak.logout_page = true
      fake_keycloak.down = true
      expect(described_class.new.logout_url("id-1")).to be_nil
    end
  end

  describe "#refresh" do
    it "returns the tokens Keycloak sends back" do
      fake_keycloak.refreshed_tokens = {access_token: "a", refresh_token: "r", id_token: "i", token_type: "Bearer"}

      expect(client.refresh("old")).to eq(access_token: "a", refresh_token: "r", id_token: "i")
    end

    it "returns the access token on its own when the refresh token is not rotated" do
      fake_keycloak.refreshed_tokens = {access_token: "a"}

      expect(client.refresh("old")).to eq(access_token: "a")
    end

    it "reports a failure when Keycloak rejects the request" do
      expect(client.refresh("old")).to be_nil
    end

    it "raises Unavailable when a 200 carries no access token" do
      fake_keycloak.refreshed_tokens = {access_token: "", id_token: "i"}

      expect { client.refresh("old") }.to raise_error(KeycloakSession::Unavailable)
    end

    it "leaves out a blank refresh token" do
      fake_keycloak.refreshed_tokens = {access_token: "a", refresh_token: ""}

      expect(client.refresh("old")).to eq(access_token: "a")
    end

    it "raises Unavailable when Keycloak is down, which is not a refusal" do
      fake_keycloak.down = true

      expect { client.refresh("old") }.to raise_error(KeycloakSession::Unavailable)
    end

    it "raises Unavailable on any answer that does not judge the refresh token" do
      answers = [[503, "{}"], [429, "{}"], [401, '{"error":"invalid_client"}'],
        [400, '{"error":"invalid_client"}'], [404, "<html>"]]
      answers.each do |status, body|
        response = instance_double(Faraday::Response, status: status, body: body, success?: false)
        allow(client).to receive(:post_form).and_return(response)

        expect { client.refresh("old") }.to raise_error(KeycloakSession::Unavailable)
      end
    end
  end

  describe "after a request Keycloak did not answer" do
    include ActiveSupport::Testing::TimeHelpers

    before do
      client.jwks_document
      fake_keycloak.down = true
      expect { client.refresh("old") }.to raise_error(KeycloakSession::Unavailable)
    end

    it "skips the next requests instead of waiting for each to time out" do
      expect(KeycloakSession.config.connection).not_to receive(:post)

      expect { described_class.new.refresh("old") }.to raise_error(KeycloakSession::Unavailable)
    end

    it "tries again a moment later" do
      travel(described_class::DOWN_FOR + 1) do
        expect(KeycloakSession.config.connection).to receive(:post).and_call_original

        expect { described_class.new.refresh("old") }.to raise_error(KeycloakSession::Unavailable)
      end
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

      expect(described_class.new.jwks_document(force: true)).to be_nil
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
