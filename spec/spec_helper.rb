# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3::memory:"

require_relative "dummy/app"
require "rspec/rails"
require "keycloak_session/test_helpers"

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :email
    t.string :oidc_id
  end
end
ActiveRecord::MigrationContext.new(File.expand_path("../db/migrate", __dir__)).migrate

KeycloakSession::TestHelpers.install!

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.include KeycloakSession::TestHelpers

  config.before do
    KeycloakSession::TestHelpers.reset
    Rails.cache.clear
  end
end
