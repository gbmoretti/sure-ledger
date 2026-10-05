module Accounting
  # The result of comparing a ledger balance with an external observation.
  # It is a pure value object: producing it never mutates the ledger.
  class Reconciliation
    attr_reader :account_id, :ledger_balance, :external_balance, :difference,
                :difference_signed, :observed_at

    def initialize(account_id:, ledger_balance:, external_balance:, observed_at: nil)
      @account_id = Integer(account_id)
      @ledger_balance = ledger_balance
      @external_balance = external_balance
      @observed_at = observed_at
      @difference_signed = external_balance - ledger_balance
      @difference = @difference_signed.abs
      freeze
    end

    # `difference` is the magnitude of the discrepancy; `difference_signed`
    # keeps the direction (positive means the external balance is higher).
    def reconciled?
      difference.zero?
    end

    def status
      reconciled? ? :reconciled : :unreconciled
    end

    def to_s
      "#<Reconciliation account=#{account_id} ledger=#{ledger_balance} " \
        "external=#{external_balance} difference=#{difference} status=#{status}>"
    end
  end
end
