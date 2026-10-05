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

  it "refuses encrypt_tokens without Active Record encryption keys" do
    config.encrypt_tokens = true
    allow(ActiveRecord::Encryption).to receive(:encryptor)
      .and_raise(ActiveRecord::Encryption::Errors::Configuration, "Missing key")

    expect { config.validate! }.to raise_error(ArgumentError, /encrypt_tokens needs Active Record encryption/)
  end
end
