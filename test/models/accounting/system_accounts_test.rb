require_relative "../../../config/environment"
require "minitest/autorun"

# Guards Phase 0's synthetic chart of accounts: every installation needs these
# balancing accounts, and seeding them must not disturb the global zero-sum
# invariant.
class Accounting::SystemAccountsTest < Minitest::Test
  USD = ::Money::Currency.new("USD")

  def test_definitions_cover_required_system_accounts
    required = %w[
      Equity:Opening-Balances
      Expenses:Uncategorized
      Income:Uncategorized
      Assets:Suspense
      Income:FX-Gain/Loss
      Income:Capital-Gains
      Expenses:Fees
      Expenses:Bank-Adjustment
    ]

    assert_equal required.sort, Accounting::SystemAccounts::NAMES.sort
  end

  def test_seed_creates_accounts_with_expected_types
    ledger = Accounting::MemoryLedger.new
    Accounting::SystemAccounts.seed!(ledger, currency: USD)

    assert ledger.find_account("Equity:Opening-Balances").equity?
    assert ledger.find_account("Expenses:Uncategorized").expense?
    assert ledger.find_account("Income:Uncategorized").income?
    assert ledger.find_account("Assets:Suspense").asset?
    assert_operator ledger.global_sum, :zero?
  end

  def test_seed_is_idempotent
    ledger = Accounting::MemoryLedger.new
    Accounting::SystemAccounts.seed!(ledger, currency: USD)
    Accounting::SystemAccounts.seed!(ledger, currency: USD)

    assert_equal 8, ledger.accounts_of_type(:expenses).size + ledger.accounts_of_type(:income).size +
                    ledger.accounts_of_type(:equity).size + ledger.accounts_of_type(:assets).size
  end
end
