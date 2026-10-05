# frozen_string_literal: true

require_relative "lib/keycloak_session/version"

Gem::Specification.new do |spec|
  spec.name = "keycloak_session"
  spec.version = KeycloakSession::VERSION
  spec.authors = ["Samuel Raub"]
  spec.email = ["samuel.raub@gmail.com"]

  spec.summary = "Keycloak login for Rails apps: sign-in, token refresh, logout and back-channel logout."
  spec.homepage = "https://github.com/samuelraub/keycloak_session"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["{app,config,db,lib}/**/*", "CHANGELOG.md", "LICENSE.txt", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "jwt", ">= 2.7", "< 4"
  spec.add_dependency "omniauth", "~> 2.1"
  spec.add_dependency "omniauth-rails_csrf_protection", "~> 1.0"
  spec.add_dependency "omniauth_openid_connect", ">= 0.7", "< 1"
  spec.add_dependency "railties", ">= 7.1"
end
