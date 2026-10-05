# frozen_string_literal: true

class AddIdTokenToKeycloakSessionTokenSets < ActiveRecord::Migration[7.1]
  def change
    add_column :keycloak_session_token_sets, :id_token, :text
  end
end
