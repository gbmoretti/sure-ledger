module Accounting
  # Translates between Sure's cash sign convention and the ledger's
  # debit-positive convention. This is the single place the two conventions
  # meet (see spikes/spike_2/ACCOUNTING_MAPPING.md "Sign convention").
  #
  # Sure:   Entry#amount is negative for an inflow to an asset and positive for
  #         an outflow; liabilities are stored as positive debt whose increase
  #         is a positive amount.
  # Ledger: positive is a debit, negative is a credit.
  #
  # Sure's sign already encodes the balance direction (balance change is
  # `-sum(entries)` for assets and `+sum(entries)` for liabilities, see
  # Balance::ForwardCalculator#signed_entry_flows), and the ledger's signed
  # posting for a real account encodes the same direction. The mapping is
  # therefore a pure negation for real (asset/liability) postings; the balancing
  # counter-posting is the negation of the sum of the real postings.
  #
  # FRAGILE: every write path and balance projection must go through here, and
  # net worth / account-balance tests must assert both conventions.
  module SignConvention
    module_function

    # Sure Entry#amount -> ledger debit-positive posting amount.
    def to_ledger(sure_amount)
      -sure_amount
    end

    # Ledger debit-positive posting amount -> Sure Entry#amount.
    def to_sure(ledger_amount)
      -ledger_amount
    end
  end
end
