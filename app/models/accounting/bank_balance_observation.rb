module Accounting
  # A bank-reported balance is an observation, never a ledger mutation. In the
  # Sure fork this is backed by a persisted balance_observations row; the
  # standalone reference keeps it as a value object.
  BankBalanceObservation = Struct.new(:account_id, :observed_at, :balance, keyword_init: true)
end
