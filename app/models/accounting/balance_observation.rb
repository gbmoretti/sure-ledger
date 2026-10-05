module Accounting
  # An external bank balance reported by a provider or statement import. An
  # observation is a fact and never mutates the ledger; reconciliation compares
  # it against the sum of postings.
  class BalanceObservation < ApplicationRecord
    self.table_name = "balance_observations"

    belongs_to :account

    validates :amount, :currency, :observed_at, :source, :kind, presence: true

    def amount_money
      Money.parse(amount, currency)
    end
  end
end
