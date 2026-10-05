# frozen_string_literal: true

RSpec.describe KeycloakSession::Configuration do
  subject(:config) { KeycloakSession.config.dup }

  it "names the settings that are missing" do
    config.issuer = nil
    config.client_secret = ""

    expect { config.validate! }.to raise_error(ArgumentError, "KeycloakSession is missing: issuer, client_secret")
  end

  it "asks for nothing while disabled" do
    config.issuer = nil
    config.enabled = false

    expect { config.validate! }.not_to raise_error
  end

  it "derives the post logout redirect from the callback's host, unless one is set" do
    expect(config.post_logout_redirect_uri).to eq("http://www.example.com/login")

    config.post_logout_redirect_uri = "https://elsewhere.example.test/bye"
    expect(config.post_logout_redirect_uri).to eq("https://elsewhere.example.test/bye")
  end

  it "refuses settings no post logout redirect can be derived from" do
    config.redirect_uri = "/auth/keycloak/callback"

    expect { config.validate! }.to raise_error(ArgumentError, /cannot derive post_logout_redirect_uri/)
  end

  it "refuses encrypt_tokens without Active Record encryption keys" do
    config.encrypt_tokens = true
    allow(ActiveRecord::Encryption).to receive(:encryptor)
      .and_raise(ActiveRecord::Encryption::Errors::Configuration, "Missing key")

    expect { config.validate! }.to raise_error(ArgumentError, /encrypt_tokens needs Active Record encryption/)
  end
end
