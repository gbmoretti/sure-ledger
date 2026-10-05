module Accounting
  # The synthetic ledger accounts required by every installation. These are
  # balancing accounts, not user-visible accounts: Phase 4 seeds them per family
  # and flags them so they are excluded from net worth, reports and the API.
  module SystemAccounts
    DEFINITIONS = [
      { name: "Equity:Opening-Balances",  type: :equity },
      { name: "Expenses:Uncategorized",   type: :expenses },
      { name: "Income:Uncategorized",     type: :income },
      { name: "Assets:Suspense",          type: :assets },
      { name: "Income:FX-Gain/Loss",      type: :income },
      { name: "Income:Capital-Gains",     type: :income },
      { name: "Expenses:Fees",            type: :expenses },
      { name: "Expenses:Bank-Adjustment", type: :expenses }
    ].freeze

    NAMES = DEFINITIONS.map { |definition| definition[:name] }.freeze

    module_function

    # Seeds the synthetic accounts into an in-memory reference ledger. The
    # AR-backed equivalent is introduced in Phase 4.
    def seed!(ledger, currency:)
      DEFINITIONS.each do |definition|
        ledger.create_account(name: definition[:name], type: definition[:type], currency: currency)
      rescue Errors::DuplicateAccountError
        next
      end
    end
  end
end
