class CreatePersonalAccessTokens < ActiveRecord::Migration[7.2]
  def change
    create_table :personal_access_tokens do |t|
      t.integer  :user_id,    null: false
      t.string   :name,       limit: 60, null: false
      t.string   :token_hash, limit: 64, null: false
      t.date     :expires_on, null: false
      t.datetime :created_on, precision: nil, null: false
    end
    add_index :personal_access_tokens, :token_hash, unique: true
    add_index :personal_access_tokens, :user_id
  end
end
