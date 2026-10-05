# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rails", ENV.fetch("RAILS_VERSION", "~> 8.0.0")

gem "rake"
gem "rspec-rails"
gem "sqlite3"
gem "standard"

# CI pins these to cover the oldest versions the apps run on.
gem "jwt", ENV["JWT_VERSION"] unless ENV["JWT_VERSION"].to_s.empty?

# Active Support before 8.1 passes JSON an option that json 3 dropped.
gem "json", "< 3" unless ENV["RAILS_VERSION"].to_s.include?("8.1")
