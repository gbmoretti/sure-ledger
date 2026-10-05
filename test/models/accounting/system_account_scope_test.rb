require "test_helper"

# Phase 4: ledger-only system accounts must never reach user-facing surfaces.
class Accounting::SystemAccountScopeTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @system = @family.accounts.create!(
      name: "Expenses:Uncategorized",
      accountable: LedgerAccount.new,
      balance: 0,
      cash_balance: 0,
      currency: "USD",
      system: true
    )
  end

  def test_excluded_from_user_facing_scopes
    refute_includes @family.accounts.visible, @system
    refute_includes @family.accounts.included_in_reports, @system
    refute_includes @family.accounts.manual, @system
    assert_includes @family.accounts.system_managed, @system
  end
end
