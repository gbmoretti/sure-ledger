class LedgerAccount < ApplicationRecord
  include Accountable

  SUBTYPES = {}.freeze

  def self.classification
    "asset"
  end

  def self.icon
    "book-open"
  end

  def self.color
    "#6b7280"
  end
end
