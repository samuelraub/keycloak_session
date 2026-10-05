# frozen_string_literal: true

RSpec.describe KeycloakSession::Verifier do
  subject(:verifier) { described_class.new }

  let(:issuer) { KeycloakSession.config.issuer }

  def rejects(token)
    expect { verifier.decode_access_token(token) }.to raise_error(JWT::DecodeError)
  end

  describe "#decode_access_token" do
    it "returns the claims of a valid token" do
      expect(verifier.decode_access_token(fake_keycloak.access_token(sub: "abc"))).to include("sub" => "abc")
    end

    it "accepts the audience inside an array" do
      token = fake_keycloak.access_token(aud: %w[account dummy])

      expect(verifier.decode_access_token(token)).to include("aud" => %w[account dummy])
    end

    it "rejects a wrong audience" do
      rejects fake_keycloak.access_token(aud: "other")
    end

    it "rejects an array without the audience" do
      rejects fake_keycloak.access_token(aud: %w[account other])
    end

    it "rejects a missing audience" do
      rejects fake_keycloak.access_token(aud: nil)
    end

    it "rejects a wrong issuer" do
      rejects fake_keycloak.access_token(iss: "https://evil.example.test/realms/test")
    end

    it "rejects a missing issuer" do
      rejects fake_keycloak.access_token(iss: nil)
    end

    it "rejects a token signed by a key outside the set" do
      rejects fake_keycloak.access_token(key: fake_keycloak.foreign_key)
    end

    it "rejects an expired token" do
      rejects fake_keycloak.access_token(exp: Time.now.to_i - 10)
    end

    it "rejects an unsigned token" do
      rejects JWT.encode({iss: issuer, aud: "dummy", exp: Time.now.to_i + 60}, nil, "none")
    end

    it "rejects a token signed with a shared secret" do
      rejects JWT.encode({iss: issuer, aud: "dummy", exp: Time.now.to_i + 60}, "secret", "HS256")
    end

    it "rejects garbage" do
      rejects "not-a-token"
      rejects nil
    end

    it "accepts a token signed with a rotated key by fetching the key set again" do
      verifier.decode_access_token(fake_keycloak.access_token)
      fake_keycloak.rotate_key!

      expect(described_class.new.decode_access_token(fake_keycloak.access_token)).to include("sub")
      expect(fake_keycloak.jwks_requests).to eq(2)
    end

    it "rejects a token without an expiry" do
      rejects fake_keycloak.access_token(exp: nil)
    end

    it "rejects a header that is not an object" do
      rejects "W10.e30.x"
      rejects "bnVsbA.e30.x"
    end

    it "raises Unavailable when Keycloak is down, which is not a rejection" do
      fake_keycloak.down = true

      expect { verifier.decode_access_token(fake_keycloak.access_token) }
        .to raise_error(KeycloakSession::Unavailable)
    end
  end

  describe "#decode_logout_token" do
    it "returns the claims of a genuine back-channel logout token" do
      expect(verifier.decode_logout_token(fake_keycloak.logout_token(sub: "abc"))).to include("sub" => "abc")
    end

    it "rejects a validly signed token that is not a logout" do
      expect { verifier.decode_logout_token(fake_keycloak.access_token) }.to raise_error(JWT::DecodeError)
    end

    it "rejects a logout token carrying a nonce" do
      token = fake_keycloak.logout_token(nonce: "n")

      expect { verifier.decode_logout_token(token) }.to raise_error(JWT::DecodeError)
    end

    it "rejects a logout token without exp, iat or jti" do
      %i[exp iat jti].each do |claim|
        token = fake_keycloak.logout_token(claim => nil)

        expect { verifier.decode_logout_token(token) }.to raise_error(JWT::DecodeError)
      end
    end

    it "rejects a logout token minted for another audience" do
      token = fake_keycloak.logout_token(aud: "other")

      expect { verifier.decode_logout_token(token) }.to raise_error(JWT::DecodeError)
    end

    it "rejects a logout token signed by a key outside the set" do
      token = fake_keycloak.logout_token(key: fake_keycloak.foreign_key)

      expect { verifier.decode_logout_token(token) }.to raise_error(JWT::DecodeError)
    end
  end
end
