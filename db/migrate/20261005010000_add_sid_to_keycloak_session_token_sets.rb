# frozen_string_literal: true

class AddSidToKeycloakSessionTokenSets < ActiveRecord::Migration[7.1]
  def change
    add_column :keycloak_session_token_sets, :sid, :string
    add_index :keycloak_session_token_sets, :sid
  end
end
