require_relative "../../../config/environment"
require "minitest/autorun"

# Behavioral tests for the double-entry core. Each test states the accounting
# semantics it guards, especially the two invariants:
#
#   sum(all postings of a journal entry) == 0
#   account balance == opening balance + sum(postings)
#
# and the rule that an external bank balance never mutates the ledger.
#
# Ported from spikes/double_entry/test/double_entry_test.rb (24 tests) to run
# against the Accounting::* boundary. This is the executable specification for
# the AR-backed ledger.
#
# Deliberately a plain Minitest::Test (not ActiveSupport::TestCase): the domain
# is pure Ruby and needs no database or fixtures.
class Accounting::LedgerTest < Minitest::Test
  USD = ::Money::Currency.new("USD")
  DAY = Date.new(2026, 10, 5)

  def setup
    @ledger = Accounting::Ledger.new
  end

  def money(value)
    Accounting::Money.parse(value, USD)
  end

  def account(name, type: :assets, opening: nil)
    @ledger.create_account(
      name: name,
      type: type,
      currency: USD,
      opening_balance: opening ? money(opening) : nil
    )
  end

  def post(date, description, lines, **options)
    postings = lines.map { |name, amount| { account: name, amount: money(amount) } }
    @ledger.post_transaction(date: date, description: description, postings: postings, **options)
  end

  # ------------------------------------------------------------------
  # Core postings and balances
  # ------------------------------------------------------------------

  def test_01_simple_expense
    checking = account("Assets:Checking")
    food = account("Expenses:Food", type: :expenses)

    transaction = post(DAY, "Whole Foods", [
      [ "Assets:Checking", "-100" ],
      [ "Expenses:Food", "100" ]
    ])

    assert_equal money("-100"), @ledger.balance_of(checking)
    assert_equal money("100"), @ledger.balance_of(food)
    assert transaction.balanced?
    assert_equal money("0"), transaction.total
  end

  def test_02_income
    checking = account("Assets:Checking")
    salary = account("Income:Salary", type: :income)

    transaction = post(DAY, "Salary", [
      [ "Assets:Checking", "5000" ],
      [ "Income:Salary", "-5000" ]
    ])

    assert_equal money("5000"), @ledger.balance_of(checking)
    assert_equal money("-5000"), @ledger.balance_of(salary)
    assert transaction.balanced?
  end

  def test_03_transfer_between_accounts
    checking = account("Assets:Checking")
    savings = account("Assets:Savings")

    transaction = @ledger.transfer(from: checking, to: savings, amount: money("1000"), date: DAY)

    assert_equal money("-1000"), @ledger.balance_of(checking)
    assert_equal money("1000"), @ledger.balance_of(savings)
    assert transaction.balanced?
    refute Accounting.const_defined?(:Transfer, false), "transfers must not be a special primitive"
  end

  def test_04_split_expense
    checking = account("Assets:Checking")
    food = account("Expenses:Food", type: :expenses)
    household = account("Expenses:Household", type: :expenses)

    transaction = post(DAY, "Grocery store", [
      [ "Assets:Checking", "-300" ],
      [ "Expenses:Food", "200" ],
      [ "Expenses:Household", "100" ]
    ])

    assert_equal money("-300"), @ledger.balance_of(checking)
    assert_equal money("200"), @ledger.balance_of(food)
    assert_equal money("100"), @ledger.balance_of(household)
    assert transaction.balanced?
  end

  def test_05_refund
    checking = account("Assets:Checking")
    food = account("Expenses:Food", type: :expenses)

    post(DAY, "Purchase", [ [ "Assets:Checking", "-100" ], [ "Expenses:Food", "100" ] ])
    post(DAY + 1, "Refund", [ [ "Assets:Checking", "30" ], [ "Expenses:Food", "-30" ] ])

    assert_equal money("-70"), @ledger.balance_of(checking)
    assert_equal money("70"), @ledger.balance_of(food)
  end

  def test_06_reimbursement
    checking = account("Assets:Checking")
    work = account("Expenses:Work", type: :expenses)

    post(DAY, "Business expense", [ [ "Assets:Checking", "-500" ], [ "Expenses:Work", "500" ] ])
    post(DAY + 14, "Reimbursement", [ [ "Assets:Checking", "500" ], [ "Expenses:Work", "-500" ] ])

    assert_equal money("0"), @ledger.balance_of(checking)
    assert_equal money("0"), @ledger.balance_of(work)
  end

  # ------------------------------------------------------------------
  # Opening balances
  # ------------------------------------------------------------------

  def test_07_opening_balance_is_explicit
    checking = account("Assets:Checking", opening: "4000")
    account("Expenses:Food", type: :expenses)

    assert_equal money("4000"), checking.opening_balance
    assert_equal money("4000"), @ledger.balance_of(checking)

    post(DAY, "Groceries", [ [ "Assets:Checking", "-500" ], [ "Expenses:Food", "500" ] ])

    assert_equal money("3500"), @ledger.balance_of(checking)
    assert_equal money("4000"), @ledger.opening_balance_of(checking)

    opening_tx = @ledger.transactions.find(&:opening?)
    equity = @ledger.find_account("Equity:Opening-Balances")
    assert_equal money("-4000"), @ledger.balance_of(equity)
    assert opening_tx.balanced?
  end

  # ------------------------------------------------------------------
  # External bank balances and reconciliation
  # ------------------------------------------------------------------

  def test_08_external_balance_matches
    checking = account("Assets:Checking", opening: "4500")

    reconciliation = @ledger.reconcile(checking, external_balance: money("4500"), observed_at: DAY)

    assert reconciliation.reconciled?
    assert_equal :reconciled, reconciliation.status
    assert_equal money("0"), reconciliation.difference
  end

  def test_09_external_balance_does_not_match
    checking = account("Assets:Checking", opening: "4500")
    account("Expenses:Food", type: :expenses)
    post(DAY, "Groceries", [ [ "Assets:Checking", "-200" ], [ "Expenses:Food", "200" ] ])
    # Keep the ledger at 4500 by making the observation describe a bank at 5000.
    post(DAY, "Correction", [ [ "Assets:Checking", "200" ], [ "Expenses:Food", "-200" ] ])

    transactions_before = @ledger.transactions.size
    reconciliation = @ledger.reconcile(checking, external_balance: money("5000"))

    assert_equal :unreconciled, reconciliation.status
    assert_equal money("500"), reconciliation.difference
    assert_equal money("500"), reconciliation.difference_signed
    assert_equal money("4500"), @ledger.balance_of(checking)
    assert_equal money("4500"), checking.opening_balance
    assert_equal transactions_before, @ledger.transactions.size
  end

  def test_10_reconciliation_never_mutates_ledger
    checking = account("Assets:Checking", opening: "4500")
    snapshot_balance = @ledger.balance_of(checking)
    snapshot_transactions = @ledger.transactions.map(&:id)
    snapshot_postings = @ledger.postings.map(&:id)

    @ledger.reconcile(checking, external_balance: money("5000"))

    assert_equal snapshot_balance, @ledger.balance_of(checking)
    assert_equal snapshot_transactions, @ledger.transactions.map(&:id)
    assert_equal snapshot_postings, @ledger.postings.map(&:id)
    assert_equal money("4500"), @ledger.balance_of(checking)
  end

  # ------------------------------------------------------------------
  # Invariant enforcement and atomicity
  # ------------------------------------------------------------------

  def test_11_unbalanced_transaction_is_rejected
    account("Assets:Checking")
    account("Expenses:Food", type: :expenses)

    assert_raises(Accounting::Errors::UnbalancedTransactionError) do
      post(DAY, "Bad", [ [ "Assets:Checking", "-100" ], [ "Expenses:Food", "50" ] ])
    end

    assert_empty @ledger.transactions
    assert_empty @ledger.postings
  end

  def test_12_invalid_transaction_is_atomic
    account("Assets:Checking")
    account("Expenses:Food", type: :expenses)
    post(DAY, "Valid", [ [ "Assets:Checking", "-10" ], [ "Expenses:Food", "10" ] ])

    transactions_before = @ledger.transactions.size
    postings_before = @ledger.postings.size

    assert_raises(Accounting::Errors::UnbalancedTransactionError) do
      post(DAY, "Invalid", [ [ "Assets:Checking", "-100" ], [ "Expenses:Food", "50" ] ])
    end

    assert_equal transactions_before, @ledger.transactions.size
    assert_equal postings_before, @ledger.postings.size
  end

  # ------------------------------------------------------------------
  # Determinism, reversal and idempotency
  # ------------------------------------------------------------------

  def test_13_balance_is_order_independent
    amounts = (1..100).map(&:to_s)

    first = expense_ledger(amounts)
    second = expense_ledger(amounts.shuffle(random: Random.new(42)))

    assert_equal first.balance_of(first.find_account("Assets:Checking")),
                 second.balance_of(second.find_account("Assets:Checking"))
    assert_equal first.balance_of(first.find_account("Expenses:Food")),
                 second.balance_of(second.find_account("Expenses:Food"))
  end

  def test_14_transaction_reversal
    checking = account("Assets:Checking")
    food = account("Expenses:Food", type: :expenses)

    original = post(DAY, "Purchase", [ [ "Assets:Checking", "-100" ], [ "Expenses:Food", "100" ] ])
    reversal = @ledger.reverse_transaction(original.id, date: DAY + 1)

    assert_equal money("0"), @ledger.balance_of(checking)
    assert_equal money("0"), @ledger.balance_of(food)
    assert_equal original.id, reversal.reversal_of
    assert_equal money("-100"), original.postings.find { |p| p.account_id == checking.id }.amount
    assert reversal.balanced?
  end

  def test_15_duplicate_external_transaction_is_ignored
    account("Assets:Checking")
    account("Expenses:Food", type: :expenses)

    first = post(DAY, "Imported", [ [ "Assets:Checking", "-25" ], [ "Expenses:Food", "25" ] ],
                 source: "bank", external_id: "abc123")
    second = post(DAY, "Imported", [ [ "Assets:Checking", "-25" ], [ "Expenses:Food", "25" ] ],
                  source: "bank", external_id: "abc123")

    assert_same first, second
    assert_equal 1, @ledger.transactions.size
  end

  # ------------------------------------------------------------------
  # Multi-account behavior
  # ------------------------------------------------------------------

  def test_16_accounts_reconcile_independently
    checking = account("Assets:Checking", opening: "5000")
    savings = account("Assets:Savings", opening: "10000")

    checking_result = @ledger.reconcile(checking, external_balance: money("5000"))
    savings_result = @ledger.reconcile(savings, external_balance: money("9500"))

    assert_equal :reconciled, checking_result.status
    assert_equal :unreconciled, savings_result.status
    assert_equal money("500"), savings_result.difference
    assert_equal money("-500"), savings_result.difference_signed
  end

  def test_17_transfer_preserves_global_balance
    checking = account("Assets:Checking", opening: "5000")
    savings = account("Assets:Savings", opening: "10000")
    total_before = @ledger.net_worth

    @ledger.transfer(from: checking, to: savings, amount: money("1000"), date: DAY)

    assert_equal money("15000"), @ledger.net_worth
    assert_equal total_before, @ledger.net_worth
    assert @ledger.balanced?
  end

  def test_18_expense_preserves_accounting_equation
    account("Assets:Checking")
    account("Expenses:Food", type: :expenses)

    post(DAY, "Groceries", [ [ "Assets:Checking", "-100" ], [ "Expenses:Food", "100" ] ])

    equation = @ledger.accounting_equation
    assert_equal money("-100"), equation[:assets]
    assert_equal money("100"), equation[:expenses]
    assert_equal money("0"), @ledger.global_sum
    assert @ledger.balanced?
  end

  def test_19_every_transaction_is_balanced
    checking = account("Assets:Checking")
    savings = account("Assets:Savings")
    account("Expenses:Food", type: :expenses)
    account("Expenses:Household", type: :expenses)
    account("Income:Salary", type: :income)

    post(DAY, "Salary", [ [ "Assets:Checking", "5000" ], [ "Income:Salary", "-5000" ] ])
    post(DAY + 1, "Groceries", [ [ "Assets:Checking", "-300" ], [ "Expenses:Food", "300" ] ])
    @ledger.transfer(from: checking, to: savings, amount: money("1000"), date: DAY + 2)
    post(DAY + 3, "Split", [ [ "Assets:Checking", "-300" ], [ "Expenses:Food", "200" ], [ "Expenses:Household", "100" ] ])
    post(DAY + 4, "Refund", [ [ "Assets:Checking", "30" ], [ "Expenses:Food", "-30" ] ])

    @ledger.transactions.each { |transaction| assert transaction.balanced?, transaction.to_s }
    assert @ledger.balanced?
    assert_equal money("0"), @ledger.global_sum
  end

  # ------------------------------------------------------------------
  # Full realistic scenario
  # ------------------------------------------------------------------

  def test_20_full_realistic_scenario
    checking = account("Assets:Bank:Checking", opening: "5000")
    savings = account("Assets:Bank:Savings", opening: "10000")
    credit_card = account("Liabilities:CreditCard", type: :liabilities)
    food = account("Expenses:Food", type: :expenses)
    transport = account("Expenses:Transport", type: :expenses)
    housing = account("Expenses:Housing", type: :expenses)
    salary = account("Income:Salary", type: :income)

    post(DAY, "Salary", [ [ "Assets:Bank:Checking", "3000" ], [ "Income:Salary", "-3000" ] ])
    @ledger.transfer(from: checking, to: savings, amount: money("2000"), date: DAY + 1,
                     description: "Move to savings")
    post(DAY + 2, "Bus pass", [ [ "Expenses:Transport", "500" ], [ "Liabilities:CreditCard", "-500" ] ])
    post(DAY + 3, "Groceries", [ [ "Assets:Bank:Checking", "-300" ], [ "Expenses:Food", "300" ] ])
    post(DAY + 4, "Split groceries", [
      [ "Assets:Bank:Checking", "-200" ],
      [ "Expenses:Food", "150" ],
      [ "Expenses:Housing", "50" ]
    ])
    post(DAY + 5, "Credit card payment", [ [ "Liabilities:CreditCard", "500" ], [ "Assets:Bank:Checking", "-500" ] ])
    post(DAY + 6, "Refund", [ [ "Assets:Bank:Checking", "30" ], [ "Expenses:Food", "-30" ] ])
    post(DAY + 7, "Reimbursement", [ [ "Assets:Bank:Checking", "100" ], [ "Expenses:Food", "-100" ] ])

    assert_equal money("5130"), @ledger.balance_of(checking)
    assert_equal money("12000"), @ledger.balance_of(savings)
    assert_equal money("0"), @ledger.balance_of(credit_card)
    assert_equal money("320"), @ledger.balance_of(food)
    assert_equal money("500"), @ledger.balance_of(transport)
    assert_equal money("50"), @ledger.balance_of(housing)
    assert_equal money("-3000"), @ledger.balance_of(salary)
    assert_equal money("-15000"), @ledger.balance_of(@ledger.find_account("Equity:Opening-Balances"))

    @ledger.transactions.each { |transaction| assert transaction.balanced? }
    assert @ledger.balanced?

    # Bank reconciliation: exact match, and an observation that reveals a gap
    # without touching the ledger.
    exact = @ledger.reconcile(checking, external_balance: money("5130"), observed_at: DAY + 8)
    off = @ledger.reconcile(checking, external_balance: money("5200"), observed_at: DAY + 9)

    assert_equal :reconciled, exact.status
    assert_equal :unreconciled, off.status
    assert_equal money("70"), off.difference
    assert_equal money("5130"), @ledger.balance_of(checking)

    observation = @ledger.observe_bank_balance(checking, balance: money("5200"), observed_at: DAY + 9)
    assert_equal money("5200"), observation.balance
    assert_equal money("5130"), @ledger.balance_of(checking)
  end

  # ------------------------------------------------------------------
  # Property-style invariants
  # ------------------------------------------------------------------

  def test_21_property_every_generated_transaction_balances
    50.times do |seed|
      ledger = new_mixed_ledger
      lines = random_lines(seed)
      transaction = ledger.post_transaction(
        date: DAY,
        description: "generated #{seed}",
        postings: lines.map { |name, amount| { account: name, amount: money(amount) } }
      )
      assert transaction.balanced?
    end
  end

  def test_22_property_global_balance_stays_zero
    ledger = new_mixed_ledger
    assert_equal money("0"), ledger.global_sum

    50.times do |seed|
      lines = random_lines(seed)
      ledger.post_transaction(
        date: DAY,
        description: "generated #{seed}",
        postings: lines.map { |name, amount| { account: name, amount: money(amount) } }
      )
      assert_equal money("0"), ledger.global_sum
    end
  end

  def test_23_property_order_does_not_affect_balances
    amounts = (1..30).map(&:to_s)
    forward = expense_ledger(amounts)
    shuffled = expense_ledger(amounts.shuffle(random: Random.new(7)))

    %w[Assets:Checking Expenses:Food].each do |name|
      assert_equal forward.balance_of(forward.find_account(name)),
                   shuffled.balance_of(shuffled.find_account(name))
    end
  end

  def test_24_property_reconciliation_does_not_change_ledger
    ledger = new_mixed_ledger
    10.times do |seed|
      ledger.post_transaction(
        date: DAY + seed,
        description: "seed #{seed}",
        postings: random_lines(seed).map { |name, amount| { account: name, amount: money(amount) } }
      )
    end

    before = ledger_snapshot(ledger)
    20.times do |i|
      ledger.reconcile(ledger.find_account("Assets:Checking"), external_balance: money((1000 + i).to_s))
    end

    assert_equal before, ledger_snapshot(ledger)
  end

  private

    def expense_ledger(amounts)
      ledger = Accounting::Ledger.new
      ledger.create_account(name: "Assets:Checking", type: :assets, currency: USD)
      ledger.create_account(name: "Expenses:Food", type: :expenses, currency: USD)

      amounts.each_with_index do |amount, index|
        ledger.post_transaction(
          date: DAY + index,
          description: "expense #{index}",
          postings: [
            { account: "Assets:Checking", amount: money("-#{amount}") },
            { account: "Expenses:Food", amount: money(amount) }
          ]
        )
      end

      ledger
    end

    def new_mixed_ledger
      ledger = Accounting::Ledger.new
      ledger.create_account(name: "Assets:Checking", type: :assets, currency: USD)
      ledger.create_account(name: "Assets:Savings", type: :assets, currency: USD)
      ledger.create_account(name: "Expenses:Food", type: :expenses, currency: USD)
      ledger.create_account(name: "Income:Salary", type: :income, currency: USD)
      ledger
    end

    def random_lines(seed)
      rng = Random.new(seed)
      amount = rng.rand(1..10_000)

      case rng.rand(3)
      when 0
        [ [ "Assets:Checking", "-#{amount}" ], [ "Expenses:Food", amount.to_s ] ]
      when 1
        [ [ "Assets:Checking", amount.to_s ], [ "Income:Salary", "-#{amount}" ] ]
      else
        [ [ "Assets:Checking", "-#{amount}" ], [ "Assets:Savings", amount.to_s ] ]
      end
    end

    def ledger_snapshot(ledger)
      {
        transactions: ledger.transactions.map { |t| [ t.id, t.date, t.description, t.reversal_of ] },
        postings: ledger.postings.map { |p| [ p.id, p.account_id, p.amount.minor_units, p.transaction_id ] }
      }
    end
end
