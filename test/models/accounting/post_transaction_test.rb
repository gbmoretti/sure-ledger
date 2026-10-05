require "test_helper"

# Exercises Accounting::PostTransaction: a user-facing transaction becomes a
# balanced journal (real posting + Uncategorized counter-posting) while the
# business metadata stays on the primary Entry's Transaction.
class Accounting::PostTransactionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
  end

  def test_posts_a_balanced_journal_with_a_counter_account
    entry = post_transaction(amount: 100, name: "Groceries")

    journal = entry.journal
    assert_equal 2, journal.postings.count
    assert journal.balanced?
    assert_equal "primary", entry.posting_role
    assert_equal @account, entry.account
    assert_equal(-10_000, entry.amount_minor)
    assert_equal BigDecimal("100.0"), entry.amount

    counter = journal.postings.find_by(posting_role: "counter")
    assert_equal "Expenses:Uncategorized", counter.account.name
    assert_equal 10_000, counter.amount_minor
    assert_nil counter.entryable
  end

  def test_inflow_uses_the_income_counter_account
    entry = post_transaction(amount: -500, name: "Salary")

    counter = entry.journal.postings.find_by(posting_role: "counter")
    assert_equal "Income:Uncategorized", counter.account.name
    assert_equal 50_000, entry.amount_minor
    assert_equal BigDecimal("-500.0"), entry.amount
  end

  def test_balanced_global_sum
    post_transaction(amount: 100, name: "Groceries")
    post_transaction(amount: -500, name: "Salary")

    assert Accounting::Ledger.new(@family).balanced?
  end

  private

    def post_transaction(amount:, name:)
      Accounting::PostTransaction.new(
        family: @family,
        account: @account,
        attributes: {
          name: name,
          date: Date.current,
          amount: amount,
          currency: @account.currency,
          entryable_attributes: { category_id: categories(:one).id }
        }
      ).call
    end
end
