# frozen_string_literal: true

class CreateKeycloakSessionTokenSets < ActiveRecord::Migration[7.1]
  def change
    create_table :keycloak_session_token_sets do |t|
      t.references :user, null: false
      t.string :subject, null: false, index: true
      t.text :access_token, null: false
      t.text :refresh_token, null: false
      t.datetime :expires_at
      t.timestamps
    end
  end
end
