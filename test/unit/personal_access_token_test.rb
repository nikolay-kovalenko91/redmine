# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require_relative '../test_helper'

class PersonalAccessTokenTest < ActiveSupport::TestCase
  fixtures :users, :email_addresses, :personal_access_tokens

  VALID_PLAIN   = 'pat_111111111111111111111111111111111111111a'
  EXPIRED_PLAIN = 'pat_222222222222222222222222222222222222222b'
  OTHER_PLAIN   = 'pat_333333333333333333333333333333333333333c'

  def setup
    User.current = nil
  end

  def test_generate_token_sets_plain_token_and_hash
    token = PersonalAccessToken.new(:user => User.find(1), :name => 'CI', :expires_on => Date.today + 1)
    token.save!
    assert_match PersonalAccessToken::TOKEN_PATTERN, token.plain_token
    assert_equal PersonalAccessToken.hash_token(token.plain_token), token.token_hash
  end

  def test_plain_token_is_not_persisted
    token = PersonalAccessToken.create!(:user => User.find(1), :name => 'CI', :expires_on => Date.today + 1)
    plain = token.plain_token
    reloaded = PersonalAccessToken.find(token.id)
    assert_nil reloaded.plain_token
    assert_not_equal plain, reloaded.token_hash
    assert_not PersonalAccessToken.column_names.include?('plain_token')
    assert_not PersonalAccessToken.column_names.include?('value')
  end

  def test_find_token_with_valid_plaintext_returns_token
    token = PersonalAccessToken.find_token(VALID_PLAIN)
    assert_equal personal_access_tokens(:personal_access_tokens_001), token
  end

  def test_find_token_with_unknown_plaintext_returns_nil
    assert_nil PersonalAccessToken.find_token('pat_' + ('0' * 40))
  end

  def test_find_token_with_wrong_format_returns_nil
    assert_nil PersonalAccessToken.find_token('not-a-pat')
    assert_nil PersonalAccessToken.find_token('abcdef0123456789abcdef0123456789abcdef01') # legacy-shaped key
  end

  def test_find_token_with_expired_plaintext_returns_nil
    assert_nil PersonalAccessToken.find_token(EXPIRED_PLAIN)
  end

  def test_find_user_returns_owner
    assert_equal User.find(1), PersonalAccessToken.find_user(VALID_PLAIN)
  end

  def test_find_active_user_returns_nil_for_locked_user
    User.find(1).update_column(:status, User::STATUS_LOCKED)
    assert_nil PersonalAccessToken.find_active_user(VALID_PLAIN)
  end

  def test_find_active_user_returns_nil_for_registered_user
    User.find(1).update_column(:status, User::STATUS_REGISTERED)
    assert_nil PersonalAccessToken.find_active_user(VALID_PLAIN)
  end

  def test_find_active_user_returns_user_for_active_user
    assert_equal User.find(1), PersonalAccessToken.find_active_user(VALID_PLAIN)
  end

  def test_find_token_returns_nil_after_deletion
    token = PersonalAccessToken.create!(:user => User.find(1), :name => 'CI', :expires_on => Date.today + 1)
    plain = token.plain_token
    assert PersonalAccessToken.find_token(plain)
    token.destroy
    assert_nil PersonalAccessToken.find_token(plain)
  end

  def test_expired_is_false_on_expiry_date
    token = PersonalAccessToken.new(:expires_on => Date.today)
    assert !token.expired?
  end

  def test_expired_is_true_the_day_after_expiry_date
    token = PersonalAccessToken.new(:expires_on => Date.today - 1)
    assert token.expired?
  end

  def test_blank_expiry_is_invalid
    token = PersonalAccessToken.new(:user => User.find(1), :name => 'CI', :expires_on => nil)
    assert !token.valid?
    assert token.errors[:expires_on].present?
  end

  def test_past_expiry_is_invalid
    token = PersonalAccessToken.new(:user => User.find(1), :name => 'CI', :expires_on => Date.today - 1)
    assert !token.valid?
    assert token.errors[:expires_on].present?
  end

  def test_blank_name_is_invalid
    token = PersonalAccessToken.new(:user => User.find(1), :name => '', :expires_on => Date.today + 1)
    assert !token.valid?
    assert token.errors[:name].present?
  end

  def test_nil_user_is_invalid
    token = PersonalAccessToken.new(:user => nil, :name => 'CI', :expires_on => Date.today + 1)
    assert !token.valid?
    assert token.errors[:user].present?
  end

  def test_nonexistent_user_id_is_invalid
    token = PersonalAccessToken.new(:user_id => 0, :name => 'CI', :expires_on => Date.today + 1)
    assert !token.valid?
    assert token.errors[:user].present?
  end

  def test_user_destroy_destroys_personal_access_tokens
    user = User.find(1)
    assert user.personal_access_tokens.any?
    ids = user.personal_access_tokens.ids
    user.destroy
    ids.each {|id| assert_nil PersonalAccessToken.find_by_id(id)}
  end

  def test_pat_value_is_not_resolved_by_legacy_api_key_lookup
    token = PersonalAccessToken.create!(:user => User.find(1), :name => 'CI', :expires_on => Date.today + 1)
    assert_nil User.find_by_api_key(token.plain_token)
  end

  def test_other_users_token_is_not_confused_with_owner
    token = PersonalAccessToken.find_token(OTHER_PLAIN)
    assert_equal User.find(2), token.user
    assert_not_equal User.find(1), token.user
  end
end
