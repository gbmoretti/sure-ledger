require "test_helper"

# Exercises the AR-backed ledger against real records (Phase 2).
class Accounting::LedgerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @ledger = Accounting::Ledger.new(@family)
    @checking = accounts(:depository)
  end

  def test_posts_a_balanced_journal_and_derives_the_balance
    expense = create_system_account("Expenses:Test", :expenses)

    journal = @ledger.post(
      date: Date.current,
      description: "Test expense",
      postings: [
        { account: @checking, amount_minor: -10_000, role: "primary" },
        { account: expense, amount_minor: 10_000, role: "counter" }
      ]
    )

    assert journal.persisted?
    assert_equal 2, journal.postings.count
    assert journal.balanced?
    assert_equal(-10_000, @ledger.balance(@checking).minor_units)
    assert_equal 10_000, @ledger.balance(expense).minor_units
    assert @ledger.balanced?
    assert_equal 0, @ledger.global_sum.minor_units
  end

  def test_primary_projection_uses_sure_sign
    expense = create_system_account("Expenses:Test", :expenses)
    journal = @ledger.post(
      date: Date.current,
      description: "Test expense",
      postings: [
        { account: @checking, amount_minor: -10_000, role: "primary" },
        { account: expense, amount_minor: 10_000, role: "counter" }
      ]
    )

    primary = journal.postings.find_by(posting_role: "primary")
    assert_equal(-10_000, primary.amount_minor)
    # Sure convention: a cash outflow is a positive entry amount.
    assert_equal BigDecimal("100.00"), primary.amount
  end

  def test_open_account_posts_against_equity
    @ledger.open_account(@checking, opening_balance: Accounting::Money.parse("5000", "USD"))

    assert_equal 500_000, @ledger.balance(@checking).minor_units
    assert_equal(-500_000, @ledger.balance(@family.accounts.find_by(name: "Equity:Opening-Balances")).minor_units)
    assert @ledger.balanced?
  end

  def test_transfer_posts_two_asset_postings
    savings = create_system_account("Assets:Savings", :assets)

    @ledger.transfer(from: @checking, to: savings, amount: Accounting::Money.parse("250", "USD"), date: Date.current)

    assert_equal(-25_000, @ledger.balance(@checking).minor_units)
    assert_equal 25_000, @ledger.balance(savings).minor_units
    assert @ledger.balanced?
  end

  def test_reconciliation_does_not_mutate_the_ledger
    @ledger.open_account(@checking, opening_balance: Accounting::Money.parse("5000", "USD"))
    before = @ledger.global_sum

    result = @ledger.reconcile(@checking, observed_balance: Accounting::Money.parse("5100", "USD"))

    assert_equal :unreconciled, result.status
    assert_equal 10_000, result.difference.minor_units
    assert_equal 500_000, @ledger.balance(@checking).minor_units
    assert_equal before, @ledger.global_sum
  end

  def test_observe_balance_records_a_fact
    observation = @ledger.observe_balance(
      @checking,
      balance: Accounting::Money.parse("5100", "USD"),
      observed_at: Time.current,
      source: "manual",
      kind: "statement"
    )

    assert observation.persisted?
    assert_equal BigDecimal("5100.0"), observation.amount
  end

  def test_post_is_idempotent_by_source_and_external_id
    expense = create_system_account("Expenses:Test", :expenses)
    attrs = {
      date: Date.current,
      description: "Imported",
      postings: [
        { account: @checking, amount_minor: -10_000, role: "primary" },
        { account: expense, amount_minor: 10_000, role: "counter" }
      ],
      source: "bank",
      external_id: "abc123"
    }

    first = @ledger.post(**attrs)
    second = @ledger.post(**attrs)

    assert_equal first.id, second.id
    assert_equal 1, @family.journals.where(source: "bank", external_id: "abc123").count
  end

  def test_attach_balances_an_existing_single_sided_entry
    entry = @checking.entries.create!(date: Date.current, name: "Legacy", amount: 100, currency: "USD", entryable: Transaction.new)

    @ledger.attach(entry)
    entry.reload

    assert entry.journal.present?
    assert_equal(-10_000, entry.amount_minor)
    assert_equal "primary", entry.posting_role
    assert entry.journal.balanced?
    assert @ledger.balanced?
    assert_equal 1, entry.journal.postings.where(posting_role: "counter").count
  end

  def test_attach_is_idempotent
    entry = @checking.entries.create!(date: Date.current, name: "Legacy", amount: 100, currency: "USD", entryable: Transaction.new)

    @ledger.attach(entry)
    journal = entry.reload.journal
    @ledger.attach(entry)

    assert_equal journal.id, entry.reload.journal_id
    assert_equal 1, @family.journals.count
  end

  private

    def create_system_account(name, _type)
      @family.accounts.create!(
        name: name,
        accountable: LedgerAccount.new,
        balance: 0,
        cash_balance: 0,
        currency: "USD",
        system: true
      )
    end
end
