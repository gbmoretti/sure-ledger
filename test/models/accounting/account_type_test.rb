require_relative "../../../config/environment"
require "minitest/autorun"

class Accounting::AccountTypeTest < Minitest::Test
  FakeAccount = Struct.new(:name, :classification, :system) do
    def system? = system
  end

  def test_user_accounts_use_sure_classification
    assert_equal :assets, Accounting::AccountType.for_record(FakeAccount.new("Checking", "asset", false)).name
    assert_equal :liabilities, Accounting::AccountType.for_record(FakeAccount.new("Card", "liability", false)).name
  end

  def test_system_accounts_use_name_prefix
    assert_equal :expenses, Accounting::AccountType.for_record(FakeAccount.new("Expenses:Food", "asset", true)).name
    assert_equal :income, Accounting::AccountType.for_record(FakeAccount.new("Income:Salary", "asset", true)).name
    assert_equal :equity, Accounting::AccountType.for_record(FakeAccount.new("Equity:Opening-Balances", "asset", true)).name
    assert_equal :assets, Accounting::AccountType.for_record(FakeAccount.new("Assets:Suspense", "asset", true)).name
    assert_equal :liabilities, Accounting::AccountType.for_record(FakeAccount.new("Liabilities:Card", "asset", true)).name
  end

  def test_unknown_system_prefix_raises
    assert_raises(Accounting::Errors::UnknownAccountTypeError) do
      Accounting::AccountType.for_record(FakeAccount.new("Weird:Thing", "asset", true))
    end
  end
end
