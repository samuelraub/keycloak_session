# frozen_string_literal: true

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "keycloak_session"

module Dummy
  class Application < Rails::Application
    config.root = __dir__
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = false
    config.secret_key_base = "0" * 64
    config.hosts.clear
    config.cache_store = :memory_store
    config.logger = Logger.new(File::NULL)
    config.session_store :cookie_store, key: "_dummy_session"
    config.action_dispatch.show_exceptions = :none
    config.action_controller.allow_forgery_protection = false
    config.active_support.to_time_preserves_timezone = :zone
    config.active_record.encryption.primary_key = "dummy-primary-key"
    config.active_record.encryption.deterministic_key = "dummy-deterministic-key"
    config.active_record.encryption.key_derivation_salt = "dummy-salt"
  end
end

KeycloakSession.configure do |config|
  config.issuer = ENV.fetch("DUMMY_ISSUER", "https://kc.example.test/realms/test")
  config.client_id = "dummy"
  config.client_secret = "dummy-secret"
  config.redirect_uri = "http://www.example.com/auth/keycloak/callback"
  config.resolve_user = ->(claims) { User.find_by(oidc_id: claims["sub"]) }
  # CI runs the suite a second time with plaintext tokens, the default.
  config.encrypt_tokens = ENV["PLAINTEXT_TOKENS"].blank?
end

# Stands in for the handler of an app with a second OmniAuth provider.
OmniAuth.config.on_failure = ->(_env) { [418, {}, ["host"]] }

Dummy::Application.initialize!

class User < ActiveRecord::Base
end

class ApplicationController < ActionController::Base
  include KeycloakSession::Authentication
end

class PagesController < ApplicationController
  before_action :require_login, only: :home

  def home
    render plain: "Hello #{current_user.email}"
  end

  def login
    response.headers["X-CSRF-Token"] = form_authenticity_token
    render plain: "Login #{flash[:alert]}"
  end
end

Dummy::Application.routes.draw do
  mount KeycloakSession::Engine, at: "/auth"
  root to: "pages#home"
  get "login", to: "pages#login"
end
