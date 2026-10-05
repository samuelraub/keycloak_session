# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rails", ENV.fetch("RAILS_VERSION", "~> 8.0.0")

gem "rake"
gem "rspec-rails"
gem "sqlite3"
gem "standard"

# CI pins these to cover the oldest versions the apps run on.
gem "jwt", ENV["JWT_VERSION"] if ENV["JWT_VERSION"]
