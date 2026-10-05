# frozen_string_literal: true

class AddRefreshingUntilToKeycloakSessionTokenSets < ActiveRecord::Migration[7.1]
  def change
    add_column :keycloak_session_token_sets, :refreshing_until, :datetime
  end
end
