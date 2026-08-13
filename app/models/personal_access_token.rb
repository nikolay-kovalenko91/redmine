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

class PersonalAccessToken < ApplicationRecord
  PREFIX        = 'pat_'
  TOKEN_PATTERN = /\Apat_[0-9a-f]{40}\z/

  belongs_to :user, :optional => false

  validates :name,       :presence => true, :length => {:maximum => 60}
  validates :expires_on, :presence => true
  validate  :expires_on_cannot_be_in_the_past

  before_create :generate_token!

  attr_reader :plain_token

  # Returns true if key looks like a personal access token
  def self.pat_format?(key)
    TOKEN_PATTERN.match?(key.to_s)
  end

  def self.hash_token(plain)
    Digest::SHA256.hexdigest(plain.to_s)
  end

  # Returns the token for the given plaintext value, or nil
  def self.find_token(plain)
    return nil unless pat_format?(plain)

    token = find_by(:token_hash => hash_token(plain))
    return nil unless token
    return nil unless ActiveSupport::SecurityUtils.secure_compare(token.token_hash, hash_token(plain))
    return nil if token.expired?

    token
  end

  # Returns the user who owns the token for the given plaintext value, or nil
  def self.find_user(plain)
    find_token(plain)&.user
  end

  # Returns the active user who owns the token for the given plaintext value, or nil
  def self.find_active_user(plain)
    user = find_user(plain)
    user if user&.active?
  end

  # Returns true if the token has expired
  def expired?
    expires_on < Date.today
  end

  # Generates a new plaintext token, stores its hash, and exposes the
  # plaintext once via #plain_token. The plaintext is never persisted.
  def generate_token!
    @plain_token = PREFIX + Redmine::Utils.random_hex(20)
    self.token_hash = self.class.hash_token(@plain_token)
  end

  private

  def expires_on_cannot_be_in_the_past
    return if expires_on.blank?

    if expires_on < Date.today
      errors.add(:expires_on, :cannot_be_in_the_past)
    end
  end
end
